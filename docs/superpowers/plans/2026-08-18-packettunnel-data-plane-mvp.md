# PacketTunnel Data Plane MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `Shadowsocks One` 的系统 VPN 从“只亮 VPN 图标”升级为“Safari 可访问网页”，同时支持中国大陆 `CIDR` 和自定义域名白名单直连。

**Architecture:** 纯逻辑尽量下沉到 `SharedCore`，包括路由规则、数据包基础解析、DNS 缓存和 Shadowsocks TCP relay 编解码；`PacketTunnel` target 只保留 `NEPacketTunnelProvider` 生命周期、`packetFlow` 读写桥接与 `NetworkExtension` 相关装配。这样既能降低 `PacketTunnelProvider.swift` 复杂度，也能让核心逻辑通过 SwiftPM/XCTest 跑起来。

**Tech Stack:** Swift, Foundation, Network, NetworkExtension, SharedCore, XCTest, Swift Package Manager

---

## File Structure

本计划创建或修改的主要文件如下：

- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Routing/RoutingConfiguration.swift`
  - 白名单与中国 IP 直连配置模型
- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Routing/CNIPRangeList.swift`
  - 中国大陆 `CIDR` 资源加载与匹配
- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Routing/DomainMatchRule.swift`
  - 精确域名与 `*.example.com` 规则匹配
- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Routing/RouteMatcher.swift`
  - 统一判断 `direct` / `proxy`
- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Store/RoutingConfigurationStore.swift`
  - 白名单共享存储
- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Tunnel/IPPacket.swift`
  - IPv4 头部解析
- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Tunnel/TCPPacket.swift`
  - TCP 头部解析与 payload 提取
- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Tunnel/UDPPacket.swift`
  - DNS 所需 `UDP/53` 解析
- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Tunnel/DNSCache.swift`
  - 域名到 IP 的 TTL 缓存
- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Tunnel/ShadowsocksTCPTransport.swift`
  - 到 Shadowsocks 服务器的双向 TCP 字节流封装
- Create: `Shadowsocks One/Packages/SharedCore/Tests/SharedCoreTests/RouteMatcherTests.swift`
- Create: `Shadowsocks One/Packages/SharedCore/Tests/SharedCoreTests/RoutingConfigurationStoreTests.swift`
- Create: `Shadowsocks One/Packages/SharedCore/Tests/SharedCoreTests/IPPacketTests.swift`
- Create: `Shadowsocks One/Packages/SharedCore/Tests/SharedCoreTests/DNSCacheTests.swift`
- Create: `Shadowsocks One/PacketTunnel/TunnelEngine.swift`
  - `packetFlow` 主循环与包分发
- Create: `Shadowsocks One/PacketTunnel/TCP/TCPFlowKey.swift`
- Create: `Shadowsocks One/PacketTunnel/TCP/TCPFlowSessionStore.swift`
- Create: `Shadowsocks One/PacketTunnel/TCP/TCPFlowRelaying.swift`
- Create: `Shadowsocks One/PacketTunnel/TCP/DirectTCPRelay.swift`
- Create: `Shadowsocks One/PacketTunnel/TCP/ShadowsocksTCPRelay.swift`
- Create: `Shadowsocks One/PacketTunnel/DNS/DNSCoordinator.swift`
- Modify: `Shadowsocks One/PacketTunnel/PacketTunnelProvider.swift`
  - 只负责装配 `TunnelEngine`、应用网络设置和响应生命周期
- Modify: `Shadowsocks One/Shadowsocks One.xcodeproj/project.pbxproj`
  - 把新文件加入相应 target

---

### Task 1: 建立路由配置和白名单匹配基础

**Files:**
- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Routing/RoutingConfiguration.swift`
- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Routing/CNIPRangeList.swift`
- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Routing/DomainMatchRule.swift`
- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Routing/RouteMatcher.swift`
- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Store/RoutingConfigurationStore.swift`
- Test: `Shadowsocks One/Packages/SharedCore/Tests/SharedCoreTests/RouteMatcherTests.swift`
- Test: `Shadowsocks One/Packages/SharedCore/Tests/SharedCoreTests/RoutingConfigurationStoreTests.swift`

- [ ] **Step 1: 先写路由测试，锁定中国 IP 和域名白名单规则**

```swift
// SharedCoreTests/RouteMatcherTests.swift
import XCTest
@testable import SharedCore

