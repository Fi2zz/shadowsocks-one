import XCTest
import SharedCore
@testable import ShadowsocksOnePacketTunnel

final class TCPRouterReturnPathTests: XCTestCase {
    func testWritesSYNACKWhenClientStartsFlow() async throws {
        let writer = PacketWriterSpy()
        let relay = RelaySpy()
        let router = makeRouter(packetWriter: writer, relay: relay)

        try await router.route(makeTCPPacket(sequenceNumber: 100, acknowledgmentNumber: 0, flags: 0x02))

        XCTAssertEqual(relay.startCalls, 1)
        XCTAssertEqual(writer.packets.count, 1)

        let packet = try IPPacket(data: writer.packets[0])
        let tcp = try packet.tcpSegment()
        XCTAssertEqual(packet.sourceAddress, "1.1.1.1")
        XCTAssertEqual(packet.destinationAddress, "10.0.0.2")
        XCTAssertTrue(tcp.isSYN)
        XCTAssertTrue(tcp.isACK)
        XCTAssertEqual(tcp.sequenceNumber, 1)
        XCTAssertEqual(tcp.acknowledgmentNumber, 101)
    }

    func testWritesPSHACKWhenRelayEmitsInboundBytes() async throws {
        let writer = PacketWriterSpy()
        let relay = RelaySpy()
        let router = makeRouter(packetWriter: writer, relay: relay)

        try await router.route(makeTCPPacket(sequenceNumber: 100, acknowledgmentNumber: 0, flags: 0x02))
        try await router.route(makeTCPPacket(sequenceNumber: 101, acknowledgmentNumber: 2, flags: 0x10))
        writer.reset()

        await relay.emitInbound(Data("HTTP".utf8))

        XCTAssertEqual(writer.packets.count, 1)
        let packet = try IPPacket(data: writer.packets[0])
        let tcp = try packet.tcpSegment()
        XCTAssertTrue(tcp.isPSH)
        XCTAssertTrue(tcp.isACK)
        XCTAssertEqual(tcp.sequenceNumber, 2)
        XCTAssertEqual(tcp.acknowledgmentNumber, 101)
        XCTAssertEqual(tcp.payload, Data("HTTP".utf8))
    }

    func testWritesACKWhenClientSendsPayload() async throws {
        let writer = PacketWriterSpy()
        let relay = RelaySpy()
        let router = makeRouter(packetWriter: writer, relay: relay)

        try await router.route(makeTCPPacket(sequenceNumber: 100, acknowledgmentNumber: 0, flags: 0x02))
        try await router.route(makeTCPPacket(sequenceNumber: 101, acknowledgmentNumber: 2, flags: 0x10))
        writer.reset()

        try await router.route(
            makeTCPPacket(
                sequenceNumber: 101,
                acknowledgmentNumber: 2,
                flags: 0x18,
                payload: "hello"
            )
        )

        XCTAssertEqual(relay.forwardedPayloads, [Data("hello".utf8)])
        XCTAssertEqual(writer.packets.count, 1)

        let tcp = try IPPacket(data: writer.packets[0]).tcpSegment()
        XCTAssertTrue(tcp.isACK)
        XCTAssertFalse(tcp.isPSH)
        XCTAssertEqual(tcp.sequenceNumber, 2)
        XCTAssertEqual(tcp.acknowledgmentNumber, 106)
        XCTAssertEqual(tcp.payload.count, 0)
    }

    func testDropsDuplicateClientPayloadAndReACKsCurrentBaseline() async throws {
        let writer = PacketWriterSpy()
        let relay = RelaySpy()
        let router = makeRouter(packetWriter: writer, relay: relay)
        let payloadPacket = makeTCPPacket(
            sequenceNumber: 101,
            acknowledgmentNumber: 2,
            flags: 0x18,
            payload: "hello"
        )

        try await router.route(makeTCPPacket(sequenceNumber: 100, acknowledgmentNumber: 0, flags: 0x02))
        try await router.route(makeTCPPacket(sequenceNumber: 101, acknowledgmentNumber: 2, flags: 0x10))
        writer.reset()

        try await router.route(payloadPacket)
        try await router.route(payloadPacket)

        XCTAssertEqual(relay.forwardedPayloads, [Data("hello".utf8)])
        XCTAssertEqual(writer.packets.count, 2)

        let duplicateAck = try IPPacket(data: writer.packets[1]).tcpSegment()
        XCTAssertTrue(duplicateAck.isACK)
        XCTAssertEqual(duplicateAck.sequenceNumber, 2)
        XCTAssertEqual(duplicateAck.acknowledgmentNumber, 106)
        XCTAssertEqual(duplicateAck.payload.count, 0)
    }

