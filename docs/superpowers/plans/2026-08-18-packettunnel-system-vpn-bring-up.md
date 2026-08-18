# PacketTunnel 系统 VPN 接管 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `Shadowsocks One` 的“连接/断开”按钮真正拉起 `NETunnelProviderManager` 与 `PacketTunnelProvider`，在真机上出现系统 VPN 状态，并把系统 VPN 未就绪与 App 内直连状态明确区分开。

**Architecture:** 本计划只接管“系统 VPN 控制面”，不在这一轮实现完整的系统流量转发。`App` 继续负责导入、节点选择与共享配置写入；`SystemTunnelManager` 成为连接生命周期唯一入口；`PacketTunnelProvider` 保持最小可启动形态，只负责读取共享配置、设置 `NEPacketTunnelNetworkSettings` 并把启动失败透明返回给系统。

**Tech Stack:** Swift, SwiftUI, Foundation, NetworkExtension, SharedCore, XCTest

---

## Scope

这份计划只解决下面 3 件事：

1. App 的“连接”改为走 `SystemTunnelManager`
2. 真机上能看到系统 VPN 连接状态变化
3. `PacketTunnelProvider` 的启动路径可验证、错误可定位

明确不包含：

- 完整的 `PacketTunnel` TCP/UDP 数据面转发
- 真正的系统全局代理可用性闭环
- 插件节点支持

完整数据面应在本计划完成后，单独再写一份 `PacketTunnel data plane` 计划。

## File Structure

本计划创建或修改的主要文件如下：

- `Shadowsocks One/App/TunnelControlling.swift`
  - 新增系统隧道控制协议，隔离 `RootViewModel` 与 `NetworkExtension` 细节。
- `Shadowsocks One/App/SystemTunnelManager.swift`
  - 让 `NETunnelProviderManager` 的加载、保存、连接、断开与状态观察都收口在这里。
- `Shadowsocks One/App/RootViewModel.swift`
  - 把当前“连接”主路径从 `ConnectionManager` 切换到 `SystemTunnelManager`。
- `Shadowsocks One/App/RootView.swift`
  - 如有必要，补系统 VPN 状态提示文案。
- `Shadowsocks One/PacketTunnel/PacketTunnelProvider.swift`
  - 保持最小可启动 `PacketTunnel`，把共享配置读取与启动失败路径收紧。
- `Shadowsocks One/Tests/ConnectionIntegrationTests/RootViewModelSystemTunnelTests.swift`
  - 覆盖 `RootViewModel` 对系统 VPN 控制器的调用和状态同步。
- `Shadowsocks One/Packages/SharedCore/Tests/SharedCoreTests/TunnelConfigurationStoreTests.swift`
  - 补启动配置缺失等基础场景，保证 `PacketTunnelProvider` 的前置依赖稳定。

---

### Task 1: 抽象系统隧道控制接口并切换连接入口

**Files:**
- Create: `Shadowsocks One/App/TunnelControlling.swift`
- Modify: `Shadowsocks One/App/SystemTunnelManager.swift`
- Modify: `Shadowsocks One/App/RootViewModel.swift`
- Test: `Shadowsocks One/Tests/ConnectionIntegrationTests/RootViewModelSystemTunnelTests.swift`

- [ ] **Step 1: 先写失败测试，锁定 `RootViewModel` 必须调用系统隧道控制器**

```swift
// Shadowsocks One/Tests/ConnectionIntegrationTests/RootViewModelSystemTunnelTests.swift
import XCTest
import SharedCore
@testable import ShadowsocksOne

@MainActor
final class RootViewModelSystemTunnelTests: XCTestCase {
    func testConnectSelectedProfileUsesSystemTunnelController() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let tunnelController = TunnelControllerSpy()
        let viewModel = RootViewModel(
            parser: ParserStub(profile: .fixture()),
            connectionManager: ConnectionManager(),
            tunnelController: tunnelController,
            storeBuilder: {
                try ProfileStore(
                    localDirectory: tempDirectory,
                    keychainService: UUID().uuidString
                )
            },
            tunnelStoreBuilder: {
                throw DummyError.disabled
            }
        )

        viewModel.importProfile()
        viewModel.connectSelectedProfile()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(tunnelController.connectCalls, 1)
    }
}

private enum DummyError: Error {
    case disabled
}

private struct ParserStub: SSURLParsing {
    let profile: ServerProfile

    func parse(_ raw: String) throws -> ServerProfile {
        profile
    }
}

private final class TunnelControllerSpy: TunnelControlling {
    private(set) var connectCalls = 0
    var state: ConnectionState = .idle
    let stateStream: AsyncStream<ConnectionState> = AsyncStream { _ in }

    func prepare() async {}

    func connect() async throws {
        connectCalls += 1
    }

    func disconnect() {}
}

private extension ServerProfile {
    static func fixture() -> ServerProfile {
        ServerProfile(
            host: "1.2.3.4",
            port: 8388,
            method: .aes128GCM,
            password: "pass",
            remark: "demo"
        )
    }
}
```

