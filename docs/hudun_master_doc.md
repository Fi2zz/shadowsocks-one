# 护盾 VPN —— 协议逆向 · iOS 集成 · 测试 完整文档

> 版本基准：com.speed.bilin v4.4.0 (19) · 文档日期：2026-08-24
> 本文为**唯一权威整合版**，合并并取代 guide / reference / ios_integration 三份旧文档的内容；
> 过程性取证记录仍保留于各 handoff 文件。配套代码：`HudunAPI.swift`（iOS 库）、`hudun_api.py`（桌面对照客户端）。

---

# 第 1 章 概述

| 项目 | 内容 |
|---|---|
| 目标应用 | 「护盾」付费 VPN，Flutter 工程 `xiyou_flutter_rebuild` |
| 协议本质 | 标准 WireGuard（UDP Noise IK），握手层无定制扩展；HTTP 层自定义签名+加密 |
| 业务栈 | Dart AOT(libapp.so) 签名/加密 → Java 壳(VpnService) → Go(libgojni: wireguard-go/xray) |
| 入口 | EdgeOne 轮换域名（公网 NXDOMAIN，IP 由 DNS TXT 钉住）+ CloudFront 兜底 |

三层动态性（贯穿全文的核心认知）：
1. **主机层轮换**：TXT 引导下发域名/IP 映射 → 会话应跑 bootstrap
2. **节点层漂移**：同 line_id 每次分配不同 endpoint → 凭证现取现用
3. **数据层快照**：线路列表是实时状态 → 不长期缓存

---

# 第 2 章 鉴权模型

## 2.1 sign 签名算法

```
merged = 业务参数(GET=query / POST=form body) ∪ {ts: 当前unix秒}
raw    = 按 key 字典序排序后拼接 "k=v"（键值间无分隔符；ts 参与排序但不进 URL/body）
sign   = md5_hex( utf8(raw + "WOYqZGTomCWAFREVnyxiyou") )
```

反编译锚点：`AppUtils::generateSign` @libapp.so+0x72a47c、`HeaderInterceptor::onRequest` @0x884e40。
POST body 为 Map 时并入签名输入；FormData 不并入。

⚠️ 特例：`/user/login` 的 `type` 参数不在服务端签名重建范围内——请求带 type 且签入即 4026。
**实现约定：登录请求不发 type。**

## 2.2 请求头矩阵（46 次消融实验结论）

| 级别 | 头 | 备注 |
|---|---|---|
| 强校验 | `ts` `sign` `deviceid` `authorization` `publickey` | deviceid 删→HTTP403 / 错→4003；publickey 删→HTTP403，值=本端X25519公钥hex（响应加密用，不绑账号） |
| 忽略 | 其余 17 个 | uid/appversion/versioncode/bundleid/platform/language/language-platform/channel/xray-support/appproxy/istv/spreadnum/push-id/devicename/last_notice_id/last_feedback_id/ua/user-agent |

补充规则：
- POST 必须 `Content-Type: application/x-www-form-urlencoded`（空 body 也要）
- 无防重放；正确签名下 ts 偏移 ±24h 均通过
- sign 与 ts 不一致：小偏移(~60s)→4026；大偏移(≥~5min)→1134

## 2.3 响应解密

```
body   = base64( iv[16] ‖ ciphertext )
shared = X25519_raw(本端私钥, REMOTE_PUBKEY)        # 裸 scalarmult，无 KDF
aesKey = SHA256(shared)
plain  = AES-256-CBC-decrypt(ciphertext, aesKey, iv)，去 PKCS7
明文   = {"code": int, "msg": str, "data": {...}}
```

REMOTE_PUBKEY 当前值：
`b3a0a0b31f7acd579d6e5882b1b1be1e48acefa90ffc2a9b6ecde398af49e924`
（libapp.so 偏移 503417；轮换窗口经 TXT publickey 字段热更新）

## 2.4 业务码

| code | 含义 | 处理 |
|---|---|---|
| 200 | 成功 | — |
| 4002 | 账号或密码错误 | 提示用户 |
| 4003 | 登录失效 | token/deviceid 失配 → 重登刷凭证 |
| 4026 | 签名验证失败 | 排查算法/ts 一致性/body 漏签 |
| 1131 | 帐号已经到期 | 无 VIP，引导充值 |
| 1134 | 设备当前时间有误 | 校时 |