final class RouteMatcherTests: XCTestCase {
    func testMatchesCNIPAddressAsDirect() throws {
        let matcher = RouteMatcher(
            configuration: RoutingConfiguration(
                bypassCNIP: true,
                domainWhitelist: []
            ),
            cnIPRanges: try CNIPRangeList(ranges: ["1.0.1.0/24"]),
            dnsCache: DNSCache(now: { Date(timeIntervalSince1970: 0) })
        )

        XCTAssertEqual(
            matcher.route(forHost: nil, ipString: "1.0.1.8"),
            .direct
        )
    }

    func testMatchesWildcardWhitelistedDomainAsDirect() throws {
        let cache = DNSCache(now: { Date(timeIntervalSince1970: 0) })
        cache.insert(
            domain: "www.qq.com",
            addresses: ["203.0.113.10"],
            ttl: 60
        )

        let matcher = RouteMatcher(
            configuration: RoutingConfiguration(
                bypassCNIP: true,
                domainWhitelist: ["*.qq.com"]
            ),
            cnIPRanges: try CNIPRangeList(ranges: []),
            dnsCache: cache
        )

        XCTAssertEqual(
            matcher.route(forHost: "www.qq.com", ipString: "203.0.113.10"),
            .direct
        )
    }

    func testFallsBackToProxyWhenNoRuleMatches() throws {
        let matcher = RouteMatcher(
            configuration: RoutingConfiguration(
                bypassCNIP: true,
                domainWhitelist: ["*.qq.com"]
            ),
            cnIPRanges: try CNIPRangeList(ranges: ["1.0.1.0/24"]),
            dnsCache: DNSCache(now: Date.init)
        )

        XCTAssertEqual(
            matcher.route(forHost: "www.google.com", ipString: "142.250.72.196"),
            .proxy
        )
    }
}
```

- [ ] **Step 2: 跑测试确认当前实现缺失**

Run: `swift test --filter RouteMatcherTests`

Expected: FAIL，提示 `RouteMatcher`、`RoutingConfiguration`、`DNSCache` 等类型不存在

- [ ] **Step 3: 写最小实现，先让路由层跑起来**

```swift
// SharedCore/Sources/SharedCore/Routing/RoutingConfiguration.swift
import Foundation

public struct RoutingConfiguration: Codable, Sendable, Equatable {
    public let bypassCNIP: Bool
    public let domainWhitelist: [String]

    public init(bypassCNIP: Bool, domainWhitelist: [String]) {
        self.bypassCNIP = bypassCNIP
        self.domainWhitelist = domainWhitelist
    }
}
```

```swift
// SharedCore/Sources/SharedCore/Routing/DomainMatchRule.swift
import Foundation

struct DomainMatchRule: Sendable, Equatable {
    let rawValue: String

    func matches(_ host: String) -> Bool {
        if rawValue.hasPrefix("*.") {
            let suffix = String(rawValue.dropFirst(1))
            return host.hasSuffix(suffix)
        }
        return host.caseInsensitiveCompare(rawValue) == .orderedSame
    }
}
```

```swift
// SharedCore/Sources/SharedCore/Routing/RouteMatcher.swift
import Foundation

public enum RouteDecision: String, Sendable, Equatable {
    case direct
    case proxy
}

public final class RouteMatcher {
    private let configuration: RoutingConfiguration
    private let cnIPRanges: CNIPRangeList
    private let dnsCache: DNSCache

    public init(
        configuration: RoutingConfiguration,
        cnIPRanges: CNIPRangeList,
        dnsCache: DNSCache
    ) {
        self.configuration = configuration
        self.cnIPRanges = cnIPRanges
        self.dnsCache = dnsCache
    }