- [ ] **Step 2: 跑测试确认它先失败**

Run:
`xcodebuild -project "/Users/fitz/REPO/ShadowsocksX-NG/Shadowsocks One/Shadowsocks One.xcodeproj" -scheme "Shadowsocks One" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ConnectionIntegrationTests/RootViewModelSystemTunnelTests test`

Expected: FAIL，提示 `RootViewModel` 缺少 `tunnelController` 注入或 `TunnelControlling` 类型不存在

- [ ] **Step 3: 写最小实现，把连接主路径改成系统隧道控制器**

```swift
// Shadowsocks One/App/TunnelControlling.swift
import SharedCore

@MainActor
protocol TunnelControlling: AnyObject {
    var state: ConnectionState { get }
    var stateStream: AsyncStream<ConnectionState> { get }
    func prepare() async
    func connect() async throws
    func disconnect()
}
```

```swift
// Shadowsocks One/App/SystemTunnelManager.swift
@MainActor
final class SystemTunnelManager: TunnelControlling {
    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        let managers = try await loadAllManagers()
        let manager = managers.first {
            let provider = $0.protocolConfiguration as? NETunnelProviderProtocol
            return provider?.providerBundleIdentifier == providerBundleIdentifier
        } ?? NETunnelProviderManager()
        configure(manager)
        try await save(manager)
        try await load(manager)
        return manager
    }
}
```

```swift
// Shadowsocks One/App/RootViewModel.swift
private let tunnelController: any TunnelControlling

init(
    parser: any SSURLParsing,
    connectionManager: ConnectionManager,
    tunnelController: any TunnelControlling,
    storeBuilder: () throws -> ProfileStore,
    tunnelStoreBuilder: () throws -> TunnelConfigurationStore
) {
    self.parser = parser
    self.connectionManager = connectionManager
    self.tunnelController = tunnelController
    self.store = try? storeBuilder()
    self.tunnelStore = try? tunnelStoreBuilder()
    refreshInformationalMessage()
    reloadProfiles()
    observeTunnelState()
    Task { await tunnelController.prepare() }
}

func connectSelectedProfile() {
    guard let selectedProfile else {
        message = "请先选择一个节点。"
        return
    }

    Task {
        do {
            try tunnelStore?.save(profile: selectedProfile)
            try await tunnelController.connect()
        } catch {
            message = "系统 VPN 启动失败：\\(error.localizedDescription)"
        }
    }
}

func disconnect() {
    tunnelController.disconnect()
}
```

- [ ] **Step 4: 跑测试并确认 App 还能编译**

Run:
`xcodebuild -project "/Users/fitz/REPO/ShadowsocksX-NG/Shadowsocks One/Shadowsocks One.xcodeproj" -scheme "Shadowsocks One" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ConnectionIntegrationTests/RootViewModelSystemTunnelTests test`

Expected: PASS

Run:
`xcodebuild -project "/Users/fitz/REPO/ShadowsocksX-NG/Shadowsocks One/Shadowsocks One.xcodeproj" -scheme "Shadowsocks One" -destination 'generic/platform=iOS Simulator' build`

Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: 提交这一小步**

```bash
git add \
  "Shadowsocks One/App/TunnelControlling.swift" \
  "Shadowsocks One/App/SystemTunnelManager.swift" \
  "Shadowsocks One/App/RootViewModel.swift" \
  "Shadowsocks One/Tests/ConnectionIntegrationTests/RootViewModelSystemTunnelTests.swift"
git commit -m "feat(ios): route connect flow through system tunnel manager"
```

---

### Task 2: 把系统 VPN 状态和错误文案接到 ViewModel