---

# 第 3 章 全链路协议

## 3.1 冷启动（免登录）

```
DNS TXT newxyqt.xyapiali.com
  → base64 → AES-128-CBC(key=iv="wriQVbeJqBWC2qJ0") → JSON:
  {domains:{android,ios,pc,all:[url]}, ips:{enabled,mappings:[{ip,host,supports}]}, [publickey]}
容灾链：GitHub 种子(内置PAT,已404) → DoH(223.5.5.5/doh.pub/...)
Splash 并行 GET：/common/bootpage · config_info · version · version_switch
```

## 3.2 登录 → 选线 → 连接

```
POST /user/login {username,password 明文}     ← data.token(JWT≈10年) + user{uid}
GET  /user/user_info · POST /user/check_in · GET /notice/info
GET  /route_list（无参实时快照）              ← {vip:[6], svip:[7]}，ip 列多为占位
GET  /user/route_info?id&public_key&is_full_route=true
       ← WG 凭证包：their_public_key/endpoint/allow_ip/sign(JWT 72h)/dnss/mtu/mask
MethodChannel connect → checkSafe(证书hashCode==1328217727)
       → VpnService(:speed) tun0(fd) → Tunlib.start(fd,json)
       → wireguard-go 握手 endpoint → 数据面
       → 智能分流 CIDR 写入路由（chn/nochn 规则，~888/910 条）
       → POST /api/app/common/report/endpoint 上报连通（无 v3 前缀）
```

### connect 参数包实录（logcat 样本，字段→来源）

| 字段 | 值示例 | 来源 |
|---|---|---|
| action | wireguard | 协议选择 |
| ip | 113.45.52.155:19921 | route_info.ip（动态） |
| their_public_key | VPujWFTjDpr9NzCAPvzXuGaEe79vRlsoFBgvQMx15zw= | route_info（全线路同一对端） |
| allow_ip / mask | 22.105.98.191 / 32 | route_info |
| dnss / mtu | [22.0.0.2] / 1300 | route_info |
| included_routes | [22.0.0.2/32] | 固定：先只导隧道 DNS |
| sign | JWT{key,allow_ip,exp,iss:wireguard} | route_info，72h |
| use_network_lock / route_switch_state / tun_mode / proxy_type / handshake_max_time | 1 / 1 / true / 2 / 600 | 配置与常量 |

**关键实证**：握手层不校验 sign JWT——官方 wireguard-go 仅凭私钥+对端公钥+endpoint 即完成握手与数据面。

---

# 第 4 章 端点参考（38 个，blutter 提取 + 实测标注）

标注：✅实测 · 📄反编译确认。路径前缀 `/api/app/v3`（例外注明）。

## 用户/登录
| 方法 | 路径 | 参数/说明 |
|---|---|---|
| ✅POST | `/user/login` | `{username,password}` 明文；⚠️勿带 type；data={token,user} |
| ✅GET | `/user/user_info` | 档案：uid/phone/expire_time/vip_expire_time/use_device_num/online_device_num... |
| 📄GET | `/user/check_in` | 签到记录列表 |
| ✅POST | `/user/check_in` | 签到动作（空 body） |
| 📄POST | `/user/register` | `{username,password,captcha}` |
| 📄PATCH | `/user/update_password` | `{old_password,new_password}` |
| 📄PATCH | `/user/retrieve_password` | `{username,password,captcha}` |
| 📄POST | `/user/bind_phone` | `{username,password,captcha}` |
| 📄POST | `/user/username/update` | `{username,captcha}` |
| 📄DELETE | `/user/account` | 注销 |
| 📄POST | `/user/qr_info` | 扫码登录 `{unique_code,operate,qr_type}` |
| ✅POST | `/common/captcha` | `{username,type}` → data.captcha |

## 线路/VPN
| 方法 | 路径 | 参数/说明 |
|---|---|---|
| ✅GET | `/route_list` | 无参；{vip:[],svip:[]}，项含 id/type_name/name/ip(占位)/vip_state/is_block |
| ✅GET | `/user/route_info` | `{id, public_key(b64), is_full_route}` → WG 凭证包；VIP过期返 1131 |
| ✅GET | `/common/route_allot` | 无参 → chn/nochn 规则 URL（COS 公开 CIDR 文本 ~888/~910 条） |

