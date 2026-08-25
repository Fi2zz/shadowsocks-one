# Handoff — 弱网 TCP 增强（任务 B）

> 写给下一个接手会话。日期：2026-08-21。
> 任务 A（UDP 转发）与任务 B（弱网 TCP 体感优化）均已完成并测试全绿；任务 B 见下文「任务 B」节。

## 仓库与流程（必读）

- 路径 `/Users/fitz/REPO/ShadowsocksX-NG`（目录名未改，可择期 rename 为 shadowsocks-one）；远端 `git@github.com:Fi2zz/shadowsocks-one.git`，唯一分支 `master`。
- 工程由 XcodeGen 生成：**新增/删除源文件后必须跑 `xcodegen`**（`make` 各目标已内置）。
- Makefile：`make test`（模拟器）、`make run`（构建+安装+启动到真机 iPhone 16，device id `14EDD430-3B6F-5969-B920-F1C427404CA4`）。
- **测试不要加 `CODE_SIGNING_ALLOWED=NO`**：会导致测试宿主 Keychain 失败、RootViewModel 用例挂。只有纯 `make build` 用了它。
- 提交规范（用户全局 AGENTS.md）：中文交流；函数 ≤20 行、文件 ≤200 行、单函数分支 ≤3；布尔命名禁 is/has 前缀；完成改动后用 `git-commit` skill 按逻辑分类提交并直接 push（已授权）。
- 项目决定**不上架 App Store**，无需考虑审核相关约束。

## 后续更新（2026-08-21）：内置浏览器成为主界面

- `RootView` 不再是 TabView：Safari 风格多标签浏览器（`App/Browser*.swift` + `WebViewStore` / `WebViewRepresentable`）直接作为根视图；`ProfilesTabView` / `ImportTabView` 零改动收进底部工具栏 `...` 菜单（`BrowserMoreMenu`，各自 sheet 打开）。
- 多标签 = 每标签常驻一个 WKWebView + `ZStack` 切可见性（不重载）；`BrowserTabManager` 管标签数组/选中态/历史。URL 规范化（`BrowserURLBuilder`）与历史 store（`BrowserHistoryStore`，本地 JSON、200 条封顶）在 SharedCore，11 个单测全绿。
- 底栏 iOS 26 Liquid Glass（`App/LiquidGlass.swift` 做 `glassEffect` 能力回退）；地址栏聚焦态仿 Safari（隐藏导航钮、全选、`✕` 取消还原输入）；顶部有加载进度条 + 导航失败错误横幅（error domain + code）。
- 曾出现「连接节点后 WebView 白屏、URLSession 正常」：未改隧道代码，重装/重启隧道后恢复，判断为隧道陈旧状态而非代码回归；复发时先记录横幅错误码 + 隧道诊断日志再排查。
- 待办：非活跃标签的 WKWebView 全部常驻内存，标签很多时可加回收策略；地址栏输入不支持搜索词（无搜索引擎跳转）。

## 当前架构状态（已完成，勿重做）

- 三层：App（SwiftUI + `SystemTunnelManager`）→ Packet Tunnel 扩展（`TunnelEngine` 读 TUN 分发）→ `Packages/SharedCore`（加密/路由/存储，纯逻辑可单测）。
- `TunnelEngine.swift:92` 按协议分发：**UDP/53 → `DNSCoordinator`，TCP → `TCPRouter`，其余全部丢弃**。
- 分流闭环已生效（真机已验证）：
  - `RouteMatcher`（SharedCore/Routing）：`route(forHost:ipString:)` 给 TCP 用，`dnsDecision(forHost:)` 给 DNS 用；代理名单 > 内网段（内置常量）> 域名白名单 > CN 段 > 默认代理。
  - DNS：`DNSCoordinator` 按 `dnsDecision` 分流——直连域名走 `LocalDNSUpstreamClient`（本地 UDP 223.5.5.5），其余走 `ProxyDNSUpstreamClient`（8.8.8.8 over SS TCP）。AAAA 查询一律回空应答（隧道只接管 IPv4，防止 App 拿 v6 绕走本地）。A 记录入 `DNSCache`，TCP 建连时 `TCPRouter` 用 `DNSCache.lookupDomain` 反查域名做名单判定。
  - CN IP 库：内置 `PacketTunnel/china-ip-list.txt`（17mon，约 7.4k 条），App 内可下载更新，下载版优先。
  - UI：「导入与分流」页（现位于浏览器 `...` 菜单内）；名单每行有「测试」按钮（`App/DomainRouteTester.swift`：本地解析 → RouteMatcher 决策 → 直连时实测 TCP 443 耗时）。