    public func route(forHost host: String?, ipString: String) -> RouteDecision {
        if configuration.bypassCNIP, cnIPRanges.contains(ipString) {
            return .direct
        }

        guard let host else { return .proxy }
        let rules = configuration.domainWhitelist.map(DomainMatchRule.init(rawValue:))
        if rules.contains(where: { $0.matches(host) }),
           dnsCache.contains(domain: host, address: ipString) {
            return .direct
        }

        return .proxy
    }
}
```

- [ ] **Step 4: 补共享存储测试和实现**

```swift
// SharedCoreTests/RoutingConfigurationStoreTests.swift
import XCTest
@testable import SharedCore

final class RoutingConfigurationStoreTests: XCTestCase {
    func testSavesAndLoadsRoutingConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RoutingConfigurationStore(
            jsonURL: directory.appendingPathComponent("routing.json")
        )
        let configuration = RoutingConfiguration(
            bypassCNIP: true,
            domainWhitelist: ["*.qq.com", "taobao.com"]
        )

        try store.save(configuration)
        XCTAssertEqual(try store.load(), configuration)
    }
}
```

```swift
// SharedCore/Sources/SharedCore/Store/RoutingConfigurationStore.swift
import Foundation

public final class RoutingConfigurationStore {
    private let jsonURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(jsonURL: URL) {
        self.jsonURL = jsonURL
    }

    public func save(_ configuration: RoutingConfiguration) throws {
        let data = try encoder.encode(configuration)
        try data.write(to: jsonURL, options: .atomic)
    }

    public func load() throws -> RoutingConfiguration {
        let data = try Data(contentsOf: jsonURL)
        return try decoder.decode(RoutingConfiguration.self, from: data)
    }
}
```

- [ ] **Step 5: 跑 `SharedCore` 测试并提交这一小步**

Run: `swift test --filter 'RouteMatcherTests|RoutingConfigurationStoreTests'`

Expected: PASS

Commit:

```bash
git add "Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Routing" \
        "Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Store/RoutingConfigurationStore.swift" \
        "Shadowsocks One/Packages/SharedCore/Tests/SharedCoreTests/RouteMatcherTests.swift" \
        "Shadowsocks One/Packages/SharedCore/Tests/SharedCoreTests/RoutingConfigurationStoreTests.swift"
git commit -m "$(cat <<'EOF'
feat(ios): add packet tunnel routing rules

Add shared routing configuration, China IP matching, and domain whitelist matching so PacketTunnel can decide between direct and proxied traffic.
EOF
)"
```

---

### Task 2: 建立 IP/TCP/UDP 基础解析和 DNS 缓存

**Files:**
- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Tunnel/IPPacket.swift`
- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Tunnel/TCPPacket.swift`
- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Tunnel/UDPPacket.swift`
- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Tunnel/DNSCache.swift`
- Test: `Shadowsocks One/Packages/SharedCore/Tests/SharedCoreTests/IPPacketTests.swift`
- Test: `Shadowsocks One/Packages/SharedCore/Tests/SharedCoreTests/DNSCacheTests.swift`

- [ ] **Step 1: 先写测试，锁定最小 IPv4/TCP/UDP 解析结果**

```swift
// SharedCoreTests/IPPacketTests.swift
import XCTest
@testable import SharedCore

final class IPPacketTests: XCTestCase {
    func testParsesIPv4TCPPacket() throws {
        let packet = try IPPacket(data: Data([
            0x45, 0x00, 0x00, 0x28, 0x00, 0x00, 0x40, 0x00,
            0x40, 0x06, 0x00, 0x00, 10, 0, 0, 2,
            142, 250, 72, 196,
            0x1F, 0x90, 0x01, 0xBB, 0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00, 0x50, 0x02, 0xFA, 0xF0,
            0x00, 0x00, 0x00, 0x00
        ]))

        XCTAssertEqual(packet.protocolNumber, 6)
        XCTAssertEqual(packet.sourceAddress, "10.0.0.2")
        XCTAssertEqual(packet.destinationAddress, "142.250.72.196")
        XCTAssertEqual(try packet.tcpSegment().destinationPort, 443)
    }
}
```

```swift
// SharedCoreTests/DNSCacheTests.swift
import XCTest
@testable import SharedCore