**Files:**
- Modify: `Shadowsocks One/App/RootViewModel.swift`
- Modify: `Shadowsocks One/App/RootView.swift`
- Test: `Shadowsocks One/Tests/ConnectionIntegrationTests/RootViewModelSystemTunnelTests.swift`

- [ ] **Step 1: 补失败测试，锁定状态同步和错误提示**

```swift
func testTunnelStateStreamUpdatesConnectionState() async throws {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let tunnelController = StreamingTunnelControllerSpy()
    let viewModel = RootViewModel(
        parser: ParserStub(profile: .fixture()),
        connectionManager: ConnectionManager(),
        tunnelController: tunnelController,
        storeBuilder: {
            try ProfileStore(
                localDirectory: tempDirectory,
                keychainService: UUID().uuidString
            )
        },
        tunnelStoreBuilder: {
            throw DummyError.disabled
        }
    )

    tunnelController.yield(.connected)
    try await Task.sleep(nanoseconds: 50_000_000)

    XCTAssertEqual(viewModel.connectionState, .connected)
}

func testConnectFailureShowsSystemVPNError() async throws {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let tunnelController = FailingTunnelControllerSpy()
    let viewModel = RootViewModel(
        parser: ParserStub(profile: .fixture()),
        connectionManager: ConnectionManager(),
        tunnelController: tunnelController,
        storeBuilder: {
            try ProfileStore(
                localDirectory: tempDirectory,
                keychainService: UUID().uuidString
            )
        },
        tunnelStoreBuilder: {
            throw DummyError.disabled
        }
    )

    viewModel.importProfile()
    viewModel.connectSelectedProfile()
    try await Task.sleep(nanoseconds: 50_000_000)

    XCTAssertEqual(viewModel.message, "系统 VPN 启动失败：permission denied")
}
```

- [ ] **Step 2: 跑测试确认状态观察还没接通**

Run:
`xcodebuild -project "/Users/fitz/REPO/ShadowsocksX-NG/Shadowsocks One/Shadowsocks One.xcodeproj" -scheme "Shadowsocks One" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ConnectionIntegrationTests/RootViewModelSystemTunnelTests test`

Expected: FAIL，`connectionState` 仍停留在 `.idle`，或错误文案与预期不一致

- [ ] **Step 3: 写最小实现，收口系统 VPN 状态和提示**

```swift
// Shadowsocks One/App/RootViewModel.swift
private func observeTunnelState() {
    stateTask = Task {
        for await state in tunnelController.stateStream {
            connectionState = state
            if case let .failed(message) = state {
                self.message = "系统 VPN 启动失败：\\(message)"
            } else if tunnelStore == nil {
                self.message = Self.tunnelUnavailableMessage
            }
        }
    }
}

private func refreshInformationalMessage() {
    if store == nil {
        message = Self.localStoreUnavailableMessage
    } else if tunnelStore == nil {
        message = Self.tunnelUnavailableMessage
    } else {
        message = "系统 VPN 已就绪，首次连接时会触发系统授权。"
    }
}
```

```swift
// Shadowsocks One/App/RootView.swift
if let message = viewModel.message {
    Section("提示") {
        Text(message)
            .foregroundStyle(.secondary)
    }
}
```

- [ ] **Step 4: 跑测试并重新构建**

Run:
`xcodebuild -project "/Users/fitz/REPO/ShadowsocksX-NG/Shadowsocks One/Shadowsocks One.xcodeproj" -scheme "Shadowsocks One" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ConnectionIntegrationTests/RootViewModelSystemTunnelTests test`

Expected: PASS

Run:
`xcodebuild -project "/Users/fitz/REPO/ShadowsocksX-NG/Shadowsocks One/Shadowsocks One.xcodeproj" -scheme "Shadowsocks One" -destination 'generic/platform=iOS Simulator' build`

Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: 提交这一小步**

```bash
git add \
  "Shadowsocks One/App/RootViewModel.swift" \
  "Shadowsocks One/App/RootView.swift" \
  "Shadowsocks One/Tests/ConnectionIntegrationTests/RootViewModelSystemTunnelTests.swift"
git commit -m "fix(ios): surface system vpn state in app ui"
```

---

### Task 3: 收紧 PacketTunnel 启动路径并完成真机冒烟验证

