# PacketTunnel TCP Return Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 `Shadowsocks One` 的 `PacketTunnel` 补齐最小 TCP 回包闭环：把 relay 收到的远端字节流重新封装成 IPv4/TCP 包写回 `packetFlow`，并维护一套只覆盖 `SYN / ACK / PSH / FIN / RST` 的最小状态机。

**Architecture:** 这一轮不追求完整网页兼容，只追求“系统 tunnel 不再只有出站、而是具备最小回程能力”。`SharedCore` 负责最小 TCP/IP 封包与校验逻辑，`PacketTunnel` 负责 flow 状态、读写桥接与 relay 事件分发。DNS、域名白名单联动、复杂 TCP 选项和更广泛协议兼容，全部留到下一轮。

**Tech Stack:** Swift, Foundation, Network, NetworkExtension, SharedCore, XCTest

---

## Scope

这份计划只解决下面 4 件事：

1. 构造可写回 `packetFlow` 的最小 IPv4/TCP 回包
2. 维护单个 TCP flow 的最小状态流转
3. 把 `DirectTCPRelay` / `ShadowsocksTCPRelay` 的入站字节流回写到系统
4. 在 `PacketTunnel` 内建立可测试的“读包 -> relay -> 回包写回”闭环

明确不包含：

- DNS 真正请求/响应闭环
- 域名白名单与 DNS 结果联动
- 完整 TCP 状态机
- TCP options 细解析
- IPv6
- UDP 通用代理
- “Safari 一定可访问网页”的承诺

---

## File Structure

本计划创建或修改的主要文件如下：

- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Tunnel/TCPPacketBuilder.swift`
  - 负责构造最小 IPv4/TCP 回包
- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Tunnel/InternetChecksum.swift`
  - IPv4 / TCP 所需校验和计算
- Create: `Shadowsocks One/Packages/SharedCore/Tests/SharedCoreTests/TCPPacketBuilderTests.swift`
  - 覆盖 SYN-ACK / ACK / PSH-ACK / FIN-ACK 封包结果
- Create: `Shadowsocks One/PacketTunnel/TCP/TCPFlowState.swift`
  - 单 flow 的最小序号、确认号和连接状态
- Create: `Shadowsocks One/PacketTunnel/TCP/TCPFlowEvent.swift`
  - `outboundPacket / inboundBytes / relayEOF / relayError`
- Create: `Shadowsocks One/PacketTunnel/TCP/TunnelPacketWriter.swift`
  - 对 `packetFlow.writePackets` 做可测试抽象
- Modify: `Shadowsocks One/PacketTunnel/TCP/TCPFlowRelaying.swift`
  - 支持入站字节回调和关闭回调
- Modify: `Shadowsocks One/PacketTunnel/TCP/DirectTCPRelay.swift`
  - 读远端数据并向 router 回调
- Modify: `Shadowsocks One/PacketTunnel/TCP/ShadowsocksTCPRelay.swift`
  - 读解密后的远端数据并向 router 回调
- Modify: `Shadowsocks One/PacketTunnel/TCP/TCPFlowSessionStore.swift`
  - 保存 flow state 与 relay，而不只是 relay
- Modify: `Shadowsocks One/PacketTunnel/TCP/TCPRouter.swift`
  - 统一处理 outbound / inbound / close / error 事件
- Modify: `Shadowsocks One/PacketTunnel/TunnelEngine.swift`
  - 注入 `TunnelPacketWriter`
- Test: `Shadowsocks One/Tests/ConnectionIntegrationTests/TCPFlowStateTests.swift`
- Test: `Shadowsocks One/Tests/ConnectionIntegrationTests/TCPRouterReturnPathTests.swift`
- Modify: `Shadowsocks One/Shadowsocks One.xcodeproj/project.pbxproj`

---

### Task 1: 建立最小 TCP 回包构造器

**Files:**
- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Tunnel/InternetChecksum.swift`
- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Tunnel/TCPPacketBuilder.swift`
- Test: `Shadowsocks One/Packages/SharedCore/Tests/SharedCoreTests/TCPPacketBuilderTests.swift`

- [ ] **Step 1: 先写测试，锁定最小回包类型**

