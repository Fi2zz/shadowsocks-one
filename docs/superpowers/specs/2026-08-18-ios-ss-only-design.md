# iOS SS Only Design

**目标**

构建一个全新的 iOS 客户端最小内核，满足以下闭环：
- 输入 `ss://`
- 解析为结构化节点
- 本地保存节点
- 选择当前节点
- 基于当前节点发起连接

UI 不在本设计范围内，后续单独实现。

---

## 1. 范围

### 1.1 本期包含

- 纯 Swift 实现
- 仅支持 `ss://`
- 仅支持 AEAD 算法：
  - `aes-128-gcm`
  - `aes-256-gcm`
  - `chacha20-ietf-poly1305`
- 支持标准 SIP002 URI
- 支持 legacy 兼容解析（见 §5.3 明确定义）
- 支持 `fragment` 备注
- 支持 `plugin` 字段解析与保存
- 支持节点本地持久化
- 支持最小连接状态管理

### 1.2 本期不包含

- PAC
- HTTP Proxy / Privoxy
- 二维码扫描与分享
- 订阅
- `ssr://`
- AEAD-2022
- 桌面端 helper / LaunchAgent / shell 脚本
- plugin 节点的实际连接（仅解析保存，见 §7.5）
- 桌面端迁移兼容层

---

## 2. 设计原则

### 2.1 纯 Swift

业务代码仅使用 Swift 实现，优先使用：
- `Foundation`
- `CryptoKit`
- `Network`
- `NetworkExtension`

不依赖：
- Objective-C 桥接实现
- CocoaPods 旧链路
- 外部二进制子进程拉起方案

### 2.2 小而清晰

每个模块只做一件事：
- Parser 只负责解析
- Model 只负责表达数据
- Store 只负责持久化
- Connection 只负责连接

### 2.3 解析尽量兼容，连接尽量保守

输入层尽量兼容常见 `ss://` 格式。  
连接层只放行第一版真正支持的 AEAD 算法，避免“解析成功但实现并不支持”的假能力。

---

## 3. 总体架构

### 3.1 iOS 进程模型（先决条件）

iOS 上做系统级代理必须走 `NEPacketTunnelProvider`，它是一个**独立的 App Extension 进程**。因此工程固定拆为：

1. `SharedCore`（Swift Package，被下面两个 target 共同引用）
   - `CipherMethod`
   - `ServerProfile`
   - `SSURLParser`
   - `ProfileStore`
   - `ConnectionConfig`

2. `App target`
   - 管理界面与节点数据
   - 通过 `NETunnelProviderManager` 启动/停止隧道、观察状态

3. `Packet Tunnel Extension target`
   - 真正运行 Shadowsocks AEAD 协议栈
   - 从共享存储读取当前节点配置

跨进程约束：
- 节点数据必须写入 **App Group 共享容器**，普通 `UserDefaults.standard` 对 Extension 不可见。
- 密码放入 **Keychain**，并配置与 App Group 对应的 Keychain Access Group，供两个进程读取。

数据流如下：

`ss:// raw string`  
-> `SSURLParser`  
-> `ServerProfile`  
-> `ProfileStore`（App Group）  
-> `ConnectionConfig`  
-> `ConnectionManager`（App 侧控制 + Extension 侧执行）

### 3.2 分层

1. `Shared Core`：模型、解析、持久化，不依赖 UI 与 NetworkExtension。
2. `Connection Layer`：协议栈与最小状态流转。
3. `UI Layer`：不在本设计范围内，后续只消费 `ProfileStore` 与 `ConnectionManager`。

---

## 4. 核心模型

### 4.1 CipherMethod

```swift
enum CipherMethod: String, Codable, Sendable {
    case aes128GCM = "aes-128-gcm"
    case aes256GCM = "aes-256-gcm"
    case chacha20IETFPoly1305 = "chacha20-ietf-poly1305"
}
```

职责：
- 约束第一版支持算法范围
- 避免业务层到处传播原始字符串

### 4.2 ServerProfile

```swift
struct ServerProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let host: String
    let port: UInt16
    let method: CipherMethod
    let password: String
    let remark: String?
    let plugin: String?
    let pluginOptions: String?
}
```

职责：
- 表达用户保存的节点
- 不包含 UI 状态
- 不包含运行期连接状态

说明：`password` 字段在持久化时不随 JSON 落盘，由 `ProfileStore` 转存 Keychain（见 §6.2）。

### 4.3 ConnectionConfig

```swift
struct ConnectionConfig: Sendable {
    let host: String
    let port: UInt16
    let method: CipherMethod
    let password: String
}
```

职责：
- 作为连接层输入模型
- 将持久化模型与运行期模型解耦

---

## 5. Parser 设计

### 5.1 对外接口

```swift
enum SSURLParseError: Error, Equatable, Sendable {
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

protocol SSURLParsing {
    func parse(_ raw: String) throws -> ServerProfile
}
```

