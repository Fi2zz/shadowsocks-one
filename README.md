# Shadowsocks One

一个纯 Swift 实现的 iOS Shadowsocks 客户端。通过 `NEPacketTunnelProvider` 接管系统全局流量，在 Packet Tunnel 扩展内用**用户态 TCP 协议栈**终结连接，再按分流规则决定走 Shadowsocks 代理还是本地直连。

- 平台：iOS 17+
- 依赖：仅系统框架（NetworkExtension、Network、CryptoKit、SwiftUI），无第三方库
- 协议：Shadowsocks AEAD（`aes-128-gcm` / `aes-256-gcm` / `chacha20-ietf-poly1305`），支持 `ss://` 导入

## 目录结构

```
App/                  主 App（SwiftUI）
PacketTunnel/         Packet Tunnel 扩展（数据面）
Packages/SharedCore/  可测试的核心逻辑（SwiftPM 本地包）
Tests/                集成测试（含本地 AEAD echo server）
docs/                 设计与实施文档
project.yml           XcodeGen 工程描述
```

## 整体架构

三个进程/模块，职责清晰分离：

```
┌─────────────────────────┐
│  App（UI + 配置管理）     │  SwiftUI，导入节点、开关 VPN、展示状态
└───────────┬─────────────┘
            │ App Group 文件 + 共享 Keychain（配置单向写入）
┌───────────▼─────────────┐
│  Packet Tunnel 扩展       │  系统托管的独立进程，App 被杀也不影响 VPN
│  TunnelEngine            │  读 TUN → 按协议分发 → 回写 TUN
│  ├─ DNSCoordinator       │  UDP/53：DNS 拦截与应答
│  └─ TCPRouter            │  TCP：用户态协议栈 + relay
└───────────┬─────────────┘
            │ 依赖
┌───────────▼─────────────┐
│  SharedCore（纯逻辑）      │  加密、协议编解码、路由、存储，全部可单测
└─────────────────────────┘
```

## 工作原理

### 1. 隧道建立

`SystemTunnelManager`（App/SystemTunnelManager.swift）管理 `NETunnelProviderManager` 生命周期：加载或创建配置 → 设置 `NETunnelProviderProtocol`（`disconnectOnSleep = false`）→ `saveToPreferences` → `startTunnel()`。连接状态通过 `NEVPNStatusDidChange` 通知映射为 `ConnectionState`，经 `AsyncStream` 推给 UI；App 回前台时还会主动 re-sync 一次状态。

隧道网络设置（`PacketTunnelProvider.startTunnel`）：

- 虚拟网卡 `10.0.0.2/24`，默认路由全量进 TUN
- DNS 指向 `223.5.5.5 / 119.29.29.29` 且 `matchDomains = [""]`——所有 DNS 查询也被路由进 TUN，由扩展接管

隧道由系统 `nesessionmanager` 托管，**App 退后台、被挂起、被终止都不影响 VPN 连接**；扩展另实现了 `sleep/wake`，在系统睡眠唤醒周期内干净地停启引擎。

### 2. 数据面分发

`TunnelEngine`（PacketTunnel/TunnelEngine.swift）起一个 async 读循环，从 `NEPacketTunnelFlow` 读 IP 包，手工解析 IPv4 头后按协议分发：

- **UDP 且端口 53** → `DNSCoordinator`
- **TCP** → `TCPRouter`
- 其他协议 → 丢弃

回包统一经 `TunnelPacketWriter` 写回 TUN。单包错误只丢包记日志，读循环级错误才上报 `cancelTunnelWithError`。

### 3. 用户态 TCP 协议栈（最小实现）

iOS 的 Packet Tunnel 只给裸 IP 包，没有 socket。`TCPRouter` + `TCPFlowState`（PacketTunnel/TCP/）在扩展内**本地终结**每一条 TCP 连接——对 App 来说它在和"远端服务器"正常握手，实际上对端就是扩展自己：

1. 收到 SYN → 按四元组（`TCPFlowKey`）建新会话，`RouteMatcher` 决策直连/代理，创建对应 relay，立刻伪造 SYN-ACK 回给客户端
2. 握手 ACK → 进入 established
3. 出站 payload：严格按序接收（重传/乱序只重 ACK 不重复投递），命中后推进 ack 号、回纯 ACK，字节流交给 relay
4. 入站方向：relay 收到字节按 1460 切片，`TCPPacketBuilder` 拼成"来自远端"的 PSH+ACK 包写回 TUN
5. FIN/RST → 关闭会话；relay 断开时补发 FIN+ACK

relay 两种实现：

- `DirectTCPRelay`：`NWConnection` 直连目标 host:port
- `ShadowsocksTCPRelay`：经 `ShadowsocksTCPTransport` 走 SS 服务器中转，发送用串行 Task 链保证写序