```swift
// SharedCoreTests/TCPPacketBuilderTests.swift
import XCTest
@testable import SharedCore

final class TCPPacketBuilderTests: XCTestCase {
    func testBuildsSYNACKPacket() throws {
        let packet = try TCPPacketBuilder.build(
            sourceIP: "142.250.72.196",
            sourcePort: 443,
            destinationIP: "10.0.0.2",
            destinationPort: 49152,
            sequenceNumber: 10,
            acknowledgmentNumber: 101,
            flags: [.syn, .ack],
            payload: Data()
        )

        let ip = try IPPacket(data: packet)
        let tcp = try ip.tcpSegment()

        XCTAssertEqual(ip.sourceAddress, "142.250.72.196")
        XCTAssertEqual(ip.destinationAddress, "10.0.0.2")
        XCTAssertTrue(tcp.isSYN)
        XCTAssertTrue(tcp.isACK)
        XCTAssertEqual(tcp.sequenceNumber, 10)
        XCTAssertEqual(tcp.acknowledgmentNumber, 101)
    }

    func testBuildsPSHACKWithPayload() throws {
        let payload = Data("HTTP".utf8)
        let packet = try TCPPacketBuilder.build(
            sourceIP: "142.250.72.196",
            sourcePort: 443,
            destinationIP: "10.0.0.2",
            destinationPort: 49152,
            sequenceNumber: 11,
            acknowledgmentNumber: 101,
            flags: [.psh, .ack],
            payload: payload
        )

        let tcp = try IPPacket(data: packet).tcpSegment()
        XCTAssertTrue(tcp.isPSH)
        XCTAssertTrue(tcp.isACK)
        XCTAssertEqual(tcp.payload, payload)
    }
}
```

- [ ] **Step 2: 跑测试确认回包构造器尚未存在**

Run:
`xcodebuild -project "/Users/fitz/REPO/ShadowsocksX-NG/Shadowsocks One/Shadowsocks One.xcodeproj" -scheme "Shadowsocks One" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SharedCoreXcodeTests/TCPPacketBuilderTests test`

Expected: FAIL，提示 `TCPPacketBuilder` 不存在

- [ ] **Step 3: 实现最小 IPv4/TCP 封包器**

```swift
// SharedCore/Tunnel/TCPPacketBuilder.swift
import Foundation

public enum TCPPacketFlag: UInt16, Sendable {
    case fin = 0x01
    case syn = 0x02
    case rst = 0x04
    case psh = 0x08
    case ack = 0x10
}

public enum TCPPacketBuilder {
    public static func build(
        sourceIP: String,
        sourcePort: UInt16,
        destinationIP: String,
        destinationPort: UInt16,
        sequenceNumber: UInt32,
        acknowledgmentNumber: UInt32,
        flags: Set<TCPPacketFlag>,
        payload: Data
    ) throws -> Data {
        let tcpHeaderLength = 20
        let ipv4HeaderLength = 20
        let totalLength = ipv4HeaderLength + tcpHeaderLength + payload.count
        var packet = Data(count: totalLength)

        packet[0] = 0x45
        packet[1] = 0x00
        packet.writeUInt16(UInt16(totalLength), at: 2)
        packet.writeUInt16(0, at: 4)
        packet.writeUInt16(0x4000, at: 6)
        packet[8] = 64
        packet[9] = 6
        packet.writeIPv4(sourceIP, at: 12)
        packet.writeIPv4(destinationIP, at: 16)

        packet.writeUInt16(sourcePort, at: 20)
        packet.writeUInt16(destinationPort, at: 22)
        packet.writeUInt32(sequenceNumber, at: 24)
        packet.writeUInt32(acknowledgmentNumber, at: 28)
        packet[32] = 0x50
        packet[33] = UInt8(flags.reduce(0) { $0 | $1.rawValue })
        packet.writeUInt16(0xFFFF, at: 34)
        packet.replaceSubrange(40..<totalLength, with: payload)

        let ipChecksum = InternetChecksum.ipv4Header(packet.prefix(20))
        packet.writeUInt16(ipChecksum, at: 10)

        let tcpChecksum = InternetChecksum.tcpSegment(
            sourceIP: sourceIP,
            destinationIP: destinationIP,
            segment: packet.suffix(from: 20)
        )
        packet.writeUInt16(tcpChecksum, at: 36)

        return packet
    }
}
```