final class DNSCacheTests: XCTestCase {
    func testExpiresCachedAddressAfterTTL() {
        var now = Date(timeIntervalSince1970: 0)
        let cache = DNSCache(now: { now })
        cache.insert(domain: "www.qq.com", addresses: ["203.0.113.10"], ttl: 10)

        XCTAssertTrue(cache.contains(domain: "www.qq.com", address: "203.0.113.10"))
        now = Date(timeIntervalSince1970: 11)
        XCTAssertFalse(cache.contains(domain: "www.qq.com", address: "203.0.113.10"))
    }
}
```

- [ ] **Step 2: 跑测试确认解析层尚未存在**

Run: `swift test --filter 'IPPacketTests|DNSCacheTests'`

Expected: FAIL，提示 `IPPacket` / `DNSCache` 不存在

- [ ] **Step 3: 实现最小解析器和 TTL 缓存**

```swift
// SharedCore/Sources/SharedCore/Tunnel/IPPacket.swift
import Foundation

public struct IPPacket: Sendable {
    public let data: Data
    public let protocolNumber: UInt8
    public let sourceAddress: String
    public let destinationAddress: String
    private let headerLength: Int

    public init(data: Data) throws {
        guard data.count >= 20, (data[0] >> 4) == 4 else {
            throw TunnelPacketError.invalidIPv4Packet
        }

        self.data = data
        self.headerLength = Int(data[0] & 0x0F) * 4
        self.protocolNumber = data[9]
        self.sourceAddress = [12, 13, 14, 15].map { String(data[$0]) }.joined(separator: ".")
        self.destinationAddress = [16, 17, 18, 19].map { String(data[$0]) }.joined(separator: ".")
    }

    public func tcpSegment() throws -> TCPPacket {
        try TCPPacket(data: data.dropFirst(headerLength))
    }

    public func udpSegment() throws -> UDPPacket {
        try UDPPacket(data: data.dropFirst(headerLength))
    }
}
```

```swift
// SharedCore/Sources/SharedCore/Tunnel/DNSCache.swift
import Foundation

public final class DNSCache {
    private struct Entry {
        let addresses: Set<String>
        let expiresAt: Date
    }

    private let now: () -> Date
    private var storage: [String: Entry] = [:]

    public init(now: @escaping () -> Date) {
        self.now = now
    }

    public func insert(domain: String, addresses: [String], ttl: TimeInterval) {
        storage[domain.lowercased()] = Entry(
            addresses: Set(addresses),
            expiresAt: now().addingTimeInterval(ttl)
        )
    }

    public func contains(domain: String, address: String) -> Bool {
        guard let entry = storage[domain.lowercased()],
              entry.expiresAt > now() else {
            storage.removeValue(forKey: domain.lowercased())
            return false
        }

        return entry.addresses.contains(address)
    }
}
```

- [ ] **Step 4: 运行测试并提交**

Run: `swift test --filter 'IPPacketTests|DNSCacheTests'`

Expected: PASS

Commit:

```bash
git add "Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Tunnel" \
        "Shadowsocks One/Packages/SharedCore/Tests/SharedCoreTests/IPPacketTests.swift" \
        "Shadowsocks One/Packages/SharedCore/Tests/SharedCoreTests/DNSCacheTests.swift"
git commit -m "$(cat <<'EOF'
feat(ios): add packet parsing primitives for tunnel engine

