import Foundation
import XCTest
import SharedCore
@testable import ShadowsocksOnePacketTunnel

final class TCPRouterTests: XCTestCase {
    func testUsesDirectRelayForWhitelistedTarget() async throws {
        let directFactory = RelayFactorySpy()
        let proxyFactory = RelayFactorySpy()
        let router = makeRouter(
            decision: .direct,
            directFactory: { [directFactory] key in try directFactory.makeRelay(key: key) },
            proxyFactory: { [proxyFactory] key in try proxyFactory.makeRelay(key: key) }
        )

        try await router.route(makeTCPPacket(destination: "1.0.1.8", port: 443, payload: "", flags: 0x02))
        try await router.route(makeTCPPacket(destination: "1.0.1.8", port: 443, payload: "", sequence: 2, flags: 0x10))
        try await router.route(makeTCPPacket(destination: "1.0.1.8", port: 443, payload: "GET", sequence: 2))

        let directCalls = directFactory.createdRelayCount
        let proxyCalls = proxyFactory.createdRelayCount
        let directStarts = directFactory.totalStartCalls
        let directPayloads = directFactory.firstRelayForwardedPayloads

        XCTAssertEqual(directCalls, 1)
        XCTAssertEqual(proxyCalls, 0)
        XCTAssertEqual(directStarts, 1)
        XCTAssertEqual(directPayloads, [Data("GET".utf8)])
    }

    func testUsesProxyRelayForForeignTarget() async throws {
        let directFactory = RelayFactorySpy()
        let proxyFactory = RelayFactorySpy()
        let router = makeRouter(
            decision: .proxy,
            directFactory: { [directFactory] key in try directFactory.makeRelay(key: key) },
            proxyFactory: { [proxyFactory] key in try proxyFactory.makeRelay(key: key) }
        )

        try await router.route(makeTCPPacket(destination: "142.250.72.196", port: 443, payload: "", flags: 0x02))
        try await router.route(makeTCPPacket(destination: "142.250.72.196", port: 443, payload: "", sequence: 2, flags: 0x10))
        try await router.route(makeTCPPacket(destination: "142.250.72.196", port: 443, payload: "PING", sequence: 2))

        let directCalls = directFactory.createdRelayCount
        let proxyCalls = proxyFactory.createdRelayCount
        let proxyStarts = proxyFactory.totalStartCalls
        let proxyPayloads = proxyFactory.firstRelayForwardedPayloads

        XCTAssertEqual(directCalls, 0)
        XCTAssertEqual(proxyCalls, 1)
        XCTAssertEqual(proxyStarts, 1)
        XCTAssertEqual(proxyPayloads, [Data("PING".utf8)])
    }

    func testReusesExistingRelayForSameFlow() async throws {
        let directFactory = RelayFactorySpy()
        let router = makeRouter(
            decision: .direct,
            directFactory: { [directFactory] key in try directFactory.makeRelay(key: key) },
            proxyFactory: { key in try RelayFactorySpy().makeRelay(key: key) }
        )

        try await router.route(makeTCPPacket(destination: "1.0.1.8", port: 443, payload: "", flags: 0x02))
        try await router.route(makeTCPPacket(destination: "1.0.1.8", port: 443, payload: "", sequence: 2, flags: 0x10))
        try await router.route(makeTCPPacket(destination: "1.0.1.8", port: 443, payload: "HELLO", sequence: 2))
        try await router.route(makeTCPPacket(destination: "1.0.1.8", port: 443, payload: "WORLD", sequence: 7))

        let directCalls = directFactory.createdRelayCount
        let starts = directFactory.totalStartCalls
        let payloads = directFactory.firstRelayForwardedPayloads

        XCTAssertEqual(directCalls, 1)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(payloads, [Data("HELLO".utf8), Data("WORLD".utf8)])
    }

    func testFINRemovesRelayFromSessionStore() async throws {
        let directFactory = RelayFactorySpy()
        let router = makeRouter(
            decision: .direct,
            directFactory: { [directFactory] key in try directFactory.makeRelay(key: key) },
            proxyFactory: { key in try RelayFactorySpy().makeRelay(key: key) }
        )

        try await router.route(makeTCPPacket(destination: "1.0.1.8", port: 443, payload: "", flags: 0x02))
        try await router.route(makeTCPPacket(destination: "1.0.1.8", port: 443, payload: "", sequence: 2, flags: 0x10))
        try await router.route(makeTCPPacket(destination: "1.0.1.8", port: 443, payload: "BODY", sequence: 2))
        try await router.route(makeTCPPacket(destination: "1.0.1.8", port: 443, payload: "", sequence: 6, flags: 0x11))
        try await router.route(makeTCPPacket(destination: "1.0.1.8", port: 443, payload: "", flags: 0x02))
        try await router.route(makeTCPPacket(destination: "1.0.1.8", port: 443, payload: "", sequence: 2, flags: 0x10))
        try await router.route(makeTCPPacket(destination: "1.0.1.8", port: 443, payload: "NEXT", sequence: 2))

        let directCalls = directFactory.createdRelayCount
        let stops = directFactory.totalStopCalls
        let payloads = directFactory.allForwardedPayloads

        XCTAssertEqual(directCalls, 2)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(payloads, [Data("BODY".utf8), Data("NEXT".utf8)])
    }

