import Foundation
import XCTest
import SharedCore
@testable import ShadowsocksOnePacketTunnel

final class TCPRouterRetransmissionTests: XCTestCase {
    func testRetransmitsUnackedInboundPayload() async throws {
        let writer = RetransmitWriterSpy()
        let relay = RetransmitRelaySpy()
        let router = makeRouter(packetWriter: writer, relay: relay)

        try await establishFlow(on: router)
        await relay.emitInbound(Data("AB".utf8))

        try await assertEventually({ writer.payloadPackets.count }, equals: 1)
        try await assertEventually({ writer.payloadPackets.count > 1 }, equals: true)

        let sequences = writer.payloadPackets.map(\.sequenceNumber)
        XCTAssertEqual(sequences.first, sequences.last)
    }

    func testAckStopsRetransmission() async throws {
        let writer = RetransmitWriterSpy()
        let relay = RetransmitRelaySpy()
        let router = makeRouter(packetWriter: writer, relay: relay)

        try await establishFlow(on: router)
        await relay.emitInbound(Data("AB".utf8))
        try await assertEventually({ writer.payloadPackets.count }, equals: 1)

        // ISN=1，SYN 占一个序号，"AB" 结束于序号 4
        try await router.route(makeRexmitTCPPacket(sequenceNumber: 101, acknowledgmentNumber: 4, flags: 0x10))
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(writer.payloadPackets.count, 1)
    }

    private func establishFlow(on router: TCPRouter) async throws {
        try await router.route(makeRexmitTCPPacket(sequenceNumber: 100, acknowledgmentNumber: 0, flags: 0x02))
        try await router.route(makeRexmitTCPPacket(sequenceNumber: 101, acknowledgmentNumber: 2, flags: 0x10))
    }

    private func makeRouter(
        packetWriter: any TunnelPacketWriting,
        relay: RetransmitRelaySpy
    ) -> TCPRouter {
        let matcher = RouteMatcher(
            configuration: RoutingConfiguration(bypassCNIP: true, domainWhitelist: []),
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
            packetWriter: packetWriter,
            directRelayFactory: { _ in relay },
            proxyRelayFactory: { _ in relay },
            retransmitTimeout: 0.1,
            sweepIntervalNanoseconds: 20_000_000
        )
    }

    private func assertEventually<T: Equatable>(
        _ expression: @escaping () -> T,
        equals expected: T,
        timeout: TimeInterval = 2
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if expression() == expected {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(expression(), expected)
    }
}

private final class RetransmitWriterSpy: TunnelPacketWriting {
    private let lock = NSLock()
    private var written: [Data] = []

    func write(_ packets: [Data], protocols: [NSNumber]) {
        lock.lock()
        written.append(contentsOf: packets)
        lock.unlock()
    }

    var payloadPackets: [TCPPacket] {
        lock.lock()
        defer { lock.unlock() }
        return written
            .compactMap { try? IPPacket(data: $0).tcpSegment() }
            .filter { !$0.payload.isEmpty }
    }
}

private final class RetransmitRelaySpy: TCPFlowRelaying {
    let queuedOutboundBytes = 0
    var onInboundBytes: (@Sendable (Data) async -> Void)?
    var onClosed: (@Sendable () async -> Void)?

    func start() async throws {}
    func forwardOutboundPayload(_ payload: Data) async throws {}
    func stop() async {}

    func emitInbound(_ data: Data) async {
        await onInboundBytes?(data)
    }
}

private func makeRexmitTCPPacket(
    sequenceNumber: UInt32,
    acknowledgmentNumber: UInt32,
    flags: UInt8
) -> IPPacket {
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
    ]

    let totalLength = UInt16(20 + tcpHeader.count)
    let ipHeader: [UInt8] = [
        0x45,
        0x00,
        UInt8(totalLength >> 8),
        UInt8(totalLength & 0x00FF),
        0x00, 0x00,
        0x40, 0x00,
        0x40,
        6,
        0x00, 0x00,
        10, 0, 0, 2,
        1, 1, 1, 1,
    ]

    return try! IPPacket(data: Data(ipHeader + tcpHeader))
}