## 全局配置（免登录可调）
📄GET `/common/bootpage` · `/common/config_info`✅ · `/common/version?type=` ·
`/common/version_switch` · `/common/marquee_info` · `/common/broadcast/last` ·
✅`/notice/info` · `/question/info` · `/common/feedback/last` · `/reply`

## 反馈/上报/上传
📄POST `/common/feedback` `{username,desc,img_url,endpoint,log,type}` ·
📄POST `/common/upload`(multipart file) ·
📄POST `/report/domain` `{uid,device_id,domains}` ·
📄POST `/api/app/common/report/endpoint`（无 v3，native 直发）

## 订单/支付
📄POST `/order/buy` `{id,pay_type,ticket_id}` · POST `/order/pay` `{order_id,payment}` ·
GET `/order/coupon_pay?id=` · POST `/order/key` `{key}` ·
GET `/order/info` · `/order/postage_info` · `/pay_method/list` ·
GET `/user/gift/info` · `/user/coupon_info`

---

# 第 5 章 iOS 集成

## 5.1 文件与要求

| 项 | 说明 |
|---|---|
| 进项目 | 仅 `HudunAPI.swift`（44KB 单文件） |
| 依赖 | 零第三方；CryptoKit/CommonCrypto/Network 系统框架 |
| 系统 | iOS 15+（async/await） |
| 权限 | 普通网络即可；无需 Info.plist/ATS/entitlements 改动 |
| ❌排除 | `hudun_cli.swift`（macOS 测试壳）及一切非 Swift 资产 |

## 5.2 快速开始

```swift
var cfg = HudunConfig.standard(
    credentials: HudunCredsStore.load() ?? HudunCredentials(token:"",deviceid:"",uid:""))
let client = HudunClient(config: cfg)          // init 零网络

await client.bootstrap()                        // 可选；request 失败也会自动补跑
let creds = try await client.login(account:u, password:p)   // 明文；成功自动应用
try HudunCredsStore.save(creds)

let lines = try await client.lines()
let wg = try await client.renew(lineId: lines[0].id)        // wg.confString → 隧道层
```

## 5.3 API 参考（实际签名）

```swift
final class HudunClient {
    init(config: HudunConfig)
    func bootstrap(platformKey: String = "ios") async -> HudunBootstrapResult?
    func bootstrapVia(resolver: String, platformKey: String = "ios") async throws -> HudunBootstrapResult
    func applyBootstrap(_ dict: [String: Any], platformKey: String = "ios") -> HudunBootstrapResult
    func login(account: String, password: String) async throws -> HudunCredentials
    func postLoginSync() async -> (user:[String:Any]?, checkIn:[String:Any]?, notice:[String:Any]?)
    func sendSmsCode(phone: String) async throws -> Bool
    func lines() async throws -> [HudunLine]
    func routeAllot() async throws -> HudunRouteAllot
    func downloadCIDRList(_ urlString: String) async throws -> [String]
    func renew(lineId: Int, fullRoute: Bool = true) async throws -> HudunWGConfig
    func userInfo() async throws -> [String: Any]
    @discardableResult
    func request(_ method: String, _ path: String,
                 _ params: [String: String] = [:],
                 extraHeaders: [String: String] = [:]) async throws -> [String: Any]
}
```

配置可覆盖项（`.standard()` 出厂后均可改）：`signSalt / remotePublicKeyHex /
bootstrapTXTHost / bootstrapKey / resolvers / staticEndpoints / appVersionName /
appVersionCode / bundleId / credentials / deviceProfile`。
`deviceProfile` 默认自动取真机（UIDevice/uname），逐项可覆写。

结果类型要点：
- `HudunWGConfig`：`privateKeyB64/address/dns/endpoint/peerPublicKey/mtu/expiresAt/confString`
- `HudunLine`：`id/name/typeName/groupName/flagName/ip/imageURL/vipState/isBlocked/tier`

错误模型 `HudunError`：
`sessionExpired(4003)` · `wrongCredentials(4002)` · `signatureRejected(4026)` ·
`deviceTimeSkew(1134)` · `vipExpired(1131)` · `http/badResponse/transport`
业务错误不切换端点；网络错误自动 failover，全部失败自动 bootstrap 一次再试。

