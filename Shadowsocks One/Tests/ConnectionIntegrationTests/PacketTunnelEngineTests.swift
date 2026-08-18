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
        let routeCalls = await router.routeCallCount

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
        let routeCalls = await router.routeCallCount

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

        try await assertEventually({ await router.routeCallCount }, equals: 1)
        packetFlow.finishPendingRead()
        await engine.stop()

        let stopAllCallCount = await router.stopAllCallCount
        XCTAssertEqual(stopAllCallCount, 1)
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
        try await assertEventually({ await router.stopAllCallCount }, equals: 1)
        packetFlow.finishPendingRead()
        await engine.stop()
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

private actor TCPRouterSpy: TCPRouting {
    private(set) var routeCallCount = 0
    private(set) var stopAllCallCount = 0
    private let shouldThrowOnRoute: Bool

    init(shouldThrowOnRoute: Bool = false) {
        self.shouldThrowOnRoute = shouldThrowOnRoute
    }

    func route(_ packet: IPPacket) async throws {
        if shouldThrowOnRoute {
            throw DummyLocalizedError(errorDescription: "route failed")
        }
        routeCallCount += 1
    }

    func stopAll() async {
        stopAllCallCount += 1
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

    func finishPendingRead() {
        lock.lock()
        let completion = pendingCompletion
        pendingCompletion = nil
        lock.unlock()
        completion?([], [])
    }
}

private struct DummyLocalizedError: LocalizedError {
    let errorDescription: String?
}

private func makeDNSPacket() -> Data {
    let udpPayload: [UInt8] = [
        0x12, 0x34, 0x01, 0x00,
        0x00, 0x01, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ]
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