- [ ] **Step 4: 运行测试并确认封包结果稳定**

Run:
`xcodebuild -project "/Users/fitz/REPO/ShadowsocksX-NG/Shadowsocks One/Shadowsocks One.xcodeproj" -scheme "Shadowsocks One" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SharedCoreXcodeTests/TCPPacketBuilderTests test`

Expected: PASS

- [ ] **Step 5: 提交这一小步**

```bash
git add "Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Tunnel/InternetChecksum.swift" \
        "Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Tunnel/TCPPacketBuilder.swift" \
        "Shadowsocks One/Packages/SharedCore/Tests/SharedCoreTests/TCPPacketBuilderTests.swift" \
        "Shadowsocks One/Shadowsocks One.xcodeproj/project.pbxproj"
git commit -m "$(cat <<'EOF'
feat(ios): add minimal tcp packet builder for tunnel return path

Add the checksum and packet building primitives needed to write TCP responses back into PacketTunnel flows.
EOF
)"
```

---

### Task 2: 建立单 flow 的最小 TCP 状态机

**Files:**
- Create: `Shadowsocks One/PacketTunnel/TCP/TCPFlowState.swift`
- Create: `Shadowsocks One/PacketTunnel/TCP/TCPFlowEvent.swift`
- Test: `Shadowsocks One/Tests/ConnectionIntegrationTests/TCPFlowStateTests.swift`

- [ ] **Step 1: 先写测试，锁定最小状态流转**

```swift
// ConnectionIntegrationTests/TCPFlowStateTests.swift
import XCTest
@testable import ShadowsocksOnePacketTunnel

final class TCPFlowStateTests: XCTestCase {
    func testConsumesClientSYNAndProducesSYNACK() throws {
        var state = TCPFlowState.initial(
            clientIP: "10.0.0.2",
            clientPort: 49152,
            remoteIP: "142.250.72.196",
            remotePort: 443,
            clientSequenceNumber: 100
        )

        let response = try state.consumeOutboundSYN()

        XCTAssertEqual(response.flags, [.syn, .ack])
        XCTAssertEqual(state.phase, .synReceived)
        XCTAssertEqual(state.nextExpectedClientSequence, 101)
    }

    func testBuildsPSHACKForInboundPayload() throws {
        var state = TCPFlowState.initial(
            clientIP: "10.0.0.2",
            clientPort: 49152,
            remoteIP: "142.250.72.196",
            remotePort: 443,
            clientSequenceNumber: 100
        )
        _ = try state.consumeOutboundSYN()
        _ = try state.consumeOutboundACK()

        let response = try state.consumeInboundPayload(Data("HTTP".utf8))

        XCTAssertEqual(response.flags, [.psh, .ack])
        XCTAssertEqual(response.payload, Data("HTTP".utf8))
        XCTAssertEqual(state.phase, .established)
    }
}
```

- [ ] **Step 2: 跑测试确认状态机尚未存在**

Run:
`xcodebuild -project "/Users/fitz/REPO/ShadowsocksX-NG/Shadowsocks One/Shadowsocks One.xcodeproj" -scheme "Shadowsocks One" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ConnectionIntegrationTests/TCPFlowStateTests test`

Expected: FAIL

- [ ] **Step 3: 实现最小状态与回包描述**

```swift
// PacketTunnel/TCP/TCPFlowEvent.swift
import Foundation
import SharedCore

struct TCPFlowResponse: Equatable {
    let flags: Set<TCPPacketFlag>
    let sequenceNumber: UInt32
    let acknowledgmentNumber: UInt32
    let payload: Data
}
```