## 5.4 凭证管理

```
启动: CredsStore.load() → 空 token 则走 login；否则 userInfo() 静默验证
失效: catch .sessionExpired → 登录页 → login → save
存储: HudunCredsStore(Application Support + completeFileProtection)；
      生产建议换 Keychain（替换 save/load 两行）
deviceid 对应做法: identifierForVendor 双拼 或 Keychain 持久 UUID×2，
      语义=安装后稳定且与 token 配对
```

## 5.5 WireGuard 隧道对接

conf 字段映射：PrivateKey←privateKeyB64 · Address←address/32 · DNS←dns · MTU←mtu ·
PublicKey←peerPublicKey · Endpoint←endpoint · AllowedIPs=0.0.0.0/0（全局模式）

智能分流（还原原 App）：
```swift
let allot = try await client.routeAllot()
let chn = try await client.downloadCIDRList(allot.chn.url)   // 国内段 CIDR
// NEPacketTunnelProvider: tun 只路由 chn 段 + 隧道 DNS，其余直连
```
到期（expiresAt≈72h）/节点漂移 → 重调 renew，禁止持久化旧 conf。
可选还原上报：`request("POST","/api/app/common/report/endpoint",...)`。

## 5.6 调试

Scheme → Environment Variables → `HUDUN_DEBUG=1`：输出完整请求头、响应摘要、
密钥派生中间值（shared/aeskey/iv）。发布移除该变量即可。

---

# 第 6 章 测试用例

组织方式：`HudunAPI.swift` 加入 App target 与 Test target（或 SPM target），
测试经 `@testable import` 访问 internal 符号。

最小 `Package.swift`（SPM 独立跑法；**必须声明 platforms**，否则 macOS 编译报
completeFileProtection 可用性错误）：

```swift
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "HudunAPI",
    platforms: [.iOS(.v15), .macOS(.v12)],
    targets: [
        .target(name: "HudunAPI", path: "Sources/HudunAPI"),
        .testTarget(name: "HudunAPITests", dependencies: ["HudunAPI"], path: "Tests/HudunAPITests")
    ])
```

## 6.1 离线单元测试（固定向量，无需网络，必须全绿）

> **验证状态：9/9 通过（2026-08-24，Swift 6.3 / arm64）**
> 测试向量来源：双实现交叉验证（Swift CryptoKit ↔ PyNaCl/pycryptodome 逐字节一致）。

