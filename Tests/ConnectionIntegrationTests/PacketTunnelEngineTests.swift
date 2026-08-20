import Darwin
import XCTest
import SharedCore

final class PacketTunnelEngineTests: XCTestCase {
    func testRoutesDNSPacketToDNSCoordinator() async throws {
        let dnsCoordinator = DNSCoordinatorSpy()
        let router = TCPRouterSpy()
        let engine = TunnelEngine(
            dnsCoordinator: dnsCoordinator,
            tcpRouter: router
        )

        try await engine.handleOutboundPacket(makeDNSPacket())

        let dnsHandleCalls = await dnsCoordinator.handleCallCount
        let routeCalls = router.routeCallCountSnapshot()

        XCTAssertEqual(dnsHandleCalls, 1)
        XCTAssertEqual(routeCalls, 0)
    }

    func testRoutesTCPPacketToTCPRouter() async throws {
        let dnsCoordinator = DNSCoordinatorSpy()
        let router = TCPRouterSpy()
        let engine = TunnelEngine(
            dnsCoordinator: dnsCoordinator,
            tcpRouter: router
        )

        try await engine.handleOutboundPacket(makeTCPPacket())

        let dnsHandleCalls = await dnsCoordinator.handleCallCount
        let routeCalls = router.routeCallCountSnapshot()

        XCTAssertEqual(dnsHandleCalls, 0)
        XCTAssertEqual(routeCalls, 1)
    }

    func testStartReadsPacketsFromPacketFlow() async throws {
        let dnsCoordinator = DNSCoordinatorSpy()
        let router = TCPRouterSpy()
        let packetFlow = PacketFlowSpy(batches: [[makeTCPPacket()]])
        let engine = TunnelEngine(
            dnsCoordinator: dnsCoordinator,
            tcpRouter: router,
            packetFlow: packetFlow
        )

        engine.start()

        try await assertEventually({ router.routeCallCountSnapshot() }, equals: 1)
        packetFlow.finishPendingRead()
        await engine.stop()

        let stopAllCallCount = router.stopAllCallCountSnapshot()
        XCTAssertEqual(stopAllCallCount, 1)
    }

    func testStartInstallsPacketWriterAndBridgesWritesBackToPacketFlow() async throws {
        let dnsCoordinator = DNSCoordinatorSpy()
        let router = TCPRouterSpy()
        let packetFlow = PacketFlowSpy(batches: [[makeTCPPacket()]])
        let engine = TunnelEngine(
            dnsCoordinator: dnsCoordinator,
            tcpRouter: router,
            packetFlow: packetFlow,
            packetWriter: TunnelPacketWriter(packetFlow: packetFlow)
        )

        engine.start()

        try await assertEventually({ router.setPacketWriterCallCountSnapshot() }, equals: 1)
        try await assertEventually({ router.routeCallCountSnapshot() }, equals: 1)

        router.emitReturnPacket(makeTCPPacket())
        XCTAssertEqual(packetFlow.writtenPacketsSnapshot().count, 1)
        XCTAssertEqual(packetFlow.writtenProtocolsSnapshot(), [NSNumber(value: AF_INET)])

        packetFlow.finishPendingRead()
        await engine.stop()

        let hasPacketWriter = router.hasPacketWriterSnapshot()
        XCTAssertFalse(hasPacketWriter)
    }

    func testFatalReadLoopErrorStopsRouterAndReportsFailure() async throws {
        let dnsCoordinator = DNSCoordinatorSpy()
        let router = TCPRouterSpy(shouldThrowOnRoute: true)
        let packetFlow = PacketFlowSpy(batches: [[makeTCPPacket()]])
        let engine = TunnelEngine(
            dnsCoordinator: dnsCoordinator,
            tcpRouter: router,
            packetFlow: packetFlow
        )
        let failureRecorder = FailureRecorder()

        engine.start { error in
            Task {
                await failureRecorder.record(error.localizedDescription)
            }
        }

        try await assertEventually({ await failureRecorder.latestMessage }, equals: "route failed")
        try await assertEventually({ router.stopAllCallCountSnapshot() }, equals: 1)
        packetFlow.finishPendingRead()
        await engine.stop()
    }

