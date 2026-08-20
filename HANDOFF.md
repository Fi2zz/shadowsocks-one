# Handoff — Shadowsocks One 仓库重构与后续事项

> 写给下一个接手会话/协作者。日期：2026-08-20。

## 仓库现状

- 远端：`git@github.com:Fi2zz/shadowsocks-one.git`，主分支 `master`，本地已建立跟踪。
- 本地路径：`/Users/fitz/REPO/ShadowsocksX-NG`（目录名未改，建议择期重命名为 `shadowsocks-one`）。
- 本仓库原为 ShadowsocksX-NG 的 fork，已删除全部旧内容，只保留 iOS 新项目并提升到仓库根目录。
- 历史：已 unshallow（含原仓库完整历史与 tag v1.9.x；tag 未推送，如不需要可 `git tag | xargs git tag -d` 清理）。
- 分支：`master` 为唯一活跃分支；`develop`、`feat/shadowsocks-one-bootstrap`、`feat/shadowsocks-one-direct-connection` 为历史遗留本地分支。

## 本次会话已完成（均已推送）

| 提交 | 内容 |
|---|---|
| `90d9c85` | 删除 ShadowsocksX-NG 旧内容（620 文件，含 Pods/submodules/.github） |
| `74baf5b` | 清理 deps 残留；恢复误删的 `docs/`（Shadowsocks One 设计文档） |
| `a5ffa73` | 后台保活加固（见下） |
| `385137e` | `Shadowsocks One/` 子目录内容上提到仓库根目录（纯 rename） |

后台保活加固（`a5ffa73`）细节：

- `App/TunnelControlling.swift` / `App/SystemTunnelManager.swift`：新增 `refreshStatus()`。
- `App/RootView.swift` / `App/RootViewModel.swift`：`scenePhase == .active` 时 re-sync 连接状态。
- `PacketTunnel/PacketTunnelProvider.swift`：实现 `sleep/wake`（停/启引擎，`startEngine()` 提取自 startTunnel 内联闭包）。
- 测试 spy 同步补 `refreshStatus()`。
- 结论性认知：Packet Tunnel 由系统托管，App 退后台/被杀 VPN 本来就不断（真机已验证），以上只是健壮性补齐。

## 待办（按优先级）

1. ~~提交 README.md~~ 已完成（`bd9982a`）。
2. ~~xcodeproj 改名~~ 已完成（`3131e7b`）：`ShadowsocksOne.xcodeproj`，只改了 `project.yml` 的 `name`，target/scheme 名未动。
3. ~~既有测试失败~~ 已解决：根因有二。(a) 旧 pbxproj 里手动维护的测试目标配置（`PacketTunnel` 源码编入测试 bundle、以 App 为 TEST_HOST）不在 project.yml 里，xcodegen 重新生成后丢失，已在 project.yml 补齐；(b) `CODE_SIGNING_ALLOWED=NO` 时测试宿主 App 无签名 → Keychain `SecItemAdd` 失败 → `importProfile` 保存抛错导致 `selectedProfile` 为 nil。**测试必须带默认签名运行（不要加 `CODE_SIGNING_ALLOWED=NO`）。** 修复后全部测试通过。
4. **未跟踪文件**：`.dbg/`、`debug-vpn-webpage-blocked.md`（调试残留，用户决定是否删除/提交）。
5. **Bundle ID 已替换**：`com.fits.socks.one*`（含扩展 `.PacketTunnel`，`App/RootViewModel.swift` 的 providerBundleIdentifier 已同步）；app group 为 `group.com.fitz.app`。仅剩 keychain service `com.example.ShadowsocksOne.shared` 为占位（替换需同步两个 target 的 `keychain-access-groups`）。

## 环境注意事项

- **上一会话的 shell 因会话工作目录（已删除的 `Shadowsocks One/` 子目录）消失而完全不可用**（spawn ENOENT）。新会话请以 `/Users/fitz/REPO/ShadowsocksX-NG` 为工作目录启动。
- 构建：`xcodebuild -project ShadowsocksOne.xcodeproj -scheme "Shadowsocks One" -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO`
- 测试：`... -destination 'platform=iOS Simulator,name=iPhone 17' test`（**不要加 `CODE_SIGNING_ALLOWED=NO`**，否则 Keychain 失败导致 RootViewModel 相关用例失败）。SharedCore 与集成测试当前全绿。

## 架构速览（详见根目录 README.md）

- 三层：App（SwiftUI + `SystemTunnelManager` 管 `NETunnelProviderManager`）→ Packet Tunnel 扩展（`TunnelEngine` 读 TUN 分发 UDP/53→`DNSCoordinator`、TCP→`TCPRouter`）→ `Packages/SharedCore`（加密/路由/存储，纯逻辑可单测）。
- 用户态最小 TCP 终结：伪造 SYN-ACK、按序接收、1460 切片回包；无重传/窗口。
- DNS：经 SS TCP 转发 8.8.8.8 出口侧解析，A 记录入 `DNSCache`；域名分流反查**尚未接入** TCP 决策，CN IP 列表为空 → 当前等同全局代理。
- 配置通道：App Group JSON + 共享 Keychain + suite UserDefaults，无 IPC。