```swift
// HudunCryptoTests.swift
import XCTest
import CryptoKit                     // ← 必须：X25519/SHA256 断言用
@testable import HudunAPI

final class HudunCryptoTests: XCTestCase {

    // MARK: - V1 签名（排序拼接 + 盐）
    // 独立参照实现: md5("a=1b=2ts=1700000000" + salt) = 751f0b62ec734539f898f5cc2b25456c
    func testGenerateSignVector() {
        let sign = HudunClient.generateSign(["b": "2", "a": "1"],
                                            ts: "1700000000",
                                            salt: "WOYqZGTomCWAFREVnyxiyou")
        XCTAssertEqual(sign, "751f0b62ec734539f898f5cc2b25456c")
    }

    /// route_info 实际形状：id < is_full_route < public_key < ts 的字典序，
    /// 且 ts 参与签名。此向量锁定排序规则防回归。
    func testGenerateSignRouteInfoShape() {
        let p = ["id": "19", "public_key": "abc+/=", "is_full_route": "true"]
        let sign = HudunClient.generateSign(p, ts: "1700000000", salt: "SALT")
        // 参照: md5("id=19is_full_route=truepublic_key=abc+/=ts=1700000000" + "SALT")
        let expect = HudunCrypto.md5Hex(
            "id=19is_full_route=truepublic_key=abc+/=ts=1700000000" + "SALT")
        XCTAssertEqual(sign, expect)
        XCTAssertFalse(sign.isEmpty)
    }

    // MARK: - V3 X25519 + SHA256 KDF（CryptoKit ↔ PyNaCl 双库一致）
    func testX25519KDFVector() throws {
        let privHex = "a1b2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff00"
        let remoteHex = "b3a0a0b31f7acd579d6e5882b1b1be1e48acefa90ffc2a9b6ecde398af49e924"
        let priv = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: HudunCrypto.hexDecode(privHex))
        let peer = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: HudunCrypto.hexDecode(remoteHex))
        let shared = try priv.sharedSecretFromKeyAgreement(with: peer)
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        XCTAssertEqual(HudunCrypto.hexEncode(sharedBytes),
            "47851523f75cf3e763a67dbca4a0f35d62cc2c3e695968350fbe0b3a278aab53")
        XCTAssertEqual(HudunCrypto.hexEncode(Data(SHA256.hash(data: sharedBytes))),
            "7e1a8b66ba806e5b66bb7e608286e5256991c5ef30d11fac5197b20bfbfe259d")
    }

    // MARK: - V4 AES-256-CBC 解密向量（PyNaCl 加密 → Swift 解密）
    func testAesCbcDecryptVector() throws {
        let key = HudunCrypto.hexDecode(
            "7e1a8b66ba806e5b66bb7e608286e5256991c5ef30d11fac5197b20bfbfe259d")
        let blob = Data(base64Encoded:
            "AAECAwQFBgcICQoLDA0OD4wXFw/zA8+YX1mGb2V+Fmngt8m7UVHuHN/sSTjSaBdseHb/zRMN98ZtpGsqFU5p8Q==")!
        let plain = try HudunCrypto.aesCbcDecrypt(blob, key: key)
        XCTAssertEqual(String(data: plain, encoding: .utf8),
                       #"{"code":200,"msg":"","data":{"ok":true}}"#)
    }

    func testAesCbcDecryptRejectsBadLength() {
        XCTAssertThrowsError(try HudunCrypto.aesCbcDecrypt(Data([0,1,2]), key: Data(repeating: 7, count: 32)))
    }

    // MARK: - hex 编解码（回归保护：曾出现半字节流 bug）
    func testHexDecodeRoundTrip() {
        let hex = "b3a0a0b31f7acd579d6e5882b1b1be1e48acefa90ffc2a9b6ecde398af49e924"
        let data = HudunCrypto.hexDecode(hex)
        XCTAssertEqual(data.count, 32)                       // 曾退化为 16/64 字节
        XCTAssertEqual(HudunCrypto.hexEncode(data), hex)
    }

    func testHexDecodeUppercaseAndOddLength() {
        XCTAssertEqual(HudunCrypto.hexDecode("ABCD").count, 2)
        XCTAssertEqual(HudunCrypto.hexDecode("ABC").count, 1)   // 尾部残缺安全截断
    }

    // MARK: - URL 编码（字典序 + 保留字符转义）
    func testUrlEncodeSortedAndEscaped() {
        let out = HudunClient.urlEncode(["public_key": "ab+/=", "id": "4"])
        XCTAssertEqual(out, "id=4&public_key=ab%2B%2F%3D")
    }

    // MARK: - JWT exp 解析（V5 向量）
    func testJwtExpiry() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
                + "eyJleHAiOjE3ODc1NTAzNjIsImlzcyI6IndpcmVndWFyZCJ9."
                + "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"
        XCTAssertEqual(HudunClient.jwtExpiry(jwt),
                       Date(timeIntervalSince1970: 1_787_550_362))
        XCTAssertNil(HudunClient.jwtExpiry("not.a.jwt"))
    }
}
```

## 6.2 在线集成测试（打真实 API；设环境变量 `HUDUN_LIVE=1` 才执行）