    func testDNSCoordinatorQueriesUpstreamWritesResponseAndCachesARecord() async throws {
        let cache = DNSCache(now: Date.init)
        let packetFlow = PacketFlowSpy(batches: [])
        let upstream = DNSUpstreamClientSpy(responsePayload: makeDNSResponsePayload())
        let dnsCoordinator = DNSCoordinator(
            cache: cache,
            whitelist: [],
            upstreamClient: upstream,
            packetWriter: TunnelPacketWriter(packetFlow: packetFlow)
        )
        let engine = TunnelEngine(
            dnsCoordinator: dnsCoordinator,
            tcpRouter: TCPRouterSpy(),
            packetWriter: TunnelPacketWriter(packetFlow: packetFlow)
        )

        try await engine.handleOutboundPacket(makeDNSPacket())

        let query = await upstream.lastQuery
        XCTAssertEqual(query?.serverIP, "8.8.8.8")
        XCTAssertEqual(query?.payload, makeDNSQueryPayload())
        XCTAssertTrue(cache.contains(domain: "example.com", address: "93.184.216.34"))

        let writtenPacket = try XCTUnwrap(packetFlow.writtenPacketsSnapshot().first)
        let packet = try IPPacket(data: writtenPacket)
        let udp = try packet.udpSegment()

        XCTAssertEqual(packet.sourceAddress, "8.8.8.8")
        XCTAssertEqual(packet.destinationAddress, "10.0.0.2")
        XCTAssertEqual(udp.sourcePort, 53)
        XCTAssertEqual(udp.destinationPort, 49_152)
        XCTAssertEqual(udp.payload, makeDNSResponsePayload())
    }

    func testDNSCoordinatorRoutesWhitelistedDomainToLocalUpstream() async throws {
        let proxySpy = DNSUpstreamClientSpy(responsePayload: makeDNSResponsePayload())
        let localSpy = DNSUpstreamClientSpy(responsePayload: makeDNSResponsePayload())
        let matcher = RouteMatcher(
            configuration: RoutingConfiguration(
                bypassCNIP: false,
                domainWhitelist: ["example.com"]
            ),
            cnIPRanges: try CNIPRangeList(ranges: [])
        )
        let dnsCoordinator = DNSCoordinator(
            cache: DNSCache(now: Date.init),
            whitelist: [],
            upstreamClient: proxySpy,
            localUpstreamClient: localSpy,
            matcher: matcher,
            packetWriter: TunnelPacketWriter(packetFlow: PacketFlowSpy(batches: []))
        )

        try await dnsCoordinator.handle(IPPacket(data: makeDNSPacket()))

        let localQuery = await localSpy.lastQuery
        let proxyQuery = await proxySpy.lastQuery
        XCTAssertNotNil(localQuery)
        XCTAssertNil(proxyQuery)
    }

    func testDNSCoordinatorRoutesUnlistedDomainToProxyUpstream() async throws {
        let proxySpy = DNSUpstreamClientSpy(responsePayload: makeDNSResponsePayload())
        let localSpy = DNSUpstreamClientSpy(responsePayload: makeDNSResponsePayload())
        let matcher = RouteMatcher(
            configuration: RoutingConfiguration(
                bypassCNIP: false,
                domainWhitelist: []
            ),
            cnIPRanges: try CNIPRangeList(ranges: [])
        )
        let dnsCoordinator = DNSCoordinator(
            cache: DNSCache(now: Date.init),
            whitelist: [],
            upstreamClient: proxySpy,
            localUpstreamClient: localSpy,
            matcher: matcher,
            packetWriter: TunnelPacketWriter(packetFlow: PacketFlowSpy(batches: []))
        )

        try await dnsCoordinator.handle(IPPacket(data: makeDNSPacket()))

        let localQuery = await localSpy.lastQuery
        let proxyQuery = await proxySpy.lastQuery
        XCTAssertNil(localQuery)
        XCTAssertNotNil(proxyQuery)
    }