- Bundle ID `com.fits.socks.one`（扩展 `.PacketTunnel`）、app group `group.com.fitz.app`、keychain `com.fits.socks.one.shared`、`DEVELOPMENT_TEAM=8Z7LGX7B48` 均已固化在 `project.yml` / entitlements。

## 任务 A：UDP 转发（已完成，2026-08-20）

已实现并推送：SharedCore 新增 `ShadowsocksUDPPacketCodec`（SIP004 AEAD，全零 nonce）与 `ShadowsocksUDPTransport`；`PacketTunnel/UDP/` 新增 `UDPRouter`（四元组 NAT 会话，过 `RouteMatcher` 分流，上限 256、空闲 60s 回收）+ `DirectUDPRelay` / `ShadowsocksUDPRelay`；端口 53 的 DNS 拦截保持优先。真机验证：默认代理配置下 Google/百度/QQ 均可访问。

**踩过的坑（勿回退）**：`UDPRouter.route` 不得内联 `await` relay 的 start/send——引擎读包循环是串行的，一个卡在 `.waiting` 的 UDP NWConnection（mDNS/STUN/不可达端点）会冻结整个隧道（DNS+TCP 全挂）。现在是 fire-and-forget 派发 + 5s 超时回收会话（`UDPRouter.dispatch`）。relay 的 `stop()` 不要先清 `stateUpdateHandler` 再 cancel，否则挂起的 ready 等待永不释放。

**新增诊断设施**：`TunnelDiagnosticsStore`（SharedCore，app group UserDefaults 环形缓冲 200 行）+ App「导入与分流」页底部「隧道诊断」区块（可全选复制）。隧道侧通过 `TunnelDiagnosticsLogging` 闭包注入 DNSCoordinator/TCPRouter/UDPRouter/Engine/relays，记录会话级事件（DNS 决策与应答 IP、TCP/UDP 分流决策、relay ready/recv/closed、ENGINE fatal、tunnel stop reason）。真机排障先让用户看这个。

**配置注意**：原「未命中名单时直连」开关已移除（2026-08-21）——它的语义是「未命中域名走本地解析 + 直连」，被墙站点必然拿到污染 IP（实测 google.com.hk → 199.16.158.8），开着必坏。现在未命中名单的流量一律远程解析 + 代理，国内直连由域名白名单与「国内 IP 直连」（CN 段兜底）承担。

## 任务 B：弱网 TCP（已完成，2026-08-21）

**现状**：用户态最小 TCP 终结——ISN 固定为 1；客户端 → 服务端方向靠客户端 TCP 自身重传兜底（router 对重传包只重 ACK，语义正确）。

**已完成（2026-08-21）**：

