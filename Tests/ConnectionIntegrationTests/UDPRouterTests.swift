import Darwin
import Foundation
import XCTest
import SharedCore
@testable import ShadowsocksOnePacketTunnel

final class UDPRouterTests: XCTestCase {
    func testUsesDirectRelayForCNTarget() async throws {
        let directFactory = UDPRelayFactorySpy()
        let proxyFactory = UDPRelayFactorySpy()
        let router = makeRouter(
            decision: .direct,
            directFactory: { [directFactory] key in try directFactory.makeRelay(key: key) },
            proxyFactory: { [proxyFactory] key in try proxyFactory.makeRelay(key: key) }
        )

        try await router.route(makeUDPPacket(destination: "1.0.1.8", destinationPort: 443, payload: "PING"))

        XCTAssertEqual(directFactory.createdRelayCount, 1)
        XCTAssertEqual(proxyFactory.createdRelayCount, 0)
        XCTAssertEqual(directFactory.totalStartCalls, 1)
        XCTAssertEqual(directFactory.firstRelayForwardedPayloads, [Data("PING".utf8)])
    }

    func testUsesProxyRelayForForeignTarget() async throws {
        let directFactory = UDPRelayFactorySpy()
        let proxyFactory = UDPRelayFactorySpy()
        let router = makeRouter(
            decision: .proxy,
            directFactory: { [directFactory] key in try directFactory.makeRelay(key: key) },
            proxyFactory: { [proxyFactory] key in try proxyFactory.makeRelay(key: key) }
        )

        try await router.route(makeUDPPacket(destination: "142.250.72.196", destinationPort: 443, payload: "PING"))

        XCTAssertEqual(directFactory.createdRelayCount, 0)
        XCTAssertEqual(proxyFactory.createdRelayCount, 1)
        XCTAssertEqual(proxyFactory.totalStartCalls, 1)
        XCTAssertEqual(proxyFactory.firstRelayForwardedPayloads, [Data("PING".utf8)])
    }

    func testReusesRelayForSameFlow() async throws {
        let directFactory = UDPRelayFactorySpy()
        let router = makeRouter(
            decision: .direct,
            directFactory: { [directFactory] key in try directFactory.makeRelay(key: key) },
            proxyFactory: { key in try UDPRelayFactorySpy().makeRelay(key: key) }
        )

        try await router.route(makeUDPPacket(destination: "1.0.1.8", destinationPort: 443, payload: "A"))
        try await router.route(makeUDPPacket(destination: "1.0.1.8", destinationPort: 443, payload: "B"))

        XCTAssertEqual(directFactory.createdRelayCount, 1)
        XCTAssertEqual(directFactory.totalStartCalls, 1)
        XCTAssertEqual(directFactory.firstRelayForwardedPayloads, [Data("A".utf8), Data("B".utf8)])
    }

    func testUsesDirectRelayForWhitelistedDomainResolvedFromHost() async throws {
        let directFactory = UDPRelayFactorySpy()
        let proxyFactory = UDPRelayFactorySpy()
        let matcher = RouteMatcher(
            configuration: RoutingConfiguration(
                bypassCNIP: false,
                domainWhitelist: ["*.qq.com"]
            ),
            cnIPRanges: try! CNIPRangeList(ranges: [])
        )
        let router = makeRouter(
            matcher: matcher,
            directFactory: { [directFactory] key in try directFactory.makeRelay(key: key) },
            proxyFactory: { [proxyFactory] key in try proxyFactory.makeRelay(key: key) },
            hostResolver: { ip in ip == "203.0.113.10" ? "www.qq.com" : nil }
        )

        try await router.route(makeUDPPacket(destination: "203.0.113.10", destinationPort: 8000, payload: "RTP"))

        XCTAssertEqual(directFactory.createdRelayCount, 1)
        XCTAssertEqual(proxyFactory.createdRelayCount, 0)
    }