    private func assertEventually<T: Equatable>(
        _ actual: @escaping () async -> T,
        equals expected: T,
        timeoutNanoseconds: UInt64 = 1_000_000_000
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await actual() == expected {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let finalValue = await actual()
        XCTAssertEqual(finalValue, expected)
    }
}

private actor DNSCoordinatorSpy: DNSCoordinating {
    private(set) var handleCallCount = 0

    func warmUpWhitelistCache() async {}

    func handle(_ packet: IPPacket) async throws {
        handleCallCount += 1
    }
}

private actor DNSUpstreamClientSpy: DNSPayloadQuerying {
    private(set) var lastQuery: (serverIP: String, payload: Data)?
    private let responsePayload: Data

    init(responsePayload: Data) {
        self.responsePayload = responsePayload
    }

    func query(serverIP: String, payload: Data) async throws -> Data {
        lastQuery = (serverIP, payload)
        return responsePayload
    }
}

private final class TCPRouterSpy: TCPRouting {
    private let lock = NSLock()
    private var routeCallCount = 0
    private var stopAllCallCount = 0
    private var setPacketWriterCallCount = 0
    private var hasPacketWriter = false
    private let shouldThrowOnRoute: Bool
    private var packetWriter: (any TunnelPacketWriting)?

    init(shouldThrowOnRoute: Bool = false) {
        self.shouldThrowOnRoute = shouldThrowOnRoute
    }

    func route(_ packet: IPPacket) async throws {
        if shouldThrowOnRoute {
            throw DummyLocalizedError(errorDescription: "route failed")
        }
        incrementRouteCallCount()
    }

    func stopAll() async {
        incrementStopAllCallCount()
    }

    func setPacketWriter(_ packetWriter: (any TunnelPacketWriting)?) {
        lock.lock()
        self.packetWriter = packetWriter
        hasPacketWriter = packetWriter != nil
        setPacketWriterCallCount += 1
        lock.unlock()
    }

    func emitReturnPacket(_ packet: Data) {
        lock.lock()
        let packetWriter = self.packetWriter
        lock.unlock()
        packetWriter?.write([packet], protocols: [NSNumber(value: AF_INET)])
    }

    func routeCallCountSnapshot() -> Int {
        lock.lock()
        let count = routeCallCount
        lock.unlock()
        return count
    }

    func stopAllCallCountSnapshot() -> Int {
        lock.lock()
        let count = stopAllCallCount
        lock.unlock()
        return count
    }

    func setPacketWriterCallCountSnapshot() -> Int {
        lock.lock()
        let count = setPacketWriterCallCount
        lock.unlock()
        return count
    }

    func hasPacketWriterSnapshot() -> Bool {
        lock.lock()
        let hasPacketWriter = self.hasPacketWriter
        lock.unlock()
        return hasPacketWriter
    }

    private func incrementRouteCallCount() {
        lock.lock()
        routeCallCount += 1
        lock.unlock()
    }

    private func incrementStopAllCallCount() {
        lock.lock()
        stopAllCallCount += 1
        lock.unlock()
    }
}

private actor FailureRecorder {
    private(set) var latestMessage: String?

    func record(_ message: String) {
        latestMessage = message
    }
}

private final class PacketFlowSpy: TunnelPacketFlow {
    private let lock = NSLock()
    private var batches: [[Data]]
    private var pendingCompletion: (([Data], [NSNumber]) -> Void)?
    private(set) var writtenPackets: [Data] = []
    private(set) var writtenProtocols: [NSNumber] = []

    init(batches: [[Data]]) {
        self.batches = batches
    }

    func readPackets(completionHandler: @escaping ([Data], [NSNumber]) -> Void) {
        lock.lock()
        if !batches.isEmpty {
            let batch = batches.removeFirst()
            lock.unlock()
            completionHandler(batch, Array(repeating: NSNumber(value: AF_INET), count: batch.count))
            return
        }

        pendingCompletion = completionHandler
        lock.unlock()
    }