1. **服务端 → 客户端方向的出站重传**。`TCPSendBuffer`（按段记录已发未 ACK 的 payload，整段累积确认，序号回绕安全）+ `TCPRetransmitter`（250ms 周期扫描，指数退避封顶 8 倍 RTO、单段最多重发 10 次），重发包保持原序列号，诊断日志前缀 `TCP rexmit`。客户端 ACK 在 `TCPRouter.route` 里挂钩清除缓冲。
2. **RTT 估计（Jacobson/Karn）**。`RTTEstimator`（srtt/rttvar → RTO = srtt + 4·var，钳制 [0.2s, 8s]，初始 1s）；只采样未重传过的段（Karn 规则），rexmit 日志带当前 `rto=`。
3. **接收窗口通告**。relay 暴露在途字节数（`queuedOutboundBytes`），`TCPFlowWindow` 按 256KB 容量余量收缩通告窗口（未协商 wscale，上限恒 0xFFFF）；零窗口时客户端的 1 字节探测会走 router 的重复 ACK 分支拿到新窗口。`ShadowsocksTCPRelay` 发送链仍是 fire-and-forget（ awaited 会卡死串行读包循环，UDP 那个坑的 TCP 版），窗口是唯一回压手段。
4. **拥塞控制（慢启动 + 拥塞避免）**。`TCPCongestionController`：初始窗口 10×MSS（RFC 6928），每 ACK +1 MSS（慢启动）/ +MSS²/cwnd（拥塞避免），段进入超时重传即记丢包（阈值折半、窗口退回 1 MSS）。inbound 数据先进会话的 `pendingInbound`，`TCPRouter.flushPendingInbound` 按窗口余量切段写 TUN，窗口打满时由后续 ACK 驱动续发。

**关键文件**（`PacketTunnel/TCP/`）：`TCPFlowState.swift`（状态机：consume 事件 → 响应）、`TCPRouter.swift`（会话分发 + inbound 窗口发送）、`TCPRetransmitter.swift` / `TCPSendBuffer.swift`（重传）、`TCPCongestionController.swift`（拥塞窗口）、`DirectTCPRelay.swift` / `ShadowsocksTCPRelay.swift`、`TCPFlowSessionStore.swift`（会话 + 发送缓冲 + 拥塞状态存储）。

序列号/ISN 逻辑都在 `TCPFlowState`，改动要保持现有测试全绿（ISN 目前固定为 1，多个测试断言依赖它；改随机 ISN 需同步更新测试）。

## 验证

- 每次改动：`xcodegen && make test` 全绿 → 分类 commit → push。
- 真机验证（`make run`）：
  - UDP/QUIC：Safari 访问 Google 系站点，用 Mac 端 `tcpdump` 或路由表观察 UDP/443 是否走通；语音用 FaceTime/微信语音实测。
  - 弱网 TCP：iOS 开发者设置里的 Network Link Conditioner 模拟丢包/高延迟，对比改进前后的加载体验。

## 护盾账号 + WireGuard 数据面（2026-08-25，已完成）

- 「护盾账号」入口在浏览器 `...` 菜单：登录/退出/静默恢复（4003 自动清凭证）、线路快照缓存、选线即连接。
- 选线流程：`HudunSessionViewModel.requestConnect` → renew 现取 WG 凭证 → `HudunTunnelCoordinator.activate` 写入 app group 配置 + Keychain 私钥 + 活动模式标记 → 复用同一 NETunnelProviderManager 连接。
- 扩展侧按 `active-tunnel-mode.json` 分流：wireguard 走 `PacketTunnel/WireGuard/WireGuardTunnelPump.swift`（全局模式接管，无 DNS 劫持、无分流），shadowsocks 走原引擎。ConnectionIntegrationTests target 也编译 WireGuard 目录（project.yml 已加）。
- **服务端是白皮书链式 KDF 变体**（非 wireguard-go）：KDF3 第三输出 = HMAC(t, T2‖0x3)；msg1 需 mixKey(E_pub)；响应三段 mixKey 后 KDF3(psk)、τ 混 hash 作 AAD；响应 mac 全零。详见 docs/hudun_master_doc.md §8 第 7 条。SharedCore 的 WireGuardCrypto/WireGuardHandshake 已对齐此语义，回环单测以 wireguard-go 语义+该变体双向守护。
- 排障：握手问题看「导入与分流」底部隧道诊断的 `WG handshake ok/rejected/fatal` 行；数据面不通而握手 ok 时查 pump 收发日志。