```swift
// HudunLiveTests.swift
import XCTest
@testable import HudunAPI

final class HudunLiveTests: XCTestCase {
    private var client: HudunClient!

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["HUDUN_LIVE"] == "1" else {
            throw XCTSkip("在线测试未启用（设 HUDUN_LIVE=1 开启）")
        }
        var cfg = HudunConfig.standard(credentials: .init(token:"", deviceid:"", uid:""))
        if let t = ProcessInfo.processInfo.environment["HUDUN_TOKEN"] {
            cfg.credentials = .init(token: t,
                deviceid: ProcessInfo.processInfo.environment["HUDUN_DEVICEID"] ?? "",
                uid: ProcessInfo.processInfo.environment["HUDUN_UID"] ?? "")
        }
        client = HudunClient(config: cfg)
    }

    /// TC-L1 引导：TXT 解析成功，端点列表非空且含钉住映射
    func testBootstrap() async throws {
        let r = try await client.bootstrapVia(resolver: "223.5.5.5", platformKey: "all")
        XCTAssertFalse(r.endpoints.isEmpty)
        XCTAssertTrue(r.endpoints.contains { $0.host.contains("tencent-cloud.net") })
    }

    /// TC-L2 登录错误路径：错密码 → wrongCredentials(4002)，而非 4026/1134
    func testLoginWrongPassword() async throws {
        do {
            _ = try await client.login(account: "13149305021", password: "definitely-wrong")
            XCTFail("错密码不应成功")
        } catch let e as HudunError {
            guard case .wrongCredentials = e else { return XCTFail("期望 4002，得到 \(e)") }
        }
    }

    /// TC-L3 登录正确路径（需注入真实账密的测试账号）
    func testLoginSuccess() async throws {
        guard let acc = ProcessInfo.processInfo.environment["HUDUN_TEST_ACC"],
              let pwd = ProcessInfo.processInfo.environment["HUDUN_TEST_PWD"] else {
            throw XCTSkip("未提供测试账号")
        }
        let creds = try await client.login(account: acc, password: pwd)
        XCTAssertFalse(creds.token.isEmpty)
        let me = try await client.userInfo()                 // 新 token 立即可用
        XCTAssertEqual(me["code"] as? Int, 200)
    }

    /// TC-L4 线路列表结构
    func testLines() async throws {
        let lines = try await client.lines()
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.allSatisfy { $0.id > 0 })
        XCTAssertTrue(lines.contains { $0.tier == "vip" })
    }

    /// TC-L5 分流规则：地址获取 + CIDR 下载计数
    func testRouteRules() async throws {
        let allot = try await client.routeAllot()
        let chn = try await client.downloadCIDRList(allot.chn.url)
        XCTAssertGreaterThan(chn.count, 500)                  // 当前 ~888 条
        XCTAssertTrue(chn.allSatisfy { $0.contains("/") })    // 形如 a.b.c.d/nn
    }

    /// TC-L6 续期凭证包字段完备性（需有效 VIP 账号）
    func testRenewCredentialPackage() async throws {
        let wg = try await client.renew(lineId: 4)
        XCTAssertFalse(wg.privateKeyB64.isEmpty)
        XCTAssertTrue(wg.endpoint.contains(":"))              // host:port
        XCTAssertNotNil(wg.expiresAt)
        XCTAssertTrue(wg.expiresAt! > Date())                 // 未过期
        XCTAssertTrue(wg.confString.hasPrefix("[Interface]"))
        XCTAssertTrue(wg.confString.contains("AllowedIPs = 0.0.0.0/0"))
    }

    /// TC-L7 安全性：篡改 sign 必须被拒（4026），证明服务端验签在位
    func testTamperedSignRejected() async throws {
        var caught = false
        do {
            _ = try await client.request("GET", "/api/app/v3/user/user_info",
                                         extraHeaders: ["sign": String(repeating: "0", count: 32)])
        } catch let e as HudunError {
            if case .signatureRejected = e { caught = true }
        }
        XCTAssertTrue(caught, "伪造 sign 应得到 signatureRejected")
    }

    /// TC-L8 安全性：坏 token → sessionExpired(4003)
    func testBadTokenRejected() async throws {
        let bad = HudunClient(config: {
            var c = HudunConfig.standard(credentials:
                .init(token: "bad.token.value", deviceid: client!.config.credentials.deviceid,
                      uid: client!.config.credentials.uid))
            return c
        }())
        do {
            _ = try await bad.request("GET", "/api/app/v3/user/user_info")
            XCTFail("坏 token 不应成功")
        } catch let e as HudunError {
            guard case .sessionExpired = e else { return XCTFail("期望 4003，得到 \(e)") }
        }
    }

    /// TC-L9 时间偏移：sign 与 ts 不一致的大偏移 → deviceTimeSkew(1134)
    func testTimeSkewRejected() async throws {
        do {
            _ = try await client.request("GET", "/api/app/v3/user/user_info",
                                         extraHeaders: ["ts": "1000000000"])
        } catch let e as HudunError {
            if case .deviceTimeSkew = e { return }
            if case .signatureRejected = e { return }   // 服务端两种拒绝序都出现过
            return XCTFail("期望 1134/4026，得到 \(e)")
        }
        XCTFail("偏移 ts 不应成功")
    }

    /// TC-L10 重放：同头集合二次发送仍 200（无防重放——锁定该行为认知）
    func testReplayAllowed() async throws {
        _ = try await client.userInfo()
        _ = try await client.userInfo()      // 第二次不抛错即通过
    }
}
```

