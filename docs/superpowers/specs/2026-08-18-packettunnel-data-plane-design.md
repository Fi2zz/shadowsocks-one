# PacketTunnel Data Plane MVP Design

**目标**

在 `Shadowsocks One` 现有“系统 VPN 控制面已打通”的基础上，补齐最小可用的数据面，使 iPhone 在开启 VPN 后：

- `Safari` 可以打开常见网页
- 境外目标可通过 Shadowsocks 隧道访问
- 中国大陆站点默认直连
- 用户手工指定的白名单站点直连

本设计只覆盖 **PacketTunnel 数据面 MVP**，不扩展到完整通用代理内核。

---

## 1. 范围

### 1.1 本期包含

- `NEPacketTunnelProvider` 内的数据面实现
- `IPv4 + TCP` 网页访问链路
- `DNS` 最小闭环支持
- 中国大陆 `CIDR` 白名单直连
- 自定义域名白名单直连
- Shadowsocks AEAD TCP 出站复用现有 `SharedCore` 加密能力
- 基本日志、错误诊断与冒烟测试

### 1.2 本期不包含

- `UDP` 通用代理
- `IPv6`
- 插件协议
- PAC
- 订阅规则下载
- 完整规则语言
- 高级 DNS 分流策略
- 长连接性能优化、多路复用、连接池高级调度

---

## 2. 成功标准

满足以下条件即可视为 MVP 完成：

1. 真机开启 VPN 后，`Safari` 可访问 `https://www.google.com`
2. 真机开启 VPN 后，`Safari` 可访问至少 2 个中国大陆常见站点，且不经过 Shadowsocks 出站
3. 关闭 VPN 后，系统网络恢复正常
4. 节点不可用时，App 能明确提示启动失败或数据面失败
5. 白名单域名和中国大陆 `CIDR` 命中结果具备可观察日志

---

## 3. 设计原则

### 3.1 先跑通网页，再补齐协议

第一版只追求常见网页访问成立，不追求所有 App 或所有协议都完美兼容。

### 3.2 分流判断尽量基于 IP，域名只做辅助

`PacketTunnel` 最终看到的核心仍是 IP 包。中国大陆站点优先用 `CIDR` 直连；自定义站点通过“域名解析结果缓存”辅助命中。

### 3.3 复用现有能力，不重写密码学

现有 `SharedCore` 中已经有 AEAD 请求编码、响应解码、探测握手能力。数据面应尽量复用同一套 Shadowsocks 编解码与连接配置。

### 3.4 模块清晰，小步闭环

路由判断、DNS 解析、TCP 中继、包读写分开实现，避免把所有逻辑继续堆进 `PacketTunnelProvider.swift`。

---

## 4. 总体架构

### 4.1 进程结构

现有工程维持三层：

1. `App target`
   - 导入节点
   - 持久化当前节点
   - 启动/停止系统 VPN

2. `Packet Tunnel Extension`
   - 读取当前启动配置
   - 从 `packetFlow` 接管系统流量
   - 按路由规则决定直连或走 Shadowsocks

3. `SharedCore`
   - 节点配置
   - Shadowsocks AEAD 编解码
   - 通用模型与共享存储

### 4.2 数据面分层

数据面拆成 5 个职责层：

1. `PacketTunnelProvider`
   - 生命周期入口
   - 装配各组件
   - 应用 `NEPacketTunnelNetworkSettings`

2. `TunnelEngine`
   - 持续读取 `packetFlow`
   - 将数据包分发给 DNS 或 TCP 路由器

3. `RouteMatcher`
   - 判断目标是否应直连
   - 规则来源包括中国大陆 `CIDR` 与用户域名白名单

4. `DNSCoordinator`
   - 负责最小 DNS 闭环
   - 为域名白名单提供解析结果缓存

5. `TCPRelay`
   - `DirectTCPRelay`: 白名单流量直连目标站点
   - `ShadowsocksTCPRelay`: 其余流量通过 Shadowsocks 服务器转发

---

## 5. 路由策略

### 5.1 默认策略

- 默认走代理
- 命中白名单则直连

这是为了保证第一版在国际站点访问上更稳定，不因规则缺失导致“该代理的不代理”。

### 5.2 中国大陆直连规则

中国大陆直连规则由一份内置 `CIDR` 列表提供，格式建议为静态 JSON 资源：

```json
{
  "version": "2026-08-18",
  "ipv4": [
    "1.0.1.0/24",
    "1.0.2.0/23"
  ]
}
```