    func testWritesInboundDatagramBackWithFlippedAddresses() async throws {
        let directFactory = UDPRelayFactorySpy()
        let packetWriter = TunnelPacketWriterSpy()
        let router = makeRouter(
            decision: .direct,
            directFactory: { [directFactory] key in try directFactory.makeRelay(key: key) },
            proxyFactory: { key in try UDPRelayFactorySpy().makeRelay(key: key) },
            packetWriter: packetWriter
        )

        try await router.route(makeUDPPacket(destination: "1.0.1.8", destinationPort: 443, payload: "PING"))
        await directFactory.firstRelay?.emitInbound(Data("PONG".utf8))

        let written = try XCTUnwrap(packetWriter.writtenPackets.first)
        let packet = try IPPacket(data: written)
        let udp = try packet.udpSegment()

        XCTAssertEqual(packet.sourceAddress, "1.0.1.8")
        XCTAssertEqual(packet.destinationAddress, "10.0.0.2")
        XCTAssertEqual(udp.sourcePort, 443)
        XCTAssertEqual(udp.destinationPort, 49_152)
        XCTAssertEqual(udp.payload, Data("PONG".utf8))
        XCTAssertEqual(packetWriter.writtenProtocols, [NSNumber(value: AF_INET)])
    }

    func testStopAllStopsAllRelays() async throws {
        let directFactory = UDPRelayFactorySpy()
        let router = makeRouter(
            decision: .direct,
            directFactory: { [directFactory] key in try directFactory.makeRelay(key: key) },
            proxyFactory: { key in try UDPRelayFactorySpy().makeRelay(key: key) }
        )

        try await router.route(makeUDPPacket(destination: "1.0.1.8", destinationPort: 443, payload: "A"))
        try await router.route(makeUDPPacket(destination: "1.0.1.9", destinationPort: 443, payload: "B"))
        await router.stopAll()

        XCTAssertEqual(directFactory.createdRelayCount, 2)
        XCTAssertEqual(directFactory.totalStopCalls, 2)
    }

    func testEvictsOldestSessionBeyondCapacity() async throws {
        let directFactory = UDPRelayFactorySpy()
        var current = Date(timeIntervalSince1970: 1_000)
        let sessionStore = UDPSessionStore(capacity: 1, idleTimeout: 600, now: { current })
        let router = makeRouter(
            decision: .direct,
            sessionStore: sessionStore,
            directFactory: { [directFactory] key in try directFactory.makeRelay(key: key) },
            proxyFactory: { key in try UDPRelayFactorySpy().makeRelay(key: key) }
        )

        try await router.route(makeUDPPacket(destination: "1.0.1.8", destinationPort: 443, payload: "A"))
        current = current.addingTimeInterval(10)
        try await router.route(makeUDPPacket(destination: "1.0.1.9", destinationPort: 443, payload: "B"))

        XCTAssertEqual(directFactory.createdRelayCount, 2)
        try await assertEventually({ directFactory.totalStopCalls }, equals: 1)
    }

    private func makeRouter(
        decision: RouteDecision,
        sessionStore: UDPSessionStore = UDPSessionStore(),
        directFactory: @escaping UDPRouter.RelayFactory,
        proxyFactory: @escaping UDPRouter.RelayFactory,
        packetWriter: (any TunnelPacketWriting)? = nil
    ) -> UDPRouter {
        let matcher = RouteMatcher(
            configuration: RoutingConfiguration(
                bypassCNIP: decision == .direct,
                domainWhitelist: []
            ),
            cnIPRanges: try! CNIPRangeList(
                ranges: decision == .direct ? ["1.0.1.0/24"] : []
            )
        )

        return makeRouter(
            matcher: matcher,
            sessionStore: sessionStore,
            directFactory: directFactory,
            proxyFactory: proxyFactory,
            packetWriter: packetWriter
        )
    }

    private func makeRouter(
        matcher: RouteMatcher,
        sessionStore: UDPSessionStore = UDPSessionStore(),
        directFactory: @escaping UDPRouter.RelayFactory,
        proxyFactory: @escaping UDPRouter.RelayFactory,
        packetWriter: (any TunnelPacketWriting)? = nil,
        hostResolver: UDPRouter.HostResolver? = nil
    ) -> UDPRouter {
        UDPRouter(
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
            directRelayFactory: directFactory,
            proxyRelayFactory: proxyFactory,
            hostResolver: hostResolver
        )
    }

    private func assertEventually<T: Equatable>(
        _ actual: @escaping () -> T,
        equals expected: T,
        timeoutNanoseconds: UInt64 = 1_000_000_000
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if actual() == expected {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(actual(), expected)
    }
}
