# Shadowsocks One

一个纯 Swift 实现的 iOS Shadowsocks 客户端。通过 `NEPacketTunnelProvider` 接管系统全局流量，在 Packet Tunnel 扩展内用**用户态 TCP 协议栈**终结连接，再按分流规则决定走 Shadowsocks 代理还是本地直连。App 主界面是内置的 Safari 风格多标签浏览器，节点管理与 VPN 开关收进「更多」菜单。

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
│  App（UI + 配置管理）     │  SwiftUI，内置多标签浏览器为主界面，节点/VPN 控制在「更多」菜单
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

> 定位说明：这是**简化版**的用户态 TCP 终结——ISN 固定、无选项协商（wscale/SACK）。客户端 → 服务端方向靠客户端 TCP 自身重传兜底（router 对重传包只重 ACK，语义正确）；服务端 → 客户端方向已实现出站重传（Jacobson/Karn RTO）、接收窗口通告与慢启动/拥塞避免（见 `PacketTunnel/TCP/TCPRetransmitter.swift`、`TCPCongestionController.swift`）。

### 4. DNS 闭环

不是本地伪造 A 记录，而是"拦截 + 按分流规则选上游 + 原样回写 + 缓存"：

1. 所有 DNS 查询进 TUN（见隧道设置），`DNSCoordinator` 解析查询报文取出域名
2. AAAA（IPv6）查询直接合成 NOERROR 空应答——隧道只配 IPv4 路由，拿到 IPv6 的 App 会绕过隧道直连，必须强制回落 A 记录
3. 按 `RouteMatcher.dnsDecision` 分流选上游（只看域名规则，不涉及 IP 判断）：
   - 命中直连名单 → `LocalDNSUpstreamClient` 走本地 UDP 解析（默认 `223.5.5.5:53`），直连流量拿到本地最优 CDN IP
   - 其余 → `ProxyDNSUpstreamClient` 建立到 `8.8.8.8:53` 的 **Shadowsocks TCP** 连接，按 DNS-over-TCP 格式（2 字节长度前缀）转发——域名在代理出口侧解析，避免本地 DNS 污染
4. 响应用 `UDPPacketBuilder` 包装成"来自 DNS 服务器"的 UDP 包写回 TUN，客户端视角就是一次普通 DNS 应答
5. 响应中的 A 记录按域名写入 `DNSCache`（带 TTL），供后续分流反查
6. 白名单域名在隧道启动时用系统 `getaddrinfo` 预解析（本地直连 IP）预热缓存

### 5. 分流

`RouteMatcher`（SharedCore/Routing/）输出两种决策，规则按优先级生效：

| 规则 | 决策 |
|---|---|
| 域名命中代理名单（精确或 `*.suffix` 通配） | 代理 |
| 目的 IP 在本地/内网网段（10/8、192.168/16、127/8 等，内置常量） | 直连 |
| 域名命中白名单 | 直连 |
| 「国内 IP 直连」开启且目的 IP 在 CN 段内 | 直连 |
| 未命中 | 代理（DNS 走远程解析防污染） |

> 现状：域名白名单/代理名单均已生效——TCP 建连前按目的 IP 在 `DNSCache` 反查域名（DNS 应答缓存 + 隧道启动时白名单预热）。名单与开关在 App 内「导入与分流」页维护，下次连接生效；每行右侧「测试」按钮按当前配置模拟分流（本地解析 → `RouteMatcher` 决策 → 判定直连时实测 TCP 443 连通耗时），用于验证域名是否直连。CN IP 库内置 17mon/china_ip_list（约 7.4k 条 IPv4 CIDR），App 内「国内 IP 库」区块可从下载地址更新（默认官方 GitHub 地址，可改），下载版优先于内置版；由「国内 IP 直连」开关控制。

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

### 8. 内置浏览器（App 主界面）

App 主界面是 Safari 风格的多标签浏览器（`App/Browser*.swift`），「节点」「导入与分流」等页面收进底部工具栏的「更多」（`...`）菜单（`BrowserMoreMenu`），以 sheet 打开。

- **多标签**：标签是纯数据（SharedCore `BrowserTab`），WebView 实例归 `BrowserTabManager` 的 LRU 缓存所有（内存最多保活 4 个，淘汰前落盘 `interactionState` 与缩略图）；SwiftUI 的 `BrowserWebViewContainer` 只做挂载、绝不创建，切换/弹出全屏不销毁页面
- **会话恢复**：标签数组存 `Application Support/ShadowsocksOne/Tabs/tabs.json`，每标签的页面 + 前进后退栈经 `WKWebView.interactionState` 落盘（`states/{id}.bin`），重启 App 完整恢复；缩略图（`snapshots/{id}.jpg`）供切换器显示
- **后台打开**：`target="_blank"` / `window.open` 链接在后台新建标签不打断当前浏览，Toast 提示带「查看」，标签数按钮弹跳反馈
- **Safari 式切换器**：全屏层叠卡片（3D 透视、上部重叠、滚动浏览），左滑关闭、点按选中；后台未加载标签显示 globe 占位图
- **底部工具栏**：地址栏（自动补 `https://`、聚焦全选、清空、取消）+ 前进/后退 + 新建标签 + 标签数按钮；下滚折叠为胶囊；iOS 26 用 `glassEffect` Liquid Glass 样式（`App/LiquidGlass.swift` 做能力回退）
- **健壮性**：外部 scheme（tel:/mailto:/App Store）交给系统打开；WebContent 进程被杀自动 reload 不白屏；侧滑前进后退手势开启
- **书签与隐私**：书签添加/列表/左滑删除（SharedCore `BrowserBookmarkStore`）；「清除浏览数据」同时清 WKWebView 网站数据与历史记录；历史记录存本地 JSON（封顶 200 条、同 URL 去重置顶）
- **排障设施**：顶部加载进度条（KVO `estimatedProgress`）+ 导航失败错误横幅（含 error domain/code），配合「导入与分流」页的隧道诊断日志定位加载问题

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

> 注意：App Group 与 Bundle ID 已替换为正式值（`group.com.fitz.app`、`com.fits.socks.one*`）；keychain service（`com.fits.socks.one.shared`）仍是占位值，需要时连同两个 target 的 `keychain-access-groups` 一起替换。

## 已知限制

- 用户态 TCP 仍为简化实现：ISN 固定、无选项协商（wscale/SACK）；重传/窗口/拥塞控制仅覆盖服务端 → 客户端方向
- 域名分流依赖 DNS 缓存反查：未经过 DNS 解析的纯 IP 流量不会命中域名名单（内网/CN 网段按 IP 直接判断，不受影响）
- UDP 支持转发（四元组 NAT 会话、过 `RouteMatcher` 分流），端口 53 的 DNS 拦截优先于 UDP 转发
- 浏览器历史记录仅存本地；内存中最多保活 4 个 WebView，更早的标签切回时按 interactionState 恢复
- 不支持 SS 插件（obfs 等），含插件的节点会被拒绝
- `SharedCore/Connection/ConnectionManager` 是早期"App 内直连探测"方案的遗留设施，主链路已切换到系统 VPN，仅测试引用