运行方式：

```bash
# 离线单元测试（CI 必跑）
swift test --filter HudunCryptoTests

# 在线集成测试（手动/联调环境）
HUDUN_LIVE=1 HUDUN_TOKEN=<token> HUDUN_DEVICEID=<did> HUDUN_UID=<uid> \
  swift test --filter HudunLiveTests
```

## 6.3 端到端手工验收清单

| # | 步骤 | 通过标准 |
|---|---|---|
| E1 | `huduncli lines` | 13 条线路，vip/svip 分组正确 |
| E2 | `huduncli renew 4 out.conf` | 打印 endpoint/expiresAt；conf 含五要素 |
| E3 | `wgprobe <endpoint>`（WG_PRIV=新私钥） | HANDSHAKE_OK + DATA_OK（DNS 回包 134B） |
| E4 | 导入官方 WireGuard App 连接 | tun 建立，可访问外网 |
| E5 | 手机 App 与脚本先后 renew 同一线路 | 两次 endpoint 不同（节点漂移特性成立） |
| E6 | 故意改错盐再请求 | 4026 → 恢复正确盐后 200 |

---

# 第 7 章 维护手册

| 场景 | 现象 | 动作 |
|---|---|---|
| 凭证失效 | 4003 | 手机重登 → `refresh`（Python/adb）或 Swift 直接 login → 存储新凭证 |
| 公钥轮换 | 全面解密乱码 | 查 TXT publickey → 更新 `cfg.remotePublicKeyHex`；或新版 APK 偏移 503417 邻域找 64hex |
| 端点轮换 | 全端点超时 | 自动跟随 TXT；TXT host 也变则更新 `cfg.bootstrapTXTHost` |
| 盐变更 | 全面 4026 | 新版 APK 搜盐串/generateSign 符号 → 改 `cfg.signSalt` |
| 排障方法论 | 解密异常 | 交叉解密：把"收到的密文+私钥"交给另一实现解——能解=本地 AES bug，不能解=密钥/传输问题 |

# 第 8 章 已知陷阱（历史事故，勿重蹈）

1. POST 缺 `Content-Type: application/x-www-form-urlencoded` → 症状是 4026（假签名错误）
2. login 带 `type` 参数 → 该端点签名重建不含它，签入即 4026
3. PyNaCl 用 `Box().shared_key()` 多一道 HSalsa20 → 必须 `crypto_scalarmult`
4. Swift 十六进制解析按 Character 切片出过半字节流事故 → 用字节对解析（已有单测守护）
5. NWConnection 回调上下文必须自持有至 finish，否则 continuation 泄漏挂死
6. 「sign 服务端不校验」为过时结论（2026-08-24 起全端点强校验）
7. **服务端 WG 握手为白皮书链式变体（2026-08-25 真机穷举实证）**：
   - KDF3 第三输出 = `HMAC(t, T2‖0x3)`（链式），非 wireguard-go 的扁平 `HMAC(t, T1‖0x3)`
   - msg1 需 `mixKey(E_pub_i)`（临时公钥先混入链键）——Go 实现同样有此步
   - 响应处理：三段 mixKey（E_pub_r / EE / SE）→ KDF3(psk) → τ 混 hash 作 Empty 的 AAD
   - 服务端响应包 mac1/mac2 全零；msg1 校验失败时静默丢弃
   - 症状特征：握手超时=包被丢；`校验失败`=响应已到但 KDF 风格不匹配

# 第 9 章 合规边界

仅限安全研究与机主自有账号自动化。凭据来自本人；禁止用于他人账号或规模化滥用。
接口随时可能变更，时效以文末验证日期为准（2026-08-24）。
