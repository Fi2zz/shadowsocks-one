import Foundation
import XCTest
import SharedCore
@testable import ShadowsocksBrowserPacketTunnel

final class TCPRouterWindowTests: XCTestCase {
    func testAdvertisedWindowShrinksWhenRelayQueueDeepens() async throws {
        let writer = WindowWriterSpy()
        let relay = WindowRelaySpy()
        let router = makeRouter(packetWriter: writer, relay: relay)

        try await router.route(makeWindowTCPPacket(sequenceNumber: 100, acknowledgmentNumber: 0, flags: 0x02))
        try await router.route(makeWindowTCPPacket(sequenceNumber: 101, acknowledgmentNumber: 2, flags: 0x10))

        relay.queuedOutboundBytes = 200_000
        try await router.route(
            makeWindowTCPPacket(sequenceNumber: 101, acknowledgmentNumber: 2, flags: 0x18, payload: "AB")
        )

        let window = try XCTUnwrap(writer.windows.last)
        XCTAssertEqual(window, UInt16(TCPFlowWindow.outboundCapacityBytes - 200_000))
    }

    func testWindowHelperClampsToRange() {
        XCTAssertEqual(TCPFlowWindow.advertised(queuedOutboundBytes: 0), 0xFFFF)
        XCTAssertEqual(
            TCPFlowWindow.advertised(queuedOutboundBytes: TCPFlowWindow.outboundCapacityBytes + 1),
            0
        )
    }

    private func makeRouter(
        packetWriter: any TunnelPacketWriting,
        relay: WindowRelaySpy
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

private final class WindowWriterSpy: TunnelPacketWriting {
    private let lock = NSLock()
    private var written: [Data] = []

    var windows: [UInt16] {
        lock.lock()
        defer { lock.unlock() }
        return written.map { UInt16($0[34]) << 8 | UInt16($0[35]) }
    }

    func write(_ packets: [Data], protocols: [NSNumber]) {
        lock.lock()
        written.append(contentsOf: packets)
        lock.unlock()
    }
}

private final class WindowRelaySpy: TCPFlowRelaying {
    var queuedOutboundBytes = 0
    var onInboundBytes: (@Sendable (Data) async -> Void)?
    var onClosed: (@Sendable () async -> Void)?

    func start() async throws {}
    func forwardOutboundPayload(_ payload: Data) async throws {}
    func stop() async {}
}

private func makeWindowTCPPacket(
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