第一版规则来源固定为项目内置资源，不做在线更新。

### 5.3 自定义域名白名单

用户可维护一组白名单域名，例如：

- `taobao.com`
- `bilibili.com`
- `*.qq.com`

第一版支持：

- 精确域名
- 单层通配符前缀 `*.example.com`

不支持更复杂表达式。

### 5.4 域名白名单的命中方式

由于 `PacketTunnel` 数据面主要看到的是目标 IP，域名白名单不能只靠字符串匹配完成。第一版采用两段式策略：

1. `DNSCoordinator` 解析白名单域名，维护一个 `domain -> [ip]` 的短期缓存
2. `RouteMatcher` 在判断目标 IP 时，同时检查：
   - 是否命中中国大陆 `CIDR`
   - 是否命中白名单域名解析结果缓存

缓存需要 TTL，避免白名单域名解析结果长期过期。

---

## 6. DNS 设计

### 6.1 第一版目标

DNS 只做最小闭环，不做完整通用 DNS 代理引擎。目标只有两个：

1. 网页访问所需域名能被解析
2. 白名单域名能把解析结果喂给路由层

### 6.2 处理方式

第一版支持两类 DNS：

1. 白名单域名预解析
   - 在 Tunnel 启动后异步解析一轮白名单域名
   - 周期性刷新缓存

2. Tunnel 内收到的 DNS 请求
   - 仅特判 `UDP/53`
   - 将查询转发给上游 DNS 服务器
   - 把结果写回 `packetFlow`

说明：虽然本期不做“通用 UDP 代理”，但 **DNS 例外**，因为没有 DNS，网页访问几乎一定失败。

### 6.3 上游 DNS 选择

第一版建议固定为两组可配置上游：

- 直连 DNS：用于白名单/国内站点解析
- 代理 DNS：用于其他站点解析

但 MVP 为了缩小范围，可先统一走一组稳定 DNS，上层只保证解析可用，不在第一版做复杂 DNS 分流。

---

## 7. TCP 数据面设计

### 7.1 最小闭环

Tunnel 读取到 `IPv4/TCP` 包后，按五元组建立连接会话：

- 源 IP
- 源端口
- 目标 IP
- 目标端口
- 协议

每个会话绑定一个 relay：

- 直连目标站点
- 或连接 Shadowsocks 服务器

### 7.2 会话模型

建议引入 `TCPFlowSession`：

```swift
struct TCPFlowKey: Hashable, Sendable {
    let sourceAddress: IPv4Address
    let sourcePort: UInt16
    let destinationAddress: IPv4Address
    let destinationPort: UInt16
}
```

```swift
protocol TCPFlowRelaying: Sendable {
    func start() async throws
    func forwardOutboundPacket(_ packet: Data) async throws
    func stop() async
}
```

说明：
- `TunnelEngine` 负责从 IP 包中切出 TCP payload
- `TCPFlowSessionStore` 负责管理活跃流
- 每条活跃流只绑定一个 relay 实例

### 7.3 直连 Relay

`DirectTCPRelay` 负责：

- 使用 `NWConnection` 直连目标站点
- 把来自 `packetFlow` 的上行数据转发到目标
- 把目标返回数据重新封装后写回 `packetFlow`

### 7.4 Shadowsocks Relay

`ShadowsocksTCPRelay` 负责：

- 建立到 Shadowsocks 服务器的 TCP 连接
- 使用现有 `SharedCore` 编码器封装目标地址与首包
- 对返回流量做 AEAD 解密
- 再封装回本地 TCP/IP 包写入 `packetFlow`

### 7.5 当前设计中的现实约束

`NEPacketTunnelProvider` 给的是 IP 包，不是现成的高层 TCP 流。也就是说，第一版数据面实际上需要一个最小用户态 TCP 适配层，至少覆盖：

- SYN / ACK / FIN 的基础状态流转
- 顺序发送与接收
- 连接关闭
- 基础超时清理

这部分是整个 MVP 最难的部分，也是实现计划里需要拆分成多个子任务的核心。

---

## 8. 组件拆分建议

建议新增或调整以下文件：

- `Shadowsocks One/PacketTunnel/PacketTunnelProvider.swift`
  - 保留生命周期和装配，不再承载全部逻辑

- `Shadowsocks One/PacketTunnel/TunnelEngine.swift`
  - 驱动 `packetFlow.readPackets`
  - 分发到 DNS 或 TCP