Add IPv4/TCP/UDP parsing helpers and DNS TTL cache so the tunnel can classify packets and remember whitelist resolutions.
EOF
)"
```

---

### Task 3: 实现 DNS 协调器和直连/代理路由决策入口

**Files:**
- Create: `Shadowsocks One/PacketTunnel/DNS/DNSCoordinator.swift`
- Create: `Shadowsocks One/PacketTunnel/TunnelEngine.swift`
- Modify: `Shadowsocks One/PacketTunnel/PacketTunnelProvider.swift`
- Test: `Shadowsocks One/Tests/ConnectionIntegrationTests/PacketTunnelEngineTests.swift`

- [ ] **Step 1: 写失败测试，锁定 DNS 包会被 `DNSCoordinator` 拦截，TCP 包会走路由器**

```swift
// ConnectionIntegrationTests/PacketTunnelEngineTests.swift
import XCTest
import SharedCore
@testable import ShadowsocksOnePacketTunnel

final class PacketTunnelEngineTests: XCTestCase {
    func testRoutesDNSPacketToDNSCoordinator() async throws {
        let dnsCoordinator = DNSCoordinatorSpy()
        let router = TCPRouterSpy()
        let engine = TunnelEngine(
            dnsCoordinator: dnsCoordinator,
            tcpRouter: router
        )

        try await engine.handleOutboundPacket(makeDNSPacket())

        XCTAssertEqual(dnsCoordinator.handleCalls, 1)
        XCTAssertEqual(router.routeCalls, 0)
    }
}
```

- [ ] **Step 2: 跑测试确认 `TunnelEngine` 还不存在**

Run: `xcodebuild -project "/Users/fitz/REPO/ShadowsocksX-NG/Shadowsocks One/Shadowsocks One.xcodeproj" -scheme "Shadowsocks One" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ConnectionIntegrationTests/PacketTunnelEngineTests test`

Expected: FAIL

- [ ] **Step 3: 写最小 `DNSCoordinator` 与 `TunnelEngine` 骨架**

```swift
// PacketTunnel/DNS/DNSCoordinator.swift
import Foundation
import SharedCore

protocol DNSCoordinating: AnyObject {
    func handle(_ packet: IPPacket) async throws
    func warmUpWhitelistCache() async
}

final class DNSCoordinator: DNSCoordinating {
    private let cache: DNSCache
    private let whitelist: [String]

    init(cache: DNSCache, whitelist: [String]) {
        self.cache = cache
        self.whitelist = whitelist
    }

    func warmUpWhitelistCache() async {
        for host in whitelist {
            let addresses = (try? await DNSResolver.resolve(host: host)) ?? []
            if !addresses.isEmpty {
                cache.insert(domain: host, addresses: addresses, ttl: 300)
            }
        }
    }

    func handle(_ packet: IPPacket) async throws {
        _ = try packet.udpSegment()
    }
}
```

```swift
// PacketTunnel/TunnelEngine.swift
import Foundation
import SharedCore

protocol TCPRouting: AnyObject {
    func route(_ packet: IPPacket) async throws
}

final class TunnelEngine {
    private let dnsCoordinator: any DNSCoordinating
    private let tcpRouter: any TCPRouting

    init(
        dnsCoordinator: any DNSCoordinating,
        tcpRouter: any TCPRouting
    ) {
        self.dnsCoordinator = dnsCoordinator
        self.tcpRouter = tcpRouter
    }