```swift
// PacketTunnel/TCP/TCPFlowState.swift
import Foundation
import SharedCore

enum TCPFlowPhase: Equatable {
    case initial
    case synReceived
    case established
    case finWaiting
    case closed
}

struct TCPFlowState {
    var phase: TCPFlowPhase
    var localSequenceNumber: UInt32
    var nextExpectedClientSequence: UInt32
    let clientIP: String
    let clientPort: UInt16
    let remoteIP: String
    let remotePort: UInt16

    static func initial(
        clientIP: String,
        clientPort: UInt16,
        remoteIP: String,
        remotePort: UInt16,
        clientSequenceNumber: UInt32
    ) -> TCPFlowState {
        TCPFlowState(
            phase: .initial,
            localSequenceNumber: 1,
            nextExpectedClientSequence: clientSequenceNumber,
            clientIP: clientIP,
            clientPort: clientPort,
            remoteIP: remoteIP,
            remotePort: remotePort
        )
    }

    mutating func consumeOutboundSYN() throws -> TCPFlowResponse {
        phase = .synReceived
        nextExpectedClientSequence += 1
        let response = TCPFlowResponse(
            flags: [.syn, .ack],
            sequenceNumber: localSequenceNumber,
            acknowledgmentNumber: nextExpectedClientSequence,
            payload: Data()
        )
        localSequenceNumber += 1
        return response
    }

    mutating func consumeOutboundACK() throws -> TCPFlowResponse {
        phase = .established
        return TCPFlowResponse(
            flags: [.ack],
            sequenceNumber: localSequenceNumber,
            acknowledgmentNumber: nextExpectedClientSequence,
            payload: Data()
        )
    }

    mutating func consumeInboundPayload(_ payload: Data) throws -> TCPFlowResponse {
        let response = TCPFlowResponse(
            flags: [.psh, .ack],
            sequenceNumber: localSequenceNumber,
            acknowledgmentNumber: nextExpectedClientSequence,
            payload: payload
        )
        localSequenceNumber += UInt32(payload.count)
        return response
    }
}
```

- [ ] **Step 4: 跑测试验证最小状态流转**

Run:
`xcodebuild -project "/Users/fitz/REPO/ShadowsocksX-NG/Shadowsocks One/Shadowsocks One.xcodeproj" -scheme "Shadowsocks One" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ConnectionIntegrationTests/TCPFlowStateTests test`

Expected: PASS

- [ ] **Step 5: 提交这一小步**

```bash
git add "Shadowsocks One/PacketTunnel/TCP/TCPFlowState.swift" \
        "Shadowsocks One/PacketTunnel/TCP/TCPFlowEvent.swift" \
        "Shadowsocks One/Tests/ConnectionIntegrationTests/TCPFlowStateTests.swift" \
        "Shadowsocks One/Shadowsocks One.xcodeproj/project.pbxproj"
git commit -m "$(cat <<'EOF'
feat(ios): add minimal tcp flow state for packet tunnel

Introduce the smallest TCP state machine needed to acknowledge client packets and write relay responses back into the tunnel.
EOF
)"
```

---

### Task 3: 把 relay 入站字节流桥接成 `packetFlow.writePackets`

**Files:**
- Create: `Shadowsocks One/PacketTunnel/TCP/TunnelPacketWriter.swift`
- Modify: `Shadowsocks One/PacketTunnel/TCP/TCPFlowRelaying.swift`
- Modify: `Shadowsocks One/PacketTunnel/TCP/DirectTCPRelay.swift`
- Modify: `Shadowsocks One/PacketTunnel/TCP/ShadowsocksTCPRelay.swift`
- Modify: `Shadowsocks One/PacketTunnel/TCP/TCPFlowSessionStore.swift`
- Modify: `Shadowsocks One/PacketTunnel/TCP/TCPRouter.swift`
- Test: `Shadowsocks One/Tests/ConnectionIntegrationTests/TCPRouterReturnPathTests.swift`

- [ ] **Step 1: 先写测试，锁定入站字节会被回写成 TCP 包**

```swift
// ConnectionIntegrationTests/TCPRouterReturnPathTests.swift
import XCTest
import SharedCore
@testable import ShadowsocksOnePacketTunnel

final class TCPRouterReturnPathTests: XCTestCase {
    func testWritesSYNACKWhenClientStartsFlow() async throws {
        let writer = PacketWriterSpy()
        let router = makeRouter(packetWriter: writer)

        try await router.route(makeSYNPacket())

        XCTAssertEqual(writer.writeCalls, 1)
        let ip = try IPPacket(data: writer.packets[0])
        let tcp = try ip.tcpSegment()
        XCTAssertTrue(tcp.isSYN)
        XCTAssertTrue(tcp.isACK)
    }

    func testWritesPSHACKWhenRelayEmitsInboundBytes() async throws {
        let writer = PacketWriterSpy()
        let relay = RelaySpy()
        let router = makeRouter(packetWriter: writer, relay: relay)

        try await router.route(makeEstablishedACKPacket())
        try await relay.emitInbound(Data("HTTP".utf8))

        XCTAssertEqual(writer.writeCalls, 1)
        XCTAssertEqual(try IPPacket(data: writer.packets[0]).tcpSegment().payload, Data("HTTP".utf8))
    }
}
```

