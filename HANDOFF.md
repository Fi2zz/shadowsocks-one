# Handoff — 弱网 TCP 增强（任务 B）

> 写给下一个接手会话。日期：2026-08-20。
> 任务 A（UDP 转发）已完成并真机验证通过（见下文「任务 A」节的结论与坑）。剩余目标：任务 B 弱网 TCP 体感优化。

## 仓库与流程（必读）

- 路径 `/Users/fitz/REPO/ShadowsocksX-NG`（目录名未改，可择期 rename 为 shadowsocks-one）；远端 `git@github.com:Fi2zz/shadowsocks-one.git`，唯一分支 `master`。
- 工程由 XcodeGen 生成：**新增/删除源文件后必须跑 `xcodegen`**（`make` 各目标已内置）。
- Makefile：`make test`（模拟器）、`make run`（构建+安装+启动到真机 iPhone 16，device id `14EDD430-3B6F-5969-B920-F1C427404CA4`）。
- **测试不要加 `CODE_SIGNING_ALLOWED=NO`**：会导致测试宿主 Keychain 失败、RootViewModel 用例挂。只有纯 `make build` 用了它。
- 提交规范（用户全局 AGENTS.md）：中文交流；函数 ≤20 行、文件 ≤200 行、单函数分支 ≤3；布尔命名禁 is/has 前缀；完成改动后用 `git-commit` skill 按逻辑分类提交并直接 push（已授权）。
- 项目决定**不上架 App Store**，无需考虑审核相关约束。

## 当前架构状态（已完成，勿重做）

- 三层：App（SwiftUI + `SystemTunnelManager`）→ Packet Tunnel 扩展（`TunnelEngine` 读 TUN 分发）→ `Packages/SharedCore`（加密/路由/存储，纯逻辑可单测）。
- `TunnelEngine.swift:92` 按协议分发：**UDP/53 → `DNSCoordinator`，TCP → `TCPRouter`，其余全部丢弃**。
- 分流闭环已生效（真机已验证）：
  - `RouteMatcher`（SharedCore/Routing）：`route(forHost:ipString:)` 给 TCP 用，`dnsDecision(forHost:)` 给 DNS 用；代理名单 > 内网段（内置常量）> 域名白名单 > CN 段 > 默认代理。
  - DNS：`DNSCoordinator` 按 `dnsDecision` 分流——直连域名走 `LocalDNSUpstreamClient`（本地 UDP 223.5.5.5），其余走 `ProxyDNSUpstreamClient`（8.8.8.8 over SS TCP）。A 记录入 `DNSCache`，TCP 建连时 `TCPRouter` 用 `DNSCache.lookupDomain` 反查域名做名单判定。
  - CN IP 库：内置 `PacketTunnel/china-ip-list.txt`（17mon，约 7.4k 条），App 内可下载更新，下载版优先。
  - UI：「导入与分流」单 Tab；名单每行有「测试」按钮（`App/DomainRouteTester.swift`：本地解析 → RouteMatcher 决策 → 直连时实测 TCP 443 耗时）。
- Bundle ID `com.fits.socks.one`（扩展 `.PacketTunnel`）、app group `group.com.fitz.app`、keychain `com.fits.socks.one.shared`、`DEVELOPMENT_TEAM=8Z7LGX7B48` 均已固化在 `project.yml` / entitlements。

## 任务 A：UDP 转发（已完成，2026-08-20）

已实现并推送：SharedCore 新增 `ShadowsocksUDPPacketCodec`（SIP004 AEAD，全零 nonce）与 `ShadowsocksUDPTransport`；`PacketTunnel/UDP/` 新增 `UDPRouter`（四元组 NAT 会话，过 `RouteMatcher` 分流，上限 256、空闲 60s 回收）+ `DirectUDPRelay` / `ShadowsocksUDPRelay`；端口 53 的 DNS 拦截保持优先。真机验证：默认代理配置下 Google/百度/QQ 均可访问。

**踩过的坑（勿回退）**：`UDPRouter.route` 不得内联 `await` relay 的 start/send——引擎读包循环是串行的，一个卡在 `.waiting` 的 UDP NWConnection（mDNS/STUN/不可达端点）会冻结整个隧道（DNS+TCP 全挂）。现在是 fire-and-forget 派发 + 5s 超时回收会话（`UDPRouter.dispatch`）。relay 的 `stop()` 不要先清 `stateUpdateHandler` 再 cancel，否则挂起的 ready 等待永不释放。

**新增诊断设施**：`TunnelDiagnosticsStore`（SharedCore，app group UserDefaults 环形缓冲 200 行）+ App「导入与分流」页底部「隧道诊断」区块（可全选复制）。隧道侧通过 `TunnelDiagnosticsLogging` 闭包注入 DNSCoordinator/TCPRouter/UDPRouter/Engine/relays，记录会话级事件（DNS 决策与应答 IP、TCP/UDP 分流决策、relay ready/recv/closed、ENGINE fatal、tunnel stop reason）。真机排障先让用户看这个。

**配置注意**：原「未命中名单时直连」开关已移除（2026-08-21）——它的语义是「未命中域名走本地解析 + 直连」，被墙站点必然拿到污染 IP（实测 google.com.hk → 199.16.158.8），开着必坏。现在未命中名单的流量一律远程解析 + 代理，国内直连由域名白名单与「国内 IP 直连」（CN 段兜底）承担。

## 任务 B：弱网 TCP

**现状**：用户态最小 TCP 终结——无重传、无窗口/拥塞控制、ISN 固定；丢包靠客户端 TCP 自身重传兜底（router 对重传包只重 ACK，语义正确但出口方向丢包 = 该连接卡死）。

**关键文件**（`PacketTunnel/TCP/`，共约 750 行）：`TCPFlowState.swift`（状态机：consume 事件 → 响应）、`TCPRouter.swift`（272 行，会话分发）、`DirectTCPRelay.swift` / `ShadowsocksTCPRelay.swift`、`TCPFlowSessionStore.swift`。

**按收益排序**：

1. **出站重传**：relay 发出的 payload 段未被 ACK 时需要重传（当前发完即忘）。需要发送缓冲 + RTO 定时器（可先固定 RTO，再做 RTT 估计）。
2. **接收窗口通告**：按缓冲余量收缩通告窗口，防止高速发送方打爆内存。
3. 拥塞控制（cwnd/slow start）——最后做，前两项收益更大。

序列号/ISN 逻辑都在 `TCPFlowState`，改动要保持现有测试全绿。

## 验证

- 每次改动：`xcodegen && make test` 全绿 → 分类 commit → push。
- 真机验证（`make run`）：
  - UDP/QUIC：Safari 访问 Google 系站点，用 Mac 端 `tcpdump` 或路由表观察 UDP/443 是否走通；语音用 FaceTime/微信语音实测。
  - 弱网 TCP：iOS 开发者设置里的 Network Link Conditioner 模拟丢包/高延迟，对比改进前后的加载体验。
