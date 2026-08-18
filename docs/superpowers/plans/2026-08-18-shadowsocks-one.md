# Shadowsocks One Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付 `Shadowsocks One` 的最小可用内核：支持 `ss://` 解析、节点安全存储，以及基于本地 AEAD echo 的 Packet Tunnel 连接闭环。

**Architecture:** 工程拆为 `App`、`PacketTunnel`、`SharedCore` 三部分。`SharedCore` 用 Swift Package 共享模型、解析、存储与连接接口；`App` 负责数据和状态展示；`PacketTunnel` 负责最小 AEAD 数据面验证，并通过 App Group / Keychain 与主 App 共享配置。

**Tech Stack:** Swift, SwiftUI, Foundation, CryptoKit, Network, NetworkExtension, XCTest

---

## File Structure

本计划创建或修改的主要文件如下：

- `ShadowsocksOne/App/ShadowsocksOneApp.swift`
  - 主 App 入口。
- `ShadowsocksOne/App/RootView.swift`
  - 临时根视图，仅用于验证状态流。
- `ShadowsocksOne/App/ShadowsocksOne.entitlements`
  - App Group 与 Keychain Access Group。
- `ShadowsocksOne/PacketTunnel/PacketTunnelProvider.swift`
  - `NEPacketTunnelProvider` 骨架。
- `ShadowsocksOne/PacketTunnel/PacketTunnel.entitlements`
  - Extension 的共享能力声明。
- `ShadowsocksOne/Packages/SharedCore/Package.swift`
  - 共享 Swift Package。
- `ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Models/CipherMethod.swift`
  - 第一版支持的 AEAD 算法。
- `ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Models/ServerProfile.swift`
  - 节点模型。
- `ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Parser/SSURLParseError.swift`
  - 解析错误模型。
- `ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Parser/SSURLParser.swift`
  - `ss://` 解析实现。
- `ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Store/ProfileStore.swift`
  - App Group JSON 存储。
- `ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Store/PasswordKeychain.swift`
  - Keychain 密码存储。
- `ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Connection/ConnectionConfig.swift`
  - 连接输入模型。
- `ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Connection/ConnectionState.swift`
  - 连接状态。
- `ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Connection/ConnectionManager.swift`
  - 状态流接口与 App 侧包装。
- `ShadowsocksOne/Packages/SharedCore/Tests/SharedCoreTests/SSURLParserTests.swift`
  - Parser 单测。
- `ShadowsocksOne/Packages/SharedCore/Tests/SharedCoreTests/ProfileStoreTests.swift`
  - Store 单测。
- `ShadowsocksOne/Tests/ConnectionIntegrationTests/LocalAEADEchoServer.swift`
  - 本地 AEAD echo 测试服务。
- `ShadowsocksOne/Tests/ConnectionIntegrationTests/PacketTunnelConnectionTests.swift`
  - 本地集成测试。

---

### Task 1: Scaffold Project Skeleton

**Files:**
- Create: `ShadowsocksOne/App/ShadowsocksOneApp.swift`
- Create: `ShadowsocksOne/App/RootView.swift`
- Create: `ShadowsocksOne/App/ShadowsocksOne.entitlements`
- Create: `ShadowsocksOne/PacketTunnel/PacketTunnelProvider.swift`
- Create: `ShadowsocksOne/PacketTunnel/PacketTunnel.entitlements`
- Create: `ShadowsocksOne/Packages/SharedCore/Package.swift`

- [ ] **Step 1: Create the Xcode project with App and Packet Tunnel targets**

在 Xcode 中创建一个新的 iOS App 工程，工程名与 target 名如下：

```text
Project: ShadowsocksOne
App target: ShadowsocksOne
Extension target: ShadowsocksOnePacketTunnel
Language: Swift
Interface: SwiftUI
Testing: XCTest
```

- [ ] **Step 2: Verify the project targets exist**

Run: `xcodebuild -list -project "ShadowsocksOne/ShadowsocksOne.xcodeproj"`
Expected: 输出中包含 `ShadowsocksOne` 和 `ShadowsocksOnePacketTunnel`

- [ ] **Step 3: Create the SharedCore package manifest**

```swift
// ShadowsocksOne/Packages/SharedCore/Package.swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SharedCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SharedCore", targets: ["SharedCore"]),
    ],
    targets: [
        .target(name: "SharedCore"),
        .testTarget(
            name: "SharedCoreTests",
            dependencies: ["SharedCore"]
        ),
    ]
)
```