> 定位说明：这是**最小可用**的用户态 TCP 终结——无重传、无窗口/拥塞控制、ISN 固定。丢包依赖客户端 TCP 自身的重传兜底（router 对重传包只重 ACK，语义正确）。它不是完整协议栈。

### 4. DNS 闭环

不是本地伪造 A 记录，而是"拦截 + 全量转发 + 原样回写 + 缓存"：

1. 所有 DNS 查询进 TUN（见隧道设置），`DNSCoordinator` 取出原始 DNS 报文
2. `ProxyDNSUpstreamClient` 建立到 `8.8.8.8:53` 的 **Shadowsocks TCP** 连接，按 DNS-over-TCP 格式（2 字节长度前缀）转发——域名在代理出口侧解析，避免本地 DNS 污染
3. 响应用 `UDPPacketBuilder` 包装成"来自 DNS 服务器"的 UDP 包写回 TUN，客户端视角就是一次普通 DNS 应答
4. 响应中的 A 记录按域名写入 `DNSCache`（带 TTL），供后续分流反查
5. 白名单域名在隧道启动时用系统 `getaddrinfo` 预解析（本地直连 IP）预热缓存

### 5. 分流

`RouteMatcher`（SharedCore/Routing/）输出两种决策，规则按优先级生效：

| 规则 | 决策 |
|---|---|
| 域名命中代理名单（精确或 `*.suffix` 通配） | 代理 |
| 域名命中白名单 | 直连 |
| `bypassCNIP` 开启且目的 IP 在 CN 段内 | 直连 |
| 未命中 | 由「未命中名单时直连」开关决定（默认关闭 = 全局代理） |

> 现状：域名白名单/代理名单均已生效——TCP 建连前按目的 IP 在 `DNSCache` 反查域名（DNS 应答缓存 + 隧道启动时白名单预热）。名单在 App 内「分流」页维护，下次连接生效。CN IP 段列表默认为空，`bypassCNIP` 暂无实际效果。

### 6. Shadowsocks 加密层

SharedCore/Connection/ + SharedCore/Tunnel/ShadowsocksTCPTransport.swift：

- **密钥**：master key 由密码经 `EVPBytesToKey`（OpenSSL 兼容 MD5 迭代）派生；每连接随机 salt，subkey = HKDF-SHA1(masterKey, salt, "ss-subkey")
- **流格式**：首帧 = `salt + 加密块(SOCKS5 风格地址头)`，之后按 SS AEAD 流协议输出 `[加密长度块][加密 payload 块]`，nonce 为递增计数器
- **传输**：`ShadowsocksTCPTransport` 基于 `NWConnection`，被 TCP relay 和 DNS 上游复用

加解密全部基于 CryptoKit，无 OpenSSL 依赖。

### 7. App ⇄ 扩展配置共享

无 IPC、无 `sendProviderMessage`，纯共享存储（常量集中在 `SharedContainerSettings`）：

| 数据 | 通道 |
|---|---|
| 节点列表 / 隧道配置（不含密码） | App Group 容器 JSON 文件 |
| 节点密码 | 共享 Keychain（account = profile UUID） |
| 选中节点 ID、扩展失败详情 | App Group `UserDefaults` |

扩展启动失败时把原因写入 `TunnelRuntimeStatusStore`，App 侧一次性取回展示——补偿 NE 错误回调拿不到扩展内部细节的问题。

## 工程与测试

- `project.yml` 由 XcodeGen 生成工程，4 个 target：App、Packet Tunnel 扩展、`ConnectionIntegrationTests`、`SharedCoreXcodeTests`
- 核心逻辑全部下沉到 `SharedCore` 包，数据面通过 `TunnelPacketFlow` 协议注入假 flow 实现脱离系统环境测试
- 集成测试含一个 `NWListener` 实现的**本地 Shadowsocks AEAD echo server**，端到端验证加解密链路；TCP 状态机、回包构造、DNS 全链路、ViewModel 交互均有覆盖

构建：

```bash
xcodegen   # 如改过 project.yml
xcodebuild -project ShadowsocksOne.xcodeproj -scheme "Shadowsocks One" \
  -destination 'generic/platform=iOS' build
```

> 注意：App Group 与 Bundle ID 已替换为正式值（`group.com.fitz.app`、`com.fits.socks.one*`）；keychain service（`com.example.ShadowsocksOne.shared`）仍是占位值，需要时连同两个 target 的 `keychain-access-groups` 一起替换。

## 已知限制

- 用户态 TCP 为最小实现：无重传/窗口/选项协商
- CN IP 段为空，`bypassCNIP` 规则暂无实际效果（域名白名单已生效）
- 仅支持 TCP 中继；UDP（除 DNS 拦截外）不转发
- 不支持 SS 插件（obfs 等），含插件的节点会被拒绝
- `SharedCore/Connection/ConnectionManager` 是早期"App 内直连探测"方案的遗留设施，主链路已切换到系统 VPN，仅测试引用
