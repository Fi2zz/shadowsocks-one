# PacketTunnel DNS Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 `Shadowsocks One` 的 `PacketTunnel` 补齐最小 DNS 真闭环：接收系统发往 `UDP/53` 的 DNS 查询，转发到上游 DNS，收到响应后写回 `packetFlow`，并把 `A` 记录写入 `DNSCache`。

**Architecture:** 这轮只解决 DNS 请求/响应链路，不扩展到完整规则系统。`SharedCore` 负责最小 UDP 封包与必要的 DNS payload 解析，`PacketTunnel` 负责上游 DNS 查询、缓存写入和回包写回系统栈。

**Tech Stack:** Swift, Foundation, Network, NetworkExtension, SharedCore, XCTest

---

## Scope

这份计划只解决下面 3 件事：

1. 构造可写回 `packetFlow` 的最小 IPv4/UDP DNS 响应包
2. 把 `UDP/53` 查询转发到上游 DNS 并拿回响应
3. 从 DNS 响应里提取 `A` 记录写入 `DNSCache`

明确不包含：

- DoH / DoT
- AAAA / MX / TXT 等更丰富记录类型
- DNS over proxy / 复杂 DNS 分流
- 域名白名单与 TCP 流的完整联动验证
- “Safari 一定已经能通”的承诺

---

## File Structure

- Create: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Tunnel/UDPPacketBuilder.swift`
- Create: `Shadowsocks One/Packages/SharedCore/Tests/SharedCoreTests/UDPPacketBuilderTests.swift`
- Modify: `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Tunnel/InternetChecksum.swift`
- Modify: `Shadowsocks One/PacketTunnel/DNS/DNSCoordinator.swift`
- Modify: `Shadowsocks One/PacketTunnel/PacketTunnelProvider.swift`
- Modify: `Shadowsocks One/Tests/ConnectionIntegrationTests/PacketTunnelEngineTests.swift`
- Modify: `Shadowsocks One/Shadowsocks One.xcodeproj/project.pbxproj`

---

## Tasks

### Task 1: 添加最小 UDP 回包构造器
- 新增 `UDPPacketBuilder`
- 复用 `InternetChecksum` 计算 UDP pseudo-header checksum
- 补 `UDPPacketBuilderTests`

### Task 2: 在 `DNSCoordinator` 中实现上游查询和缓存写入
- 增加 DNS 上游查询协议
- 最小支持原始 UDP payload 查询
- 解析 DNS 响应中的 question 与 `A` answers
- 写入 `DNSCache`

### Task 3: 把 DNS 响应写回 `packetFlow`
- 给 `DNSCoordinator` 注入 `TunnelPacketWriting`
- 把上游响应封成 IPv4/UDP 包
- 在 `PacketTunnelProvider` 里接入真实 writer
- 补 `PacketTunnelEngineTests` 验证 DNS 响应确实写回 `PacketFlowSpy`

---

## Notes

- 这轮完成标准是“DNS 链路真实闭环”，不是“浏览器一定可用”。
- 如果 DNS 闭环做完后网页仍不通，剩余问题就会更明确地落在 TCP 兼容面，而不是 DNS。