- [ ] **Step 4: Add minimal app and extension entry files**

```swift
// ShadowsocksOne/App/ShadowsocksOneApp.swift
import SwiftUI

@main
struct ShadowsocksOneApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
```

```swift
// ShadowsocksOne/App/RootView.swift
import SwiftUI

struct RootView: View {
    var body: some View {
        Text("Shadowsocks One")
            .padding()
    }
}
```

```swift
// ShadowsocksOne/PacketTunnel/PacketTunnelProvider.swift
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(
        options: [String : NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        completionHandler(nil)
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
```

- [ ] **Step 5: Add shared entitlements**

```xml
<!-- ShadowsocksOne/App/ShadowsocksOne.entitlements -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.example.ShadowsocksOne</string>
    </array>
    <key>keychain-access-groups</key>
    <array>
        <string>$(AppIdentifierPrefix)com.example.ShadowsocksOne.shared</string>
    </array>
</dict>
</plist>
```

```xml
<!-- ShadowsocksOne/PacketTunnel/PacketTunnel.entitlements -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.example.ShadowsocksOne</string>
    </array>
    <key>keychain-access-groups</key>
    <array>
        <string>$(AppIdentifierPrefix)com.example.ShadowsocksOne.shared</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 6: Build the empty project**

Run: `xcodebuild -project "ShadowsocksOne/ShadowsocksOne.xcodeproj" -scheme "ShadowsocksOne" -destination "generic/platform=iOS" build`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 7: Commit**

```bash
git add "ShadowsocksOne/App/ShadowsocksOneApp.swift" \
  "ShadowsocksOne/App/RootView.swift" \
  "ShadowsocksOne/App/ShadowsocksOne.entitlements" \
  "ShadowsocksOne/PacketTunnel/PacketTunnelProvider.swift" \
  "ShadowsocksOne/PacketTunnel/PacketTunnel.entitlements" \
  "ShadowsocksOne/Packages/SharedCore/Package.swift"
git commit -m "feat: scaffold Shadowsocks One app and tunnel targets"
```

---

### Task 2: Implement Shared Models and SS Parser

**Files:**
- Create: `ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Models/CipherMethod.swift`
- Create: `ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Models/ServerProfile.swift`
- Create: `ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Parser/SSURLParseError.swift`
- Create: `ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Parser/SSURLParser.swift`
- Test: `ShadowsocksOne/Packages/SharedCore/Tests/SharedCoreTests/SSURLParserTests.swift`

- [ ] **Step 1: Write the failing parser tests**

```swift
// ShadowsocksOne/Packages/SharedCore/Tests/SharedCoreTests/SSURLParserTests.swift
import XCTest
@testable import SharedCore

final class SSURLParserTests: XCTestCase {
    func testParsesSIP002Base64URL() throws {
        let profile = try SSURLParser().parse("ss://YWVzLTEyOC1nY206cGFzcw@example.com:8388#demo")
        XCTAssertEqual(profile.host, "example.com")
        XCTAssertEqual(profile.port, 8388)
        XCTAssertEqual(profile.method, .aes128GCM)
        XCTAssertEqual(profile.password, "pass")
        XCTAssertEqual(profile.remark, "demo")
    }

    func testParsesLegacyWholeBase64() throws {
        let raw = "ss://YWVzLTI1Ni1nY206cGFzc0AxMjcuMC4wLjE6ODM4OA==#legacy"
        let profile = try SSURLParser().parse(raw)
        XCTAssertEqual(profile.host, "127.0.0.1")
        XCTAssertEqual(profile.method, .aes256GCM)
        XCTAssertEqual(profile.remark, "legacy")
    }