    func handleOutboundPacket(_ data: Data) async throws {
        let packet = try IPPacket(data: data)
        switch packet.protocolNumber {
        case 17:
            let udp = try packet.udpSegment()
            if udp.destinationPort == 53 {
                try await dnsCoordinator.handle(packet)
            }
        case 6:
            try await tcpRouter.route(packet)
        default:
            break
        }
    }
}
```

- [ ] **Step 4: 把 `PacketTunnelProvider` 改成装配 `TunnelEngine`**

```swift
// PacketTunnel/PacketTunnelProvider.swift
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var engine: TunnelEngine?

    override func startTunnel(
        options: [String : NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            let launch = try TunnelConfigurationStore(
                appGroupID: SharedContainerSettings.appGroupID,
                keychainService: SharedContainerSettings.keychainService
            ).loadLaunchConfiguration()
            let routing = try loadRoutingConfiguration()
            let dnsCache = DNSCache(now: Date.init)
            let matcher = RouteMatcher(
                configuration: routing,
                cnIPRanges: try loadCNIPRanges(),
                dnsCache: dnsCache
            )
            let dnsCoordinator = DNSCoordinator(
                cache: dnsCache,
                whitelist: routing.domainWhitelist
            )
            let tcpRouter = TCPRouter(
                launchConfiguration: launch,
                matcher: matcher,
                packetFlow: packetFlow
            )
            self.engine = TunnelEngine(
                dnsCoordinator: dnsCoordinator,
                tcpRouter: tcpRouter
            )
            applyNetworkSettings(completionHandler: completionHandler)
        } catch {
            completionHandler(error)
        }
    }
}
```

- [ ] **Step 5: 跑测试并提交**

Run: `xcodebuild -project "/Users/fitz/REPO/ShadowsocksX-NG/Shadowsocks One/Shadowsocks One.xcodeproj" -scheme "Shadowsocks One" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ConnectionIntegrationTests/PacketTunnelEngineTests test`

Expected: PASS

Commit:

```bash
git add "Shadowsocks One/PacketTunnel/DNS/DNSCoordinator.swift" \
        "Shadowsocks One/PacketTunnel/TunnelEngine.swift" \
        "Shadowsocks One/PacketTunnel/PacketTunnelProvider.swift" \
        "Shadowsocks One/Tests/ConnectionIntegrationTests/PacketTunnelEngineTests.swift" \
        "Shadowsocks One/Shadowsocks One.xcodeproj/project.pbxproj"
git commit -m "$(cat <<'EOF'
feat(ios): add packet tunnel engine skeleton

Introduce the tunnel engine, DNS coordinator, and provider wiring so outbound packets can be split between DNS handling and TCP routing.
EOF
)"
```

---

### Task 4: 打通 TCP 会话存储、直连 relay 和 Shadowsocks relay

**Files:**
- Create: `Shadowsocks One/PacketTunnel/TCP/TCPFlowKey.swift`
- Create: `Shadowsocks One/PacketTunnel/TCP/TCPFlowRelaying.swift`
- Create: `Shadowsocks One/PacketTunnel/TCP/TCPFlowSessionStore.swift`
- Create: `Shadowsocks One/PacketTunnel/TCP/DirectTCPRelay.swift`
- Create: `Shadowsocks One/PacketTunnel/TCP/ShadowsocksTCPRelay.swift`
- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Tunnel/ShadowsocksTCPTransport.swift`
- Test: `Shadowsocks One/Tests/ConnectionIntegrationTests/TCPRouterTests.swift`

- [ ] **Step 1: 先写测试，锁定白名单走直连、其余走 Shadowsocks**

```swift
// ConnectionIntegrationTests/TCPRouterTests.swift
import XCTest
import SharedCore
@testable import ShadowsocksOnePacketTunnel

final class TCPRouterTests: XCTestCase {
    func testUsesDirectRelayForWhitelistedTarget() async throws {
        let router = makeRouter(decision: .direct)
        try await router.route(makeTCPPacket(destination: "1.0.1.8", port: 443))
        XCTAssertEqual(router.directRelayStartCalls, 1)
        XCTAssertEqual(router.proxyRelayStartCalls, 0)
    }

    func testUsesProxyRelayForForeignTarget() async throws {
        let router = makeRouter(decision: .proxy)
        try await router.route(makeTCPPacket(destination: "142.250.72.196", port: 443))
        XCTAssertEqual(router.directRelayStartCalls, 0)
        XCTAssertEqual(router.proxyRelayStartCalls, 1)
    }
}
```

- [ ] **Step 2: 跑测试确认 TCP 路由器与 relay 还不存在**

Run: `xcodebuild -project "/Users/fitz/REPO/ShadowsocksX-NG/Shadowsocks One/Shadowsocks One.xcodeproj" -scheme "Shadowsocks One" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ConnectionIntegrationTests/TCPRouterTests test`

Expected: FAIL

- [ ] **Step 3: 写最小 TCP session store 和 relay 协议**