    func testSplitsLargeInboundPayloadIntoMultiplePackets() async throws {
        let writer = PacketWriterSpy()
        let relay = RelaySpy()
        let router = makeRouter(packetWriter: writer, relay: relay)
        let payload = Data(repeating: 0x41, count: 3_000)

        try await router.route(makeTCPPacket(sequenceNumber: 100, acknowledgmentNumber: 0, flags: 0x02))
        try await router.route(makeTCPPacket(sequenceNumber: 101, acknowledgmentNumber: 2, flags: 0x10))
        writer.reset()

        await relay.emitInbound(payload)

        XCTAssertEqual(writer.packets.count, 3)

        let first = try IPPacket(data: writer.packets[0]).tcpSegment()
        let second = try IPPacket(data: writer.packets[1]).tcpSegment()
        let third = try IPPacket(data: writer.packets[2]).tcpSegment()

        XCTAssertEqual(first.payload.count, 1_460)
        XCTAssertEqual(second.payload.count, 1_460)
        XCTAssertEqual(third.payload.count, 80)

        XCTAssertEqual(first.sequenceNumber, 2)
        XCTAssertEqual(second.sequenceNumber, 1_462)
        XCTAssertEqual(third.sequenceNumber, 2_922)
        XCTAssertEqual(first.acknowledgmentNumber, 101)
        XCTAssertEqual(second.acknowledgmentNumber, 101)
        XCTAssertEqual(third.acknowledgmentNumber, 101)
    }

    func testWritesFINACKWhenRelayCloses() async throws {
        let writer = PacketWriterSpy()
        let relay = RelaySpy()
        let router = makeRouter(packetWriter: writer, relay: relay)

        try await router.route(makeTCPPacket(sequenceNumber: 100, acknowledgmentNumber: 0, flags: 0x02))
        try await router.route(makeTCPPacket(sequenceNumber: 101, acknowledgmentNumber: 2, flags: 0x10))
        writer.reset()

        await relay.close()

        XCTAssertEqual(writer.packets.count, 1)
        let tcp = try IPPacket(data: writer.packets[0]).tcpSegment()
        XCTAssertTrue(tcp.isFIN)
        XCTAssertTrue(tcp.isACK)
        XCTAssertEqual(tcp.sequenceNumber, 2)
        XCTAssertEqual(tcp.acknowledgmentNumber, 102)
    }

    func testDropsLatePacketsAfterRelayCloses() async throws {
        let writer = PacketWriterSpy()
        let relay = RelaySpy()
        let router = makeRouter(packetWriter: writer, relay: relay)

        try await router.route(makeTCPPacket(sequenceNumber: 100, acknowledgmentNumber: 0, flags: 0x02))
        try await router.route(makeTCPPacket(sequenceNumber: 101, acknowledgmentNumber: 2, flags: 0x10))

        await relay.close()
        writer.reset()

        try await router.route(makeTCPPacket(sequenceNumber: 101, acknowledgmentNumber: 3, flags: 0x10))
        try await router.route(
            makeTCPPacket(
                sequenceNumber: 101,
                acknowledgmentNumber: 3,
                flags: 0x18,
                payload: "late"
            )
        )

        XCTAssertEqual(relay.startCalls, 1)
        XCTAssertEqual(writer.packets.count, 0)
    }

