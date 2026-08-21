import Foundation
import XCTest
import SharedCore
@testable import ShadowsocksOnePacketTunnel

final class TCPCongestionControllerTests: XCTestCase {
    func testInitialWindowAllowsTenSegments() {
        let controller = TCPCongestionController()
        XCTAssertEqual(
            controller.allowance(inFlightBytes: 0),
            TCPCongestionController.initialWindowBytes
        )
        XCTAssertEqual(controller.allowance(inFlightBytes: 14_600), 0)
    }

    func testSlowStartGrowsOneSegmentPerAcknowledgment() {
        var controller = TCPCongestionController()
        controller.noteAcknowledgment()
        XCTAssertEqual(
            controller.windowBytes,
            TCPCongestionController.initialWindowBytes + TCPCongestionController.segmentSizeBytes
        )
    }

    func testCongestionAvoidanceGrowsFractionally() {
        var controller = TCPCongestionController(
            windowBytes: 2_920,
            slowStartThresholdBytes: 2_920
        )
        controller.noteAcknowledgment()
        XCTAssertEqual(controller.windowBytes, 2_920 + 730)
    }

    func testLossHalvesThresholdAndResetsWindow() {
        var controller = TCPCongestionController()
        controller.noteLoss()
        XCTAssertEqual(controller.windowBytes, TCPCongestionController.minimumWindowBytes)
        controller.noteAcknowledgment()
        XCTAssertEqual(controller.windowBytes, 2 * TCPCongestionController.segmentSizeBytes)
    }
}

final class TCPRouterCongestionTests: XCTestCase {
    /// 初始窗口 14600B：20000B 的 inbound 只能先发出 10 个 MSS 段，
    /// 客户端 ACK 后窗口抬升，剩余 5400B 才补发出去
    func testInboundFlushRespectsWindowAndResumesOnAcknowledgment() async throws {
        let writer = CongestionWriterSpy()
        let relay = CongestionRelaySpy()
        let router = makeRouter(packetWriter: writer, relay: relay)

        try await router.route(makeCongestionTCPPacket(sequenceNumber: 100, acknowledgmentNumber: 0, flags: 0x02))
        try await router.route(makeCongestionTCPPacket(sequenceNumber: 101, acknowledgmentNumber: 2, flags: 0x10))

        await relay.emitInbound(Data(repeating: 0x41, count: 20_000))

        let firstBatch = writer.payloadPackets
        XCTAssertEqual(firstBatch.count, 10)
        XCTAssertEqual(firstBatch.reduce(0) { $0 + $1.payload.count }, 14_600)

        // ISN=1，SYN 占一个序号，10 个 MSS 段结束于序号 14602
        try await router.route(
            makeCongestionTCPPacket(sequenceNumber: 101, acknowledgmentNumber: 14_602, flags: 0x10)
        )

        let all = writer.payloadPackets
        XCTAssertEqual(all.count, 14)
        XCTAssertEqual(all.reduce(0) { $0 + $1.payload.count }, 20_000)

        var expectedSequence = all.first?.sequenceNumber
        for packet in all {
            XCTAssertEqual(packet.sequenceNumber, expectedSequence)
            expectedSequence = packet.sequenceNumber &+ UInt32(packet.payload.count)
        }
    }

    private func makeRouter(
        packetWriter: any TunnelPacketWriting,
        relay: CongestionRelaySpy
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
            proxyRelayFactory: { _ in relay }
        )
    }
}

private final class CongestionWriterSpy: TunnelPacketWriting {
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

private final class CongestionRelaySpy: TCPFlowRelaying {
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

private func makeCongestionTCPPacket(
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
