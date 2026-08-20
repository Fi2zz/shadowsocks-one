import Foundation
import XCTest
import SharedCore
@testable import ShadowsocksOnePacketTunnel

final class TunnelEngineUDPTests: XCTestCase {
    func testRoutesNonDNSUDPPacketToUDPRouter() async throws {
        let dnsCoordinator = EngineDNSCoordinatorSpy()
        let udpRouter = UDPRouterSpy()
        let engine = TunnelEngine(
            dnsCoordinator: dnsCoordinator,
            tcpRouter: EngineTCPRouterSpy(),
            udpRouter: udpRouter
        )

        try await engine.handleOutboundPacket(
            makeUDPPacket(destination: "142.250.72.196", destinationPort: 443, payload: "QUIC").data
        )

        let udpRouteCalls = udpRouter.routeCallCount
        let dnsHandleCalls = await dnsCoordinator.handleCallCount
        XCTAssertEqual(udpRouteCalls, 1)
        XCTAssertEqual(dnsHandleCalls, 0)
    }

    func testKeepsDNSDatagramsWithDNSCoordinator() async throws {
        let dnsCoordinator = EngineDNSCoordinatorSpy()
        let udpRouter = UDPRouterSpy()
        let engine = TunnelEngine(
            dnsCoordinator: dnsCoordinator,
            tcpRouter: EngineTCPRouterSpy(),
            udpRouter: udpRouter
        )

        try await engine.handleOutboundPacket(
            makeUDPPacket(destination: "223.5.5.5", destinationPort: 53, payload: "Q").data
        )

        let dnsHandleCalls = await dnsCoordinator.handleCallCount
        let udpRouteCalls = udpRouter.routeCallCount
        XCTAssertEqual(dnsHandleCalls, 1)
        XCTAssertEqual(udpRouteCalls, 0)
    }

    func testStopStopsUDPRouter() async throws {
        let udpRouter = UDPRouterSpy()
        let engine = TunnelEngine(
            dnsCoordinator: EngineDNSCoordinatorSpy(),
            tcpRouter: EngineTCPRouterSpy(),
            udpRouter: udpRouter
        )

        await engine.stop()

        let stopAllCalls = udpRouter.stopAllCallCount
        XCTAssertEqual(stopAllCalls, 1)
    }
}

private actor EngineDNSCoordinatorSpy: DNSCoordinating {
    private(set) var handleCallCount = 0

    func warmUpWhitelistCache() async {}

    func handle(_ packet: IPPacket) async throws {
        handleCallCount += 1
    }
}

private final class UDPRouterSpy: UDPRouting, @unchecked Sendable {
    private let lock = NSLock()
    private var routeCalls = 0
    private var stopAllCalls = 0

    var routeCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return routeCalls
    }

    var stopAllCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stopAllCalls
    }

    func route(_ packet: IPPacket) async throws {
        lock.lock()
        routeCalls += 1
        lock.unlock()
    }

    func stopAll() async {
        lock.lock()
        stopAllCalls += 1
        lock.unlock()
    }

    func setPacketWriter(_ packetWriter: (any TunnelPacketWriting)?) {}
}

private final class EngineTCPRouterSpy: TCPRouting {
    func route(_ packet: IPPacket) async throws {}
    func stopAll() async {}
    func setPacketWriter(_ packetWriter: (any TunnelPacketWriting)?) {}
}