    func testDropsNonSYNPacketsForResidualInitialSession() async throws {
        let writer = PacketWriterSpy()
        let relay = RelaySpy()
        let sessionStore = TCPFlowSessionStore()
        let router = makeRouter(
            packetWriter: writer,
            relay: relay,
            sessionStore: sessionStore
        )
        let packet = makeTCPPacket(
            sequenceNumber: 101,
            acknowledgmentNumber: 3,
            flags: 0x18,
            payload: "late"
        )
        let key = try TCPFlowKey(packet: packet)
        _ = sessionStore.session(for: key) {
            (
                relay,
                TCPFlowState.initial(
                    clientIP: "10.0.0.2",
                    clientPort: 49_152,
                    remoteIP: "1.1.1.1",
                    remotePort: 443,
                    clientSequenceNumber: 101
                )
            )
        }

        try await router.route(packet)

        XCTAssertEqual(relay.startCalls, 0)
        XCTAssertEqual(relay.stopCalls, 1)
        XCTAssertEqual(writer.packets.count, 0)
        XCTAssertNil(sessionStore.state(for: key))
    }

    private func makeRouter(
        packetWriter: any TunnelPacketWriting,
        relay: RelaySpy,
        sessionStore: TCPFlowSessionStore = TCPFlowSessionStore()
    ) -> TCPRouter {
        let matcher = RouteMatcher(
            configuration: RoutingConfiguration(
                bypassCNIP: true,
                domainWhitelist: []
            ),
            cnIPRanges: try! CNIPRangeList(ranges: ["1.1.1.0/24"])
        )

        return TCPRouter(
            launchConfiguration: TunnelLaunchConfiguration(
                profileID: UUID(),
                connection: ConnectionConfig(
                    host: "127.0.0.1",
                    port: 8388,
                    method: .aes128GCM,
                    password: "pass"
                ),
                plugin: nil,
                pluginOptions: nil
            ),
            matcher: matcher,
            sessionStore: sessionStore,
            packetWriter: packetWriter,
            directRelayFactory: { _ in relay },
            proxyRelayFactory: { _ in relay }
        )
    }
}

private final class PacketWriterSpy: TunnelPacketWriting {
    private let lock = NSLock()
    private(set) var packets: [Data] = []
    private(set) var protocols: [NSNumber] = []

    func write(_ packets: [Data], protocols: [NSNumber]) {
        lock.lock()
        self.packets.append(contentsOf: packets)
        self.protocols.append(contentsOf: protocols)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        packets.removeAll()
        protocols.removeAll()
        lock.unlock()
    }
}

private final class RelaySpy: TCPFlowRelaying {
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var forwardedPayloads: [Data] = []
    let queuedOutboundBytes = 0
    var onInboundBytes: (@Sendable (Data) async -> Void)?
    var onClosed: (@Sendable () async -> Void)?

    func start() async throws {
        startCalls += 1
    }

    func forwardOutboundPayload(_ payload: Data) async throws {
        forwardedPayloads.append(payload)
    }

    func stop() async {
        stopCalls += 1
    }

    func emitInbound(_ data: Data) async {
        await onInboundBytes?(data)
    }

    func close() async {
        await onClosed?()
    }
}

private func makeTCPPacket(
    sequenceNumber: UInt32,
    acknowledgmentNumber: UInt32,
    flags: UInt8,
    payload: String = ""
) -> IPPacket {
    let payloadBytes = Array(payload.utf8)
    let tcpHeader: [UInt8] = [
        0xC0, 0x00,
        0x01, 0xBB,
        UInt8((sequenceNumber >> 24) & 0xFF),
        UInt8((sequenceNumber >> 16) & 0xFF),
        UInt8((sequenceNumber >> 8) & 0xFF),
        UInt8(sequenceNumber & 0xFF),
        UInt8((acknowledgmentNumber >> 24) & 0xFF),
        UInt8((acknowledgmentNumber >> 16) & 0xFF),
        UInt8((acknowledgmentNumber >> 8) & 0xFF),
        UInt8(acknowledgmentNumber & 0xFF),
        0x50, flags,
        0x20, 0x00,
        0x00, 0x00,
        0x00, 0x00,
    ] + payloadBytes

    return try! IPPacket(
        data: makeIPv4Packet(
            protocolNumber: 6,
            sourceAddress: [10, 0, 0, 2],
            destinationAddress: [1, 1, 1, 1],
            transportPayload: tcpHeader
        )
    )
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
