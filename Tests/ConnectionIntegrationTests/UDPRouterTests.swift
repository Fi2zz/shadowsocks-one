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
        try await assertEventually({ directFactory.totalStartCalls }, equals: 1)
        try await assertEventually(
            { directFactory.firstRelayForwardedPayloads },
            equals: [Data("PING".utf8)]
        )
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
        try await assertEventually({ proxyFactory.totalStartCalls }, equals: 1)
        try await assertEventually(
            { proxyFactory.firstRelayForwardedPayloads },
            equals: [Data("PING".utf8)]
        )
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
        try await assertEventually({ directFactory.firstRelayForwardedPayloads.count }, equals: 2)
        XCTAssertEqual(
            Set(directFactory.firstRelayForwardedPayloads),
            Set([Data("A".utf8), Data("B".utf8)])
        )
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

    /// 回归用例：relay 启动永久挂起时 route 必须立即返回（不阻塞引擎读包循环），
    /// 超时后回收会话，后续报文重建新 relay。
    func testHangingRelayStartReturnsImmediatelyAndTearsDownAfterTimeout() async throws {
        let hangingRelay = HangingUDPRelaySpy()
        let directFactory = UDPRelayFactorySpy()
        let relaySource = RelaySourceSpy(hangingRelay: hangingRelay, fallbackFactory: directFactory)
        let router = makeRouter(
            decision: .direct,
            relayTimeoutNanoseconds: 50_000_000,
            directFactory: { key in try relaySource.makeRelay(key: key) },
            proxyFactory: { key in try UDPRelayFactorySpy().makeRelay(key: key) }
        )

        try await router.route(makeUDPPacket(destination: "1.0.1.8", destinationPort: 443, payload: "A"))

        try await assertEventually({ hangingRelay.stopCalls }, equals: 1)

        relaySource.serveHangingRelay = false
        try await router.route(makeUDPPacket(destination: "1.0.1.8", destinationPort: 443, payload: "B"))
        try await assertEventually({ directFactory.createdRelayCount }, equals: 1)
        try await assertEventually(
            { directFactory.firstRelayForwardedPayloads },
            equals: [Data("B".utf8)]
        )
    }

    private func makeRouter(
        decision: RouteDecision,
        sessionStore: UDPSessionStore = UDPSessionStore(),
        relayTimeoutNanoseconds: UInt64 = 5_000_000_000,
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
            relayTimeoutNanoseconds: relayTimeoutNanoseconds,
            directFactory: directFactory,
            proxyFactory: proxyFactory,
            packetWriter: packetWriter
        )
    }

    private func makeRouter(
        matcher: RouteMatcher,
        sessionStore: UDPSessionStore = UDPSessionStore(),
        relayTimeoutNanoseconds: UInt64 = 5_000_000_000,
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
            hostResolver: hostResolver,
            relayTimeoutNanoseconds: relayTimeoutNanoseconds
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

private final class HangingUDPRelaySpy: UDPFlowRelaying {
    private(set) var stopCalls = 0
    var onInboundDatagram: (@Sendable (Data) async -> Void)?
    var onClosed: (@Sendable () async -> Void)?

    func start() async throws {
        try await Task.sleep(nanoseconds: .max)
    }

    func forwardOutboundPayload(_ payload: Data) async throws {}

    func stop() async {
        stopCalls += 1
    }
}

private final class RelaySourceSpy: @unchecked Sendable {
    private let lock = NSLock()
    private let hangingRelay: HangingUDPRelaySpy
    private let fallbackFactory: UDPRelayFactorySpy
    private var hangingEnabled = true

    var serveHangingRelay: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return hangingEnabled
        }
        set {
            lock.lock()
            hangingEnabled = newValue
            lock.unlock()
        }
    }

    init(hangingRelay: HangingUDPRelaySpy, fallbackFactory: UDPRelayFactorySpy) {
        self.hangingRelay = hangingRelay
        self.fallbackFactory = fallbackFactory
    }

    func makeRelay(key: UDPFlowKey) throws -> any UDPFlowRelaying {
        guard serveHangingRelay else {
            return try fallbackFactory.makeRelay(key: key)
        }
        return hangingRelay
    }
}