- [ ] **Step 2: 跑测试确认回程桥接尚未实现**

Run:
`xcodebuild -project "/Users/fitz/REPO/ShadowsocksX-NG/Shadowsocks One/Shadowsocks One.xcodeproj" -scheme "Shadowsocks One" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ConnectionIntegrationTests/TCPRouterReturnPathTests test`

Expected: FAIL

- [ ] **Step 3: 扩展 relay 协议，支持入站回调**

```swift
// PacketTunnel/TCP/TCPFlowRelaying.swift
import Foundation

protocol TCPFlowRelaying: AnyObject {
    var onInboundBytes: (@Sendable (Data) async -> Void)? { get set }
    var onClosed: (@Sendable () async -> Void)? { get set }
    func start() async throws
    func forwardOutboundPayload(_ payload: Data) async throws
    func stop() async
}
```

```swift
// PacketTunnel/TCP/TunnelPacketWriter.swift
import Foundation
@preconcurrency import NetworkExtension

protocol TunnelPacketWriting: AnyObject {
    func write(_ packets: [Data], protocols: [NSNumber])
}

final class TunnelPacketWriter: TunnelPacketWriting {
    private let packetFlow: NEPacketTunnelFlow

    init(packetFlow: NEPacketTunnelFlow) {
        self.packetFlow = packetFlow
    }

    func write(_ packets: [Data], protocols: [NSNumber]) {
        packetFlow.writePackets(packets, withProtocols: protocols)
    }
}
```

- [ ] **Step 4: 在 `TCPRouter` 中把状态机输出写回系统**

```swift
// PacketTunnel/TCP/TCPRouter.swift
final class TCPRouter: TCPRouting {
    private let packetWriter: any TunnelPacketWriting

    func handleInboundBytes(_ data: Data, for key: TCPFlowKey) async throws {
        let state = try sessionStore.state(for: key)
        let response = try state.consumeInboundPayload(data)
        let packet = try TCPPacketBuilder.build(
            sourceIP: state.remoteIP,
            sourcePort: state.remotePort,
            destinationIP: state.clientIP,
            destinationPort: state.clientPort,
            sequenceNumber: response.sequenceNumber,
            acknowledgmentNumber: response.acknowledgmentNumber,
            flags: response.flags,
            payload: response.payload
        )
        packetWriter.write([packet], protocols: [NSNumber(value: AF_INET)])
        try sessionStore.updateState(state, for: key)
    }
}
```

- [ ] **Step 5: 运行测试并提交**

Run:
`xcodebuild -project "/Users/fitz/REPO/ShadowsocksX-NG/Shadowsocks One/Shadowsocks One.xcodeproj" -scheme "Shadowsocks One" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ConnectionIntegrationTests/TCPRouterReturnPathTests test`

Expected: PASS

Commit:

```bash
git add "Shadowsocks One/PacketTunnel/TCP/TunnelPacketWriter.swift" \
        "Shadowsocks One/PacketTunnel/TCP/TCPFlowRelaying.swift" \
        "Shadowsocks One/PacketTunnel/TCP/DirectTCPRelay.swift" \
        "Shadowsocks One/PacketTunnel/TCP/ShadowsocksTCPRelay.swift" \
        "Shadowsocks One/PacketTunnel/TCP/TCPFlowSessionStore.swift" \
        "Shadowsocks One/PacketTunnel/TCP/TCPRouter.swift" \
        "Shadowsocks One/Tests/ConnectionIntegrationTests/TCPRouterReturnPathTests.swift" \
        "Shadowsocks One/Shadowsocks One.xcodeproj/project.pbxproj"
git commit -m "$(cat <<'EOF'
feat(ios): bridge relay ingress back into packet tunnel

Write inbound relay bytes back to packetFlow using minimal TCP packet synthesis so the tunnel has a real return path.
EOF
)"
```

---

### Task 4: 把最小回程桥接接进 `TunnelEngine` / `PacketTunnelProvider`