```swift
// PacketTunnel/TCP/TCPFlowKey.swift
import Foundation
import SharedCore

struct TCPFlowKey: Hashable, Sendable {
    let sourceAddress: String
    let sourcePort: UInt16
    let destinationAddress: String
    let destinationPort: UInt16

    init(packet: IPPacket) throws {
        let tcp = try packet.tcpSegment()
        self.sourceAddress = packet.sourceAddress
        self.sourcePort = tcp.sourcePort
        self.destinationAddress = packet.destinationAddress
        self.destinationPort = tcp.destinationPort
    }
}
```

```swift
// PacketTunnel/TCP/TCPFlowRelaying.swift
import Foundation

protocol TCPFlowRelaying: AnyObject {
    func start() async throws
    func forwardOutboundPayload(_ payload: Data) async throws
    func stop() async
}
```

```swift
// PacketTunnel/TCP/TCPFlowSessionStore.swift
import Foundation

final class TCPFlowSessionStore {
    private var relays: [TCPFlowKey: any TCPFlowRelaying] = [:]

    func relay(for key: TCPFlowKey) -> (any TCPFlowRelaying)? {
        relays[key]
    }

    func setRelay(_ relay: any TCPFlowRelaying, for key: TCPFlowKey) {
        relays[key] = relay
    }

    func removeRelay(for key: TCPFlowKey) {
        relays.removeValue(forKey: key)
    }
}
```

- [ ] **Step 4: 实现最小直连和代理 relay**

```swift
// PacketTunnel/TCP/DirectTCPRelay.swift
import Foundation
import Network

final class DirectTCPRelay: TCPFlowRelaying {
    private let connection: NWConnection

    init(host: String, port: UInt16) {
        self.connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
    }

    func start() async throws {
        connection.start(queue: .global())
    }

    func forwardOutboundPayload(_ payload: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            })
        }
    }

    func stop() async {
        connection.cancel()
    }
}
```

```swift
// SharedCore/Tunnel/ShadowsocksTCPTransport.swift
import Foundation
import Network

public final class ShadowsocksTCPTransport {
    private let connection: NWConnection
    private let encoder: ShadowsocksStreamEncoder
    private let decoder: ShadowsocksStreamDecoder

    public init(config: ConnectionConfig, destinationHost: String, destinationPort: UInt16) {
        self.connection = NWConnection(
            host: NWEndpoint.Host(config.host),
            port: NWEndpoint.Port(rawValue: config.port)!,
            using: .tcp
        )
        let masterKey = ShadowsocksSessionKey.makeMasterKey(config: config)
        self.encoder = ShadowsocksStreamEncoder(
            method: config.method,
            masterKey: masterKey,
            addressHeader: try! ShadowsocksAddressEncoder.encode(
                host: destinationHost,
                port: destinationPort
            )
        )
        self.decoder = ShadowsocksStreamDecoder(
            method: config.method,
            masterKey: masterKey
        )
    }
}
```

- [ ] **Step 5: 运行测试并提交**

Run: `xcodebuild -project "/Users/fitz/REPO/ShadowsocksX-NG/Shadowsocks One/Shadowsocks One.xcodeproj" -scheme "Shadowsocks One" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ConnectionIntegrationTests/TCPRouterTests test`

Expected: PASS

Commit:

```bash
git add "Shadowsocks One/PacketTunnel/TCP" \
        "Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Tunnel/ShadowsocksTCPTransport.swift" \
        "Shadowsocks One/Tests/ConnectionIntegrationTests/TCPRouterTests.swift" \
        "Shadowsocks One/Shadowsocks One.xcodeproj/project.pbxproj"
git commit -m "$(cat <<'EOF'
feat(ios): add tcp relays for packet tunnel

Add direct and Shadowsocks TCP relay building blocks so PacketTunnel can choose between bypassed and proxied outbound flows.
EOF
)"
```

---

### Task 5: 集成到 `PacketTunnelProvider` 并完成真机冒烟闭环

**Files:**
- Modify: `Shadowsocks One/PacketTunnel/PacketTunnelProvider.swift`
- Modify: `Shadowsocks One/App/RootViewModel.swift`
- Modify: `Shadowsocks One/App/SystemTunnelManager.swift`
- Test: `Shadowsocks One/Tests/ConnectionIntegrationTests/RootViewModelSystemTunnelTests.swift`