- `Shadowsocks One/PacketTunnel/Routing/RouteMatcher.swift`
  - 中国大陆 `CIDR` 匹配
  - 自定义域名缓存命中

- `Shadowsocks One/PacketTunnel/Routing/DomainWhitelistStore.swift`
  - 读取用户自定义白名单

- `Shadowsocks One/PacketTunnel/Routing/CNIPRangeStore.swift`
  - 加载静态中国大陆 IP 资源

- `Shadowsocks One/PacketTunnel/DNS/DNSCoordinator.swift`
  - DNS 请求处理
  - 域名预解析与 TTL 缓存

- `Shadowsocks One/PacketTunnel/TCP/TCPFlowSessionStore.swift`
  - 管理活跃 TCP 会话

- `Shadowsocks One/PacketTunnel/TCP/DirectTCPRelay.swift`
  - 直连目标站点

- `Shadowsocks One/PacketTunnel/TCP/ShadowsocksTCPRelay.swift`
  - 代理出口

- `Shadowsocks One/Packages/SharedCore/Sources/SharedCore/Routing/`
  - 放通用规则模型和共享白名单配置

---

## 9. 配置与共享存储

### 9.1 共享配置新增项

除当前 `TunnelLaunchConfiguration` 外，第一版还需要共享以下配置：

- 用户自定义域名白名单
- DNS 上游配置（可选，第一版可内置默认值）
- 是否启用中国大陆 IP 直连

### 9.2 存储建议

- Tunnel 启动配置继续使用现有 `TunnelConfigurationStore`
- 路由与白名单配置新增独立 store，避免和当前节点配置耦合

建议新增：

```swift
struct RoutingConfiguration: Codable, Sendable, Equatable {
    let bypassCNIP: Bool
    let domainWhitelist: [String]
}
```

---

## 10. 错误处理与可观察性

### 10.1 App 可见错误

App 侧至少需要能区分：

- Tunnel 启动失败
- 配置缺失
- DNS 初始化失败
- 数据面 relay 建立失败

### 10.2 Extension 日志

`PacketTunnel` 需要对以下事件打日志：

- Tunnel 启动完成
- DNS 查询转发
- 路由命中结果（direct / proxy）
- TCP relay 建立 / 关闭
- 关键失败原因

日志粒度以“能排查问题”为准，不做大规模追踪系统。

---

## 11. 测试策略

### 11.1 单元测试

应覆盖：

- 中国大陆 `CIDR` 匹配
- 域名白名单匹配
- 域名缓存 TTL 失效
- `TunnelConfigurationStore` 与新路由配置 store

### 11.2 集成测试

应覆盖：

- 给定目标 IP，命中直连路径
- 给定目标 IP，命中代理路径
- DNS 结果写入缓存后，后续流量切到直连

### 11.3 真机冒烟测试

最少验证：

1. 开启 VPN 后访问 `google.com`
2. 开启 VPN 后访问 `bilibili.com`
3. 关闭 VPN 后恢复原始网络
4. 节点失效时，App 能提示失败

---

## 12. 风险与取舍

### 12.1 最大风险

最大风险不是 Shadowsocks 协议本身，而是 **PacketTunnel 的最小 TCP/IP 适配层**。如果这里实现过重，整个 MVP 会迅速失控。

### 12.2 取舍

因此第一版必须坚持：

- 只做 `IPv4`
- 只做 `TCP`
- `UDP` 仅特判 DNS
- 白名单不做复杂表达式
- 不追求全 App 生态兼容，只先验证网页访问

---

## 13. 里程碑建议

### 13.1 M1：可启动 DNS 闭环

- Tunnel 启动
- DNS 请求可被处理
- 白名单域名缓存可写入

### 13.2 M2：TCP 直连闭环

- 白名单目标可直连访问
- Safari 不再因为全局断网而直接失败

### 13.3 M3：Shadowsocks TCP 代理闭环

- 非白名单目标通过 Shadowsocks 出站
- `google.com` 可访问

### 13.4 M4：真机稳定性收尾

- 日志补齐
- 错误提示补齐
- 断开、失败恢复、基础回归测试

---

## 14. 结论

本设计选择一条非常明确的 MVP 路线：

- 用 `PacketTunnel` 真正接管系统流量
- 先只支持 `IPv4 TCP + DNS`
- 中国大陆 `CIDR` 与用户白名单域名走直连
- 其余目标走 Shadowsocks AEAD TCP

它不是完整代理内核，但足够验证产品路线是否成立：**系统 VPN 可用、网页可访问、基础分流有效**。