**Files:**
- Modify: `Shadowsocks One/PacketTunnel/TunnelEngine.swift`
- Modify: `Shadowsocks One/PacketTunnel/PacketTunnelProvider.swift`
- Modify: `Shadowsocks One/Tests/ConnectionIntegrationTests/PacketTunnelEngineTests.swift`

- [ ] **Step 1: 写失败测试，锁定 `PacketTunnelProvider` 会装配 packet writer 并启动真实读包循环**

```swift
// ConnectionIntegrationTests/PacketTunnelEngineTests.swift
func testEngineStartsPacketLoopWhenPacketFlowExists() async throws {
    let flow = PacketFlowSpy()
    let engine = TunnelEngine(
        dnsCoordinator: DNSCoordinatorSpy(),
        tcpRouter: TCPRouterSpy(),
        packetFlow: flow
    )

    engine.start()
    await flow.deliver([makeSYNPacket()])

    XCTAssertEqual(flow.readCalls, 1)
}
```

- [ ] **Step 2: 跑测试确认集成缺口**

Run:
`xcodebuild -project "/Users/fitz/REPO/ShadowsocksX-NG/Shadowsocks One/Shadowsocks One.xcodeproj" -scheme "Shadowsocks One" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ConnectionIntegrationTests/PacketTunnelEngineTests test`

Expected: FAIL 或部分失败

- [ ] **Step 3: 接入 writer 与 stopAll 生命周期**

```swift
// PacketTunnel/PacketTunnelProvider.swift
let packetWriter = TunnelPacketWriter(packetFlow: packetFlow)
let tcpRouter = TCPRouter(
    launchConfiguration: launchConfiguration,
    matcher: routeMatcher,
    packetWriter: packetWriter
)
let engine = TunnelEngine(
    dnsCoordinator: dnsCoordinator,
    tcpRouter: tcpRouter,
    packetFlow: PacketTunnelFlowAdapter(packetFlow: packetFlow)
)
self.engine = engine
engine.start(onFatalError: { [weak self] error in
    self?.persistRuntimeError(error)
    self?.cancelTunnelWithError(error)
})
```

- [ ] **Step 4: 运行自动化验证**

Run:
- `xcodebuild -project "/Users/fitz/REPO/ShadowsocksX-NG/Shadowsocks One/Shadowsocks One.xcodeproj" -scheme "Shadowsocks One" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ConnectionIntegrationTests/PacketTunnelEngineTests -only-testing:ConnectionIntegrationTests/TCPRouterReturnPathTests test`
- `xcodebuild -project "/Users/fitz/REPO/ShadowsocksX-NG/Shadowsocks One/Shadowsocks One.xcodeproj" -scheme "Shadowsocks One" -destination 'generic/platform=iOS' build`

Expected:
- 测试通过
- 真机构建通过

- [ ] **Step 5: 提交 integration checkpoint**

```bash
git add "Shadowsocks One/PacketTunnel/TunnelEngine.swift" \
        "Shadowsocks One/PacketTunnel/PacketTunnelProvider.swift" \
        "Shadowsocks One/Tests/ConnectionIntegrationTests/PacketTunnelEngineTests.swift" \
        "Shadowsocks One/Shadowsocks One.xcodeproj/project.pbxproj"
git commit -m "$(cat <<'EOF'
feat(ios): add minimal tcp return path to packet tunnel

Integrate packet writing and the smallest TCP response path so PacketTunnel can echo relay responses back into the system stack.
EOF
)"
```

---

## Self-Review

- 当前最关键的阻塞点 `packetFlow.writePackets + 最小 TCP 状态机` 已被单独拆出
- 这份计划没有把 DNS、白名单增强、完整网页兼容再混进来
- 每个任务都围绕“最小回程闭环”收敛，没有再往大而全发散

## Notes

- 这份计划的完成标准不是“Safari 一定通”，而是“系统 tunnel 已具备最小 TCP 回程能力”。只有把这一步做出来，后面才值得继续调网页兼容性。
- 如果在 Task 3/4 发现最小状态机仍不足以支撑真实系统 TCP 行为，下一份计划就应继续细化 `SEQ/ACK`、重传和关闭握手，而不是重新扩回 DNS/规则系统。