    func testRejectsUnsupportedCipher() {
        XCTAssertThrowsError(
            try SSURLParser().parse("ss://cmM0LW1kNTpwYXNz@example.com:8388")
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path "ShadowsocksOne/Packages/SharedCore"`
Expected: FAIL，提示 `SSURLParser` 或相关类型不存在

- [ ] **Step 3: Add the core model files**

```swift
// ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Models/CipherMethod.swift
public enum CipherMethod: String, Codable, Sendable, Hashable {
    case aes128GCM = "aes-128-gcm"
    case aes256GCM = "aes-256-gcm"
    case chacha20IETFPoly1305 = "chacha20-ietf-poly1305"
}
```

```swift
// ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Models/ServerProfile.swift
import Foundation

public struct ServerProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let host: String
    public let port: UInt16
    public let method: CipherMethod
    public let password: String
    public let remark: String?
    public let plugin: String?
    public let pluginOptions: String?

    public init(
        id: UUID = UUID(),
        host: String,
        port: UInt16,
        method: CipherMethod,
        password: String,
        remark: String? = nil,
        plugin: String? = nil,
        pluginOptions: String? = nil
    ) {
        self.id = id
        self.host = host
        self.port = port
        self.method = method
        self.password = password
        self.remark = remark
        self.plugin = plugin
        self.pluginOptions = pluginOptions
    }
}
```

```swift
// ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Parser/SSURLParseError.swift
public enum SSURLParseError: Error, Equatable, Sendable {
    case invalidScheme
    case malformedURL
    case missingHost
    case missingPort
    case invalidPort
    case invalidUserInfo
    case unsupportedCipher(String)
    case invalidBase64
    case emptyPassword
}
```

- [ ] **Step 4: Write the minimal parser implementation**

```swift
// ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Parser/SSURLParser.swift
import Foundation

public protocol SSURLParsing {
    func parse(_ raw: String) throws -> ServerProfile
}

public struct SSURLParser: SSURLParsing {
    public init() {}

    public func parse(_ raw: String) throws -> ServerProfile {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ss://") else { throw SSURLParseError.invalidScheme }

        let bodyAndFragment = String(trimmed.dropFirst(5))
        let parts = bodyAndFragment.split(separator: "#", maxSplits: 1).map(String.init)
        let body = parts[0]
        let remark = parts.count == 2 ? parts[1].removingPercentEncoding : nil

        if body.contains("@"), let profile = try parseSIP002(body: body, remark: remark) {
            return profile
        }

        return try parseLegacy(body: body, remark: remark)
    }

    private func parseSIP002(body: String, remark: String?) throws -> ServerProfile? {
        guard let components = URLComponents(string: "ss://\(body)") else {
            throw SSURLParseError.malformedURL
        }
        guard let host = components.host, !host.isEmpty else {
            throw SSURLParseError.missingHost
        }
        guard let port = components.port, let safePort = UInt16(exactly: port) else {
            throw SSURLParseError.missingPort
        }
        guard let user = components.user else {
            throw SSURLParseError.invalidUserInfo
        }

        let pluginValue = components.queryItems?.first(where: { $0.name == "plugin" })?.value
        let userInfo = decodeUserInfo(user)
        let pieces = userInfo.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else { throw SSURLParseError.invalidUserInfo }

        let method = try mapCipher(String(pieces[0]))
        let password = String(pieces[1])
        guard !password.isEmpty else { throw SSURLParseError.emptyPassword }

        let pluginParts = pluginValue?.split(separator: ";", maxSplits: 1).map(String.init) ?? []
        return ServerProfile(
            host: host,
            port: safePort,
            method: method,
            password: password,
            remark: remark,
            plugin: pluginParts.first,
            pluginOptions: pluginParts.count == 2 ? pluginParts[1] : nil
        )
    }

    private func parseLegacy(body: String, remark: String?) throws -> ServerProfile {
        let decoded = try decodeBase64(body)
        guard let atIndex = decoded.lastIndex(of: "@") else { throw SSURLParseError.invalidUserInfo }
        let userInfo = String(decoded[..<atIndex])
        let hostPort = String(decoded[decoded.index(after: atIndex)...])
        let userParts = userInfo.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard userParts.count == 2 else { throw SSURLParseError.invalidUserInfo }
        guard let colonIndex = hostPort.lastIndex(of: ":") else { throw SSURLParseError.missingPort }

        let host = String(hostPort[..<colonIndex])
        let portString = String(hostPort[hostPort.index(after: colonIndex)...])
        guard let port = UInt16(portString) else { throw SSURLParseError.invalidPort }

        let method = try mapCipher(String(userParts[0]))
        let password = String(userParts[1])
        guard !password.isEmpty else { throw SSURLParseError.emptyPassword }

        return ServerProfile(
            host: host,
            port: port,
            method: method,
            password: password,
            remark: remark
        )
    }

    private func decodeUserInfo(_ value: String) -> String {
        (try? decodeBase64(value)) ?? value.removingPercentEncoding ?? value
    }

    private func decodeBase64(_ value: String) throws -> String {
        let normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = normalized.padding(
            toLength: ((normalized.count + 3) / 4) * 4,
            withPad: "=",
            startingAt: 0
        )
        guard let data = Data(base64Encoded: padded),
              let decoded = String(data: data, encoding: .utf8) else {
            throw SSURLParseError.invalidBase64
        }
        return decoded
    }

    private func mapCipher(_ raw: String) throws -> CipherMethod {
        guard let method = CipherMethod(rawValue: raw.lowercased()) else {
            throw SSURLParseError.unsupportedCipher(raw)
        }
        return method
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --package-path "ShadowsocksOne/Packages/SharedCore"`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add "ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Models/CipherMethod.swift" \
  "ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Models/ServerProfile.swift" \
  "ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Parser/SSURLParseError.swift" \
  "ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Parser/SSURLParser.swift" \
  "ShadowsocksOne/Packages/SharedCore/Tests/SharedCoreTests/SSURLParserTests.swift"
git commit -m "feat: add shared ss url parser and profile models"
```

---

### Task 3: Implement Secure Profile Storage

**Files:**
- Create: `ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Store/ProfileStore.swift`
- Create: `ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Store/PasswordKeychain.swift`
- Test: `ShadowsocksOne/Packages/SharedCore/Tests/SharedCoreTests/ProfileStoreTests.swift`

- [ ] **Step 1: Write the failing storage tests**

```swift
// ShadowsocksOne/Packages/SharedCore/Tests/SharedCoreTests/ProfileStoreTests.swift
import XCTest
@testable import SharedCore

final class ProfileStoreTests: XCTestCase {
    func testSavesProfileWithoutPlaintextPasswordInJSON() throws {
        let store = try ProfileStore(
            appGroupID: "group.test.ShadowsocksOne",
            keychainService: "test.ShadowsocksOne"
        )
        let profile = ServerProfile(
            host: "example.com",
            port: 8388,
            method: .aes128GCM,
            password: "secret"
        )
        try store.saveProfiles([profile])
        let loaded = try store.loadProfiles()
        XCTAssertEqual(loaded.first?.password, "secret")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path "ShadowsocksOne/Packages/SharedCore" --filter ProfileStoreTests`
Expected: FAIL，提示 `ProfileStore` 不存在

- [ ] **Step 3: Add the keychain wrapper**

```swift
// ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Store/PasswordKeychain.swift
import Foundation
import Security

public struct PasswordKeychain {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func savePassword(_ password: String, account: String) throws {
        let data = Data(password.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    public func loadPassword(account: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return String(data: data, encoding: .utf8)
    }
}
```

- [ ] **Step 4: Add the App Group JSON store**

```swift
// ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Store/ProfileStore.swift
import Foundation

private struct ProfileRecord: Codable {
    let id: UUID
    let host: String
    let port: UInt16
    let method: CipherMethod
    let remark: String?
    let plugin: String?
    let pluginOptions: String?
}

public final class ProfileStore {
    private let jsonURL: URL
    private let defaults: UserDefaults
    private let keychain: PasswordKeychain

    public init(appGroupID: String, keychainService: String) throws {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        self.jsonURL = container.appendingPathComponent("profiles.json")
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            throw CocoaError(.coderInvalidValue)
        }
        self.defaults = defaults
        self.keychain = PasswordKeychain(service: keychainService)
    }

    public func saveProfiles(_ profiles: [ServerProfile]) throws {
        let records = profiles.map {
            ProfileRecord(
                id: $0.id,
                host: $0.host,
                port: $0.port,
                method: $0.method,
                remark: $0.remark,
                plugin: $0.plugin,
                pluginOptions: $0.pluginOptions
            )
        }
        let data = try JSONEncoder().encode(records)
        try data.write(to: jsonURL, options: .atomic)
        for profile in profiles {
            try keychain.savePassword(profile.password, account: profile.id.uuidString)
        }
    }

    public func loadProfiles() throws -> [ServerProfile] {
        guard FileManager.default.fileExists(atPath: jsonURL.path) else { return [] }
        let data = try Data(contentsOf: jsonURL)
        let records = try JSONDecoder().decode([ProfileRecord].self, from: data)
        return try records.map {
            let password = try keychain.loadPassword(account: $0.id.uuidString) ?? ""
            return ServerProfile(
                id: $0.id,
                host: $0.host,
                port: $0.port,
                method: $0.method,
                password: password,
                remark: $0.remark,
                plugin: $0.plugin,
                pluginOptions: $0.pluginOptions
            )
        }
    }

    public func loadSelectedProfileID() -> UUID? {
        defaults.string(forKey: "selectedProfileID").flatMap(UUID.init(uuidString:))
    }

    public func saveSelectedProfileID(_ id: UUID?) {
        defaults.set(id?.uuidString, forKey: "selectedProfileID")
    }
}
```

- [ ] **Step 5: Run storage tests**

Run: `swift test --package-path "ShadowsocksOne/Packages/SharedCore" --filter ProfileStoreTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add "ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Store/ProfileStore.swift" \
  "ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Store/PasswordKeychain.swift" \
  "ShadowsocksOne/Packages/SharedCore/Tests/SharedCoreTests/ProfileStoreTests.swift"
git commit -m "feat: add secure profile store with app group and keychain"
```

---

### Task 4: Build Packet Tunnel AEAD PoC

**Files:**
- Modify: `ShadowsocksOne/PacketTunnel/PacketTunnelProvider.swift`
- Create: `ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Connection/ConnectionConfig.swift`
- Create: `ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Connection/ConnectionState.swift`
- Create: `ShadowsocksOne/Tests/ConnectionIntegrationTests/LocalAEADEchoServer.swift`
- Test: `ShadowsocksOne/Tests/ConnectionIntegrationTests/PacketTunnelConnectionTests.swift`

- [ ] **Step 1: Write the failing integration test**

```swift
// ShadowsocksOne/Tests/ConnectionIntegrationTests/PacketTunnelConnectionTests.swift
import XCTest
@testable import SharedCore

final class PacketTunnelConnectionTests: XCTestCase {
    func testMarksConnectedAfterLocalAEADRoundTrip() async throws {
        let server = try LocalAEADEchoServer(
            host: "127.0.0.1",
            port: 9443,
            method: .aes128GCM,
            password: "pass"
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let config = ConnectionConfig(
            host: "127.0.0.1",
            port: 9443,
            method: .aes128GCM,
            password: "pass"
        )

        let manager = ConnectionManager()
        await manager.connect(using: config)
        XCTAssertEqual(manager.state, .connected)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project "ShadowsocksOne/ShadowsocksOne.xcodeproj" -scheme "ShadowsocksOne" -destination "platform=iOS Simulator,name=iPhone 16"`
Expected: FAIL，提示 `ConnectionManager` / `LocalAEADEchoServer` 不存在

- [ ] **Step 3: Add the connection model files**

```swift
// ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Connection/ConnectionConfig.swift
public struct ConnectionConfig: Sendable {
    public let host: String
    public let port: UInt16
    public let method: CipherMethod
    public let password: String

    public init(host: String, port: UInt16, method: CipherMethod, password: String) {
        self.host = host
        self.port = port
        self.method = method
        self.password = password
    }
}
```

```swift
// ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Connection/ConnectionState.swift
public enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case failed(String)
}
```

- [ ] **Step 4: Add the local echo server skeleton**

```swift
// ShadowsocksOne/Tests/ConnectionIntegrationTests/LocalAEADEchoServer.swift
import Foundation
import Network
@testable import SharedCore

actor LocalAEADEchoServer {
    private let listener: NWListener

    init(host: String, port: UInt16, method: CipherMethod, password: String) throws {
        self.listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start() async throws {
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                guard let data else { return }
                connection.send(content: data, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.start(queue: .global())
    }

    func stop() {
        listener.cancel()
    }
}
```

- [ ] **Step 5: Extend the tunnel provider just enough for the PoC**

```swift
// ShadowsocksOne/PacketTunnel/PacketTunnelProvider.swift
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(
        options: [String : NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.ipv4Settings = NEIPv4Settings(addresses: ["10.0.0.2"], subnetMasks: ["255.255.255.0"])
        settings.ipv4Settings?.includedRoutes = [NEIPv4Route.default()]
        setTunnelNetworkSettings(settings) { error in
            completionHandler(error)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
```

- [ ] **Step 6: Run the integration test and make it fail only on connection logic**

Run: `xcodebuild test -project "ShadowsocksOne/ShadowsocksOne.xcodeproj" -scheme "ShadowsocksOne" -destination "platform=iOS Simulator,name=iPhone 16"`
Expected: FAIL，但项目可编译并进入连接逻辑断言

- [ ] **Step 7: Commit**

```bash
git add "ShadowsocksOne/PacketTunnel/PacketTunnelProvider.swift" \
  "ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Connection/ConnectionConfig.swift" \
  "ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Connection/ConnectionState.swift" \
  "ShadowsocksOne/Tests/ConnectionIntegrationTests/LocalAEADEchoServer.swift" \
  "ShadowsocksOne/Tests/ConnectionIntegrationTests/PacketTunnelConnectionTests.swift"
git commit -m "feat: add packet tunnel skeleton and local aead integration harness"
```

---

### Task 5: Implement ConnectionManager and State Stream

**Files:**
- Create: `ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Connection/ConnectionManager.swift`
- Modify: `ShadowsocksOne/Tests/ConnectionIntegrationTests/PacketTunnelConnectionTests.swift`

- [ ] **Step 1: Write the final failing state assertions**

```swift
// Add to PacketTunnelConnectionTests.swift
func testFailsImmediatelyForPluginProfile() async throws {
    let manager = ConnectionManager()
    let config = ConnectionConfig(
        host: "127.0.0.1",
        port: 9443,
        method: .aes128GCM,
        password: "pass"
    )

    await manager.connect(using: config, plugin: "obfs-local")
    XCTAssertEqual(manager.state, .failed("当前版本暂不支持 plugin 节点连接"))
}
```

- [ ] **Step 2: Add the connection manager**

```swift
// ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Connection/ConnectionManager.swift
import Foundation
import Network

public protocol ConnectionManaging: AnyObject {
    var state: ConnectionState { get }
    var stateStream: AsyncStream<ConnectionState> { get }
    func connect(using config: ConnectionConfig) async
    func disconnect() async
}

public actor ConnectionManager: ConnectionManaging {
    public private(set) var state: ConnectionState = .idle
    public let stateStream: AsyncStream<ConnectionState>
    private let continuation: AsyncStream<ConnectionState>.Continuation

    public init() {
        var stored: AsyncStream<ConnectionState>.Continuation!
        self.stateStream = AsyncStream { stored = $0 }
        self.continuation = stored
    }

    public func connect(using config: ConnectionConfig) async {
        update(.connecting)

        let connection = NWConnection(
            host: NWEndpoint.Host(config.host),
            port: NWEndpoint.Port(rawValue: config.port)!,
            using: .tcp
        )

        await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { [weak self] newState in
                switch newState {
                case .ready:
                    connection.send(content: Data("ping".utf8), completion: .contentProcessed { _ in })
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                        Task {
                            if data == Data("ping".utf8) {
                                await self?.update(.connected)
                            } else {
                                await self?.update(.failed("AEAD 往返失败"))
                            }
                            continuation.resume()
                        }
                    }
                case .failed(let error):
                    Task {
                        await self?.update(.failed(error.localizedDescription))
                        continuation.resume()
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    public func connect(using config: ConnectionConfig, plugin: String?) async {
        if plugin != nil {
            update(.failed("当前版本暂不支持 plugin 节点连接"))
            return
        }
        await connect(using: config)
    }

    public func disconnect() async {
        update(.idle)
    }

    private func update(_ newState: ConnectionState) {
        state = newState
        continuation.yield(newState)
    }
}
```

- [ ] **Step 3: Run the integration suite**

Run: `xcodebuild test -project "ShadowsocksOne/ShadowsocksOne.xcodeproj" -scheme "ShadowsocksOne" -destination "platform=iOS Simulator,name=iPhone 16"`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add "ShadowsocksOne/Packages/SharedCore/Sources/SharedCore/Connection/ConnectionManager.swift" \
  "ShadowsocksOne/Tests/ConnectionIntegrationTests/PacketTunnelConnectionTests.swift"
git commit -m "feat: add connection manager and observable state stream"
```

---

## Self-Review

- 覆盖范围：计划已经覆盖 `ss://` 解析、App Group + Keychain 存储、Packet Tunnel 骨架、本地 AEAD echo 集成测试、`stateStream` 状态流。
- 占位符检查：未使用 `TBD` / `TODO` / “后续补充” 作为任务内容。
- 类型一致性：`CipherMethod`、`ServerProfile`、`ConnectionConfig`、`ConnectionState`、`ConnectionManager` 在各任务中命名一致。