**Files:**
- Modify: `Shadowsocks One/PacketTunnel/PacketTunnelProvider.swift`
- Test: `Shadowsocks One/Packages/SharedCore/Tests/SharedCoreTests/TunnelConfigurationStoreTests.swift`

- [ ] **Step 1: 先补一个失败测试，锁定“缺配置时必须报错”**

```swift
func testFailsWhenLaunchConfigurationIsMissing() throws {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let store = TunnelConfigurationStore(
        jsonURL: tempDirectory.appendingPathComponent("tunnel.json"),
        keychain: InMemoryPasswordStore()
    )

    XCTAssertThrowsError(try store.loadLaunchConfiguration()) { error in
        XCTAssertEqual(
            error as? TunnelConfigurationError,
            .missingConfiguration
        )
    }
}
```

- [ ] **Step 2: 跑 SharedCore 测试确认它先失败**

Run:
`xcodebuild -scheme SharedCore -destination 'platform=macOS' test`

Expected: FAIL，提示缺少 `missingConfiguration` 相关断言用例或行为不一致

- [ ] **Step 3: 写最小实现，让 PacketTunnelProvider 启动路径更可诊断**

```swift
// Shadowsocks One/PacketTunnel/PacketTunnelProvider.swift
import NetworkExtension
import SharedCore

final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(
        options: [String : NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            let configuration = try TunnelConfigurationStore(
                appGroupID: SharedContainerSettings.appGroupID,
                keychainService: SharedContainerSettings.keychainService
            ).loadLaunchConfiguration()

            let settings = NEPacketTunnelNetworkSettings(
                tunnelRemoteAddress: configuration.connection.host
            )
            settings.ipv4Settings = NEIPv4Settings(
                addresses: ["10.0.0.2"],
                subnetMasks: ["255.255.255.0"]
            )
            settings.ipv4Settings?.includedRoutes = [NEIPv4Route.default()]
            settings.mtu = 1500 as NSNumber

            setTunnelNetworkSettings(settings) { error in
                if let error {
                    NSLog("PacketTunnel setTunnelNetworkSettings failed: %@", error.localizedDescription)
                }
                completionHandler(error)
            }
        } catch {
            NSLog("PacketTunnel startTunnel failed: %@", error.localizedDescription)
            completionHandler(error)
        }
    }
}
```

- [ ] **Step 4: 跑测试、构建，并做真机冒烟**

Run:
`xcodebuild -scheme SharedCore -destination 'platform=macOS' test`

Expected: `TEST SUCCEEDED`

Run:
`xcodebuild -project "/Users/fitz/REPO/ShadowsocksX-NG/Shadowsocks One/Shadowsocks One.xcodeproj" -scheme "Shadowsocks One" -destination 'generic/platform=iOS' build`

Expected: `BUILD SUCCEEDED`

Manual:

1. 用真机安装 `Shadowsocks One`
2. 导入一个可用 `ss://` 节点
3. 点击“连接”
4. 首次弹系统 VPN 授权框，选择允许
5. 观察状态栏是否出现 `VPN`
6. 打开 iOS 设置 -> VPN，确认 `Shadowsocks One` 处于已连接或连接中

Expected:

- 首次连接会弹系统授权
- App 内连接状态从“未连接”变成“连接中/已连接”
- 状态栏出现 `VPN`
- 若失败，App 的提示区能看到明确错误，而不是静默无响应

- [ ] **Step 5: 提交这一小步**

```bash
git add \
  "Shadowsocks One/PacketTunnel/PacketTunnelProvider.swift" \
  "Shadowsocks One/Packages/SharedCore/Tests/SharedCoreTests/TunnelConfigurationStoreTests.swift"
git commit -m "fix(ios): harden packet tunnel startup path"
```

---

## Self-Review

- 这份计划覆盖了当前最缺的控制面切换、状态同步、启动诊断三部分
- 没有把完整数据面转发塞进来，范围保持在可执行的 MVP bring-up
- 所有任务都给了明确文件、命令、测试和提交粒度

## Execution Notes

- 真机是必需项；系统 VPN 图标不能以模拟器结果为准
- 如果 Task 3 完成后仍然没有 `VPN` 图标，优先排查签名、`NetworkExtension` capability、App Group 与 provider bundle id
- 如果 `VPN` 图标出现但系统流量仍不走代理，那是下一份“PacketTunnel 数据面实现计划”的范围