### 5.2 解析流程

解析固定按以下顺序执行：

1. 预处理字符串
   - 去除首尾空白
   - 校验 scheme 必须为 `ss://`

2. 判定输入形态（二选一）
   - **SIP002 形态**：`ss://userinfo@host:port?plugin=...#remark`，走 `URLComponents`
   - **legacy 整段 Base64 形态**：`ss://base64(method:password@host:port)#remark`，
     即 `ss://` 之后、`#` 之前整体是一段 Base64，解码后再按 `method:password@host:port` 拆分。
     存量二维码与分享链接大量使用此格式，第一版必须支持。

3. Base64 解码规则（两种形态共用）
   - 同时接受标准 Base64（`+` `/`）与 Base64URL（`-` `_`）
   - 容忍缺失的 padding（解码前自动补齐 `=`）

4. `userinfo` 解析（SIP002 形态）
   - 先尝试按 Base64 解码（规则同上）
   - 解码失败后按明文 `method:password` 尝试
   - 两者都失败则抛 `invalidUserInfo`
   - 明文形式需注意密码可能含 `@`、`:`、`/` 等字符，按**最后一个 `@`** 分割 host，
     按**第一个 `:`** 分割 method 与 password

5. 算法映射
   - method 转小写
   - 非 AEAD 白名单算法直接抛 `unsupportedCipher`

6. 可选字段解析
   - `fragment` -> `remark`
   - `plugin` query -> 拆成 `plugin` 与 `pluginOptions`

7. 产出 `ServerProfile`
   - 生成新的 `UUID`
   - 返回完整对象

### 5.3 支持格式

第一版支持以下几类输入：

- SIP002：Base64 userinfo（标准 Base64 与 Base64URL，可缺 padding）
- SIP002：明文 `method:password` userinfo（含特殊字符密码）
- legacy 整段 Base64：`ss://base64(method:password@host:port)#remark`
- `#remark`
- `?plugin=...`
- IPv4
- 域名
- IPv6

### 5.4 不支持格式

- `ss:.//`
- 非 `ss://` scheme
- 缺失 host 或 port
- 非法 Base64
- 不支持的 cipher
- 空 password
- AEAD-2022
- `ssr://`

---

## 6. Store 设计

### 6.1 对外接口

```swift
protocol ProfileStoring {
    func loadProfiles() throws -> [ServerProfile]
    func saveProfiles(_ profiles: [ServerProfile]) throws
    func loadSelectedProfileID() throws -> UUID?
    func saveSelectedProfileID(_ id: UUID?) throws
}
```

### 6.2 设计约束

- 节点列表以 JSON 文件形式写入 **App Group 共享容器**（App 与 Extension 都要读）。
- 选中节点 ID 写入 App Group 的 `UserDefaults(suiteName:)`。
- 密码不写入 JSON，按 profile `id` 存入 **Keychain**（共享 Access Group），
  `loadProfiles` 时回填。这是硬性要求，不接受明文落盘。
- 不做迁移逻辑。
- 不做复杂并发同步（第一版约定只有 App 侧写、Extension 侧读）。

### 6.3 成功标准

- 节点可保存
- 节点可恢复（含密码）
- 当前选中节点可保存
- 重启后能恢复选中节点
- Extension 进程能读到同一份数据

---

## 7. Connection 设计

### 7.1 最小状态机

```swift
enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case failed(String)
}
```

### 7.2 对外接口

```swift
protocol ConnectionManaging: AnyObject {
    var state: ConnectionState { get }
    var stateStream: AsyncStream<ConnectionState> { get }
    func connect(using config: ConnectionConfig) async
    func disconnect() async
}
```

约定：
- 状态变化必须通过 `stateStream` 推送，UI 层据此观察；只读 `state` 属性不足以满足验收。
- `connect(using:)` 不抛错是有意设计：所有失败统一走 `.failed(String)`，调用方只订阅状态。
- App 侧实现包装 `NETunnelProviderManager`；Extension 侧协议栈的状态经 `NEPacketTunnelProvider`
  的 IPC / 状态映射回这套状态机。

### 7.3 connected 的判定标准

`connected` 有明确定义，不是“隧道启动了”：

- 本地完成一次 AEAD 数据往返：协议栈对内置自检目标（或本地回显）完成
  salt 交换 + 加密发送 + 解密接收且 AEAD 校验通过。

烟雾测试不依赖外部真实服务器：测试进程本地起一个回显端
（自写的 SS AEAD echo server 或 shadowsocks-libev 的 `ss-server`），保证可重复、可在 CI 运行。

### 7.4 密钥派生说明

SS AEAD 的密钥派生为 EVP_BytesToKey(MD5) 生成 master key，再用 HKDF-SHA1 按 salt 派生子密钥。
CryptoKit 中 MD5 / SHA1 位于 `Insecure` 命名空间（`Insecure.MD5`、`HMAC<Insecure.SHA1>`），
纯 Swift 路线可行，无需引入第三方加密库。