    func testUsesDirectRelayForWhitelistedDomainResolvedFromHost() async throws {
        let directFactory = RelayFactorySpy()
        let proxyFactory = RelayFactorySpy()
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

        try await router.route(makeTCPPacket(destination: "203.0.113.10", port: 443, payload: "", flags: 0x02))

        XCTAssertEqual(directFactory.createdRelayCount, 1)
        XCTAssertEqual(proxyFactory.createdRelayCount, 0)
    }

    func testUsesProxyRelayWhenHostResolverMisses() async throws {
        let directFactory = RelayFactorySpy()
        let proxyFactory = RelayFactorySpy()
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
            hostResolver: { _ in nil }
        )

        try await router.route(makeTCPPacket(destination: "142.250.72.196", port: 443, payload: "", flags: 0x02))

        XCTAssertEqual(directFactory.createdRelayCount, 0)
        XCTAssertEqual(proxyFactory.createdRelayCount, 1)
    }

    private func makeRouter(
        decision: RouteDecision,
        directFactory: @escaping TCPRouter.RelayFactory,
        proxyFactory: @escaping TCPRouter.RelayFactory
    ) -> TCPRouter {
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
            directFactory: directFactory,
            proxyFactory: proxyFactory
        )
    }

    private func makeRouter(
        matcher: RouteMatcher,
        directFactory: @escaping TCPRouter.RelayFactory,
        proxyFactory: @escaping TCPRouter.RelayFactory,
        hostResolver: TCPRouter.HostResolver? = nil
    ) -> TCPRouter {
        TCPRouter(
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
            directRelayFactory: directFactory,
            proxyRelayFactory: proxyFactory,
            hostResolver: hostResolver
        )
    }
}

private final class RelayFactorySpy: @unchecked Sendable {
    private let lock = NSLock()
    private var relays: [RelaySpy] = []

    var createdRelayCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return relays.count
    }

    var totalStartCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return relays.reduce(0) { $0 + $1.startCalls }
    }

    var totalStopCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return relays.reduce(0) { $0 + $1.stopCalls }
    }

    var allForwardedPayloads: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return relays.flatMap(\.forwardedPayloads)
    }

    var firstRelayForwardedPayloads: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return relays.first?.forwardedPayloads ?? []
    }

    func makeRelay(key: TCPFlowKey) throws -> any TCPFlowRelaying {
        let relay = RelaySpy(key: key)
        lock.lock()
        relays.append(relay)
        lock.unlock()
        return relay
    }
}

private final class RelaySpy: TCPFlowRelaying {
    let key: TCPFlowKey
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var forwardedPayloads: [Data] = []
    let queuedOutboundBytes = 0
    var onInboundBytes: (@Sendable (Data) async -> Void)?
    var onClosed: (@Sendable () async -> Void)?

    init(key: TCPFlowKey) {
        self.key = key
    }

    func start() async throws {
        startCalls += 1
    }

    func forwardOutboundPayload(_ payload: Data) async throws {
        forwardedPayloads.append(payload)
    }

    func stop() async {
        stopCalls += 1
    }
}

private func makeTCPPacket(
    destination: String,
    port: UInt16,
    payload: String,
    sequence: UInt32 = 1,
    flags: UInt8 = 0x18
) -> IPPacket {
    let payloadBytes = Array(payload.utf8)
    let tcpHeader: [UInt8] = [
        0xC0, 0x00,
        UInt8(port >> 8),
        UInt8(port & 0x00FF),
        UInt8(sequence >> 24),
        UInt8((sequence >> 16) & 0x00FF),
        UInt8((sequence >> 8) & 0x00FF),
        UInt8(sequence & 0x00FF),
        0x00, 0x00, 0x00, 0x00,
        0x50, flags,
        0x20, 0x00,
        0x00, 0x00,
        0x00, 0x00,
    ] + payloadBytes

    return try! IPPacket(
        data: makeIPv4Packet(
            protocolNumber: 6,
            sourceAddress: [10, 0, 0, 2],
            destinationAddress: destination.split(separator: ".").compactMap { UInt8($0) },
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