    func writePackets(_ packets: [Data], withProtocols protocols: [NSNumber]) {
        lock.lock()
        writtenPackets.append(contentsOf: packets)
        writtenProtocols.append(contentsOf: protocols)
        lock.unlock()
    }

    func finishPendingRead() {
        lock.lock()
        let completion = pendingCompletion
        pendingCompletion = nil
        lock.unlock()
        completion?([], [])
    }

    func writtenPacketsSnapshot() -> [Data] {
        lock.lock()
        let packets = writtenPackets
        lock.unlock()
        return packets
    }

    func writtenProtocolsSnapshot() -> [NSNumber] {
        lock.lock()
        let protocols = writtenProtocols
        lock.unlock()
        return protocols
    }
}

private struct DummyLocalizedError: LocalizedError {
    let errorDescription: String?
}

private func makeDNSPacket() -> Data {
    let udpPayload = Array(makeDNSQueryPayload())
    let udpHeader = makeUDPHeader(
        sourcePort: 49_152,
        destinationPort: 53,
        payloadLength: udpPayload.count
    )

    return makeIPv4Packet(
        protocolNumber: 17,
        sourceAddress: [10, 0, 0, 2],
        destinationAddress: [8, 8, 8, 8],
        transportPayload: udpHeader + udpPayload
    )
}

private func makeTCPPacket() -> Data {
    let tcpHeader: [UInt8] = [
        0xC0, 0x00,
        0x01, 0xBB,
        0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00,
        0x50, 0x02,
        0x20, 0x00,
        0x00, 0x00,
        0x00, 0x00,
    ]

    return makeIPv4Packet(
        protocolNumber: 6,
        sourceAddress: [10, 0, 0, 2],
        destinationAddress: [1, 1, 1, 1],
        transportPayload: tcpHeader
    )
}

private func makeUDPHeader(
    sourcePort: UInt16,
    destinationPort: UInt16,
    payloadLength: Int
) -> [UInt8] {
    let length = UInt16(8 + payloadLength)
    return [
        UInt8(sourcePort >> 8),
        UInt8(sourcePort & 0x00FF),
        UInt8(destinationPort >> 8),
        UInt8(destinationPort & 0x00FF),
        UInt8(length >> 8),
        UInt8(length & 0x00FF),
        0x00,
        0x00,
    ]
}

private func makeIPv4Packet(
    protocolNumber: UInt8,
    sourceAddress: [UInt8],
    destinationAddress: [UInt8],
    transportPayload: [UInt8]
) -> Data {
    let totalLength = UInt16(20 + transportPayload.count)
    let header: [UInt8] = [
        0x45,
        0x00,
        UInt8(totalLength >> 8),
        UInt8(totalLength & 0x00FF),
        0x00, 0x00,
        0x40, 0x00,
        0x40,
        protocolNumber,
        0x00, 0x00,
    ] + sourceAddress + destinationAddress

    return Data(header + transportPayload)
}

private func makeDNSQueryPayload() -> Data {
    Data([
        0x12, 0x34, 0x01, 0x00,
        0x00, 0x01, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x07, 0x65, 0x78, 0x61, 0x6D, 0x70, 0x6C, 0x65,
        0x03, 0x63, 0x6F, 0x6D, 0x00,
        0x00, 0x01, 0x00, 0x01,
    ])
}

private func makeDNSResponsePayload() -> Data {
    Data([
        0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00,
        0x07, 0x65, 0x78, 0x61, 0x6D, 0x70, 0x6C, 0x65,
        0x03, 0x63, 0x6F, 0x6D, 0x00,
        0x00, 0x01, 0x00, 0x01,
        0xC0, 0x0C,
        0x00, 0x01, 0x00, 0x01,
        0x00, 0x00, 0x01, 0x2C,
        0x00, 0x04, 93, 184, 216, 34,
    ])
}