### 7.5 plugin 节点的连接行为

第一版连接层不实现任何 plugin。带 `plugin` 的节点发起连接时，必须立即进入
`.failed("当前版本暂不支持 plugin 节点连接")`，不允许静默忽略 plugin 字段直接裸连。

### 7.6 连接层边界

第一版连接层职责：
- 接收 `ConnectionConfig`
- 完成最小 Shadowsocks AEAD 连接
- 管理连接生命周期
- 对外暴露状态

第一版连接层不负责：
- 订阅
- 复杂规则路由
- 多协议
- 插件进程管理
- 大规模兼容矩阵

### 7.7 cipher 范围

第一版只实现：
- `aes-128-gcm`
- `aes-256-gcm`
- `chacha20-ietf-poly1305`

不实现：
- `cfb`
- `ctr`
- `rc4-md5`
- `camellia-*`
- `xchacha20-ietf-poly1305`
- AEAD-2022

---

## 8. 测试策略

### 8.1 Parser 单元测试

必须覆盖：
- SIP002 合法 Base64 userinfo（标准 Base64 / Base64URL / 缺 padding）
- SIP002 合法明文 userinfo
- 明文密码含 `@` `:` `/` 特殊字符
- legacy 整段 Base64 格式
- remark
- plugin
- IPv4 / 域名 / IPv6
- 非法 scheme
- 缺失 host / port
- 非法 Base64
- 不支持算法
- 空 password

### 8.2 Store 测试

覆盖：
- `ServerProfile` 编解码正确
- 节点保存与读取正确（含 Keychain 密码往返）
- 选中节点保存与读取正确
- 使用 App Group 容器读写（测试环境用独立 suite / keychain access group 隔离）

### 8.3 连接集成测试

不依赖外部固定节点，本地起回显端，验证：
- 基于本地 echo server 发起连接，按 §7.3 判定进入 `connected`
- 服务端不可达 / 密码错误时进入 `failed`
- 断开后进入 `idle`
- 带 plugin 的节点连接时立即进入 `.failed`（§7.5）

---

## 9. 文件拆分

建议的实现文件结构（SharedCore Swift Package）：

- `Core/Models/CipherMethod.swift`
- `Core/Models/ServerProfile.swift`
- `Core/Parser/SSURLParser.swift`
- `Core/Parser/SSURLParseError.swift`
- `Core/Store/ProfileStore.swift`
- `Core/Store/PasswordKeychain.swift`
- `Core/Connection/ConnectionConfig.swift`
- `Core/Connection/ConnectionState.swift`
- `Core/Connection/ConnectionManager.swift`

工程 target：
- `App/`（主 App，后续含 UI）
- `PacketTunnel/`（Network Extension）

测试文件：

- `Tests/Parser/SSURLParserTests.swift`
- `Tests/Store/ProfileStoreTests.swift`
- `Tests/Connection/ConnectionIntegrationTests.swift`

---

## 10. 最小落地顺序

连接层是本项目最大风险点，采用双轨推进：

轨道 A（数据链路，可直接开工）：
1. `CipherMethod`
2. `ServerProfile`
3. `SSURLParseError`
4. `SSURLParser`
5. Parser 单元测试
6. `ProfileStore` + Keychain
7. Store 测试

轨道 B（连接验证，与轨道 A 并行尽早启动）：
1. 搭建 App + Packet Tunnel Extension 骨架，跑通 Extension 启动与共享存储读取
2. 纯 Swift AEAD 协议栈（KDF → salt → 加解密）
3. 本地 echo server 集成测试打通

汇合：
1. `ConnectionConfig`
2. `ConnectionManager`（App 侧状态包装）
3. 连接集成测试全绿
4. 最后接 UI

这样可以保证：
- 数据链路完全不依赖 UI 与连接实现细节
- 连接层风险最早暴露，不阻塞 Parser / Store
- 连接层若后续调整，Parser 和 Store 基本不返工

---

## 11. 验收标准

本阶段完成的标准是：

1. 输入合法 `ss://`（SIP002 与 legacy 整段 Base64）可正确解析出节点
2. 非法输入可返回明确错误
3. 节点（含密码）可保存并在重启后恢复
4. 当前节点可被选中并恢复，且 Extension 进程可读到
5. 基于本地回显端可完成一次符合 §7.3 判定的成功连接
6. 连接中、成功、失败三种状态可通过 `stateStream` 被外部观察与断言

---

## 12. 结论

第一版方案正式锁定为：

- 纯 Swift
- 仅支持 `ss://`
- 仅支持 AEAD
- App + Packet Tunnel Extension 双进程，SharedCore 经 App Group / Keychain 共享
- UI 后置，连接层 PoC 与数据链路并行
- parser / store / connection 分层清晰

这是当前范围下最小、最稳、最容易形成闭环的实现方案。