- [ ] **Step 1: 写失败测试，锁定数据面失败信息能回传到 App**

```swift
// ConnectionIntegrationTests/RootViewModelSystemTunnelTests.swift
func testShowsDataPlaneFailureMessage() async throws {
    let tunnelController = TunnelControllerSpy()
    tunnelController.yield(.failed("dns bootstrap failed"))

    let viewModel = makeViewModel(tunnelController: tunnelController)
    try await Task.sleep(nanoseconds: 50_000_000)

    XCTAssertEqual(viewModel.message, "系统 VPN 启动失败：dns bootstrap failed")
}
```

- [ ] **Step 2: 跑测试确认失败提示没有回归**

Run: `xcodebuild -project "/Users/fitz/REPO/ShadowsocksX-NG/Shadowsocks One/Shadowsocks One.xcodeproj" -scheme "Shadowsocks One" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ConnectionIntegrationTests/RootViewModelSystemTunnelTests test`

Expected: PASS

- [ ] **Step 3: 集成 `TunnelEngine` 读包循环，确保 stopTunnel 会回收资源**

```swift
// PacketTunnel/PacketTunnelProvider.swift
override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
) {
    Task {
        await engine?.stop()
        engine = nil
        completionHandler()
    }
}
```

```swift
// PacketTunnel/TunnelEngine.swift
func start() {
    packetReaderTask = Task {
        while !Task.isCancelled {
            let packets = await readPackets()
            for packet in packets {
                try await handleOutboundPacket(packet)
            }
        }
    }
}

func stop() async {
    packetReaderTask?.cancel()
    packetReaderTask = nil
    await tcpRouter.stopAll()
}
```

- [ ] **Step 4: 执行自动化测试和真机冒烟**

Run:
- `swift test`
- `xcodebuild -project "/Users/fitz/REPO/ShadowsocksX-NG/Shadowsocks One/Shadowsocks One.xcodeproj" -scheme "Shadowsocks One" -destination 'generic/platform=iOS' build`

真机检查：
1. 连接节点后 `VPN` 图标出现
2. `https://www.google.com` 可访问
3. `https://www.bilibili.com` 可访问且命中直连日志
4. 断开 VPN 后系统网络恢复

Expected:
- 测试全部通过
- 真机网页访问成立

- [ ] **Step 5: 提交集成收尾**

```bash
git add "Shadowsocks One/App/RootViewModel.swift" \
        "Shadowsocks One/App/SystemTunnelManager.swift" \
        "Shadowsocks One/PacketTunnel/PacketTunnelProvider.swift" \
        "Shadowsocks One/PacketTunnel/TunnelEngine.swift" \
        "Shadowsocks One/Tests/ConnectionIntegrationTests/RootViewModelSystemTunnelTests.swift" \
        "Shadowsocks One/Shadowsocks One.xcodeproj/project.pbxproj"
git commit -m "$(cat <<'EOF'
feat(ios): wire packet tunnel data plane into system vpn

Integrate the tunnel engine, DNS handling, and direct/proxied TCP relays so the system VPN can carry real web traffic with basic bypass rules.
EOF
)"
```

---

## Self-Review

- 设计要求的 `IPv4 + TCP + DNS` 在 Task 2-5 都有对应落点
- 中国 `CIDR` 和自定义域名白名单在 Task 1 落地
- 真机网页可用与日志观察在 Task 5 落地
- 未把 `UDP`、`IPv6`、复杂规则语言扩进本计划

## Notes

- 这个计划最重的部分是 `PacketTunnel` 最小 TCP 适配层。执行时如果发现单纯依赖当前 `TCPPacket` 分包还不足以让 Safari 成立，需要优先补齐 `SYN/ACK/FIN` 状态管理，而不是先扩功能面。
- 所有新增文件都应控制体积，优先做小文件拆分，不要把数据面重新堆回 `PacketTunnelProvider.swift`。
