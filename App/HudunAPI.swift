// HudunAPI.swift — 护盾 VPN 全链路客户端（iOS 嵌入版，零第三方依赖）
//
// 链路对应（逆向结论见 _out/hudun_api_handoff.md）：
//   阶段0 冷启动   bootstrap()          DNS TXT → 域名/IP/公钥动态下发（可懒执行）
//   阶段1 登录     login(account:pwd:)  明文凭据 POST /user/login；成功后凭证自动应用
//                  postLoginSync()      等价 handleLoginSuccess：userInfo/checkIn/notices
//   阶段2 选线     lines()              实时快照 route_list
//   阶段3 连接     renew(lineId:)       route_info 下发 WG 凭证包 → confString
//
// 设计约束：
//   - init() 零网络调用（只生成会话 X25519 密钥对 + 注入配置）
//   - 网络操作全部显式 async 方法；request() 内置"全端点失败→自动 bootstrap 一次→重试"
//   - 服务端规则已内化：sign=md5(排序参数含ts+盐)；ts 不进 URL/body；
//     4026/1134/4003 映射为强类型错误；响应 AES-256-CBC 自动解密
//
// 宿主 App 用法：
//   var cfg = HudunConfig.standard(
//       credentials: HudunCredsStore.load() ?? HudunCredentials(token:"",deviceid:"",uid:""))
//   let client = HudunClient(config: cfg)
//   let ok = await client.bootstrap()                    // 可选；失败自动兜底静态端点
//   if cfg.credentials.token.isEmpty {
//       let creds = try await client.login(account: u, password: p)  // 明文密码
//       HudunCredsStore.save(creds)
//   } else {
//       _ = try? await client.postLoginSync()             // 签到/资料刷新（可选）
//   }
//   let lines = try await client.lines()
//   let wg = try await client.renew(lineId: lines[0].id)  // wg.confString 导入隧道

import Foundation
import CryptoKit
import CommonCrypto
import Network
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 错误

public enum HudunError: Error, CustomStringConvertible {
    case sessionExpired                       // 4003
    case wrongCredentials(String)             // 4002 等：账密/验证码错
    case signatureRejected                    // 4026
    case deviceTimeSkew                       // 1134
    case vipExpired(String)                   // 1131
    case http(status: Int, body: String)
    case badResponse(String)
    case transport(String)

    public var description: String {
        switch self {
        case .sessionExpired: return "登录失效(4003)"
        case .wrongCredentials(let m): return "凭据错误: \(m)"
        case .signatureRejected: return "签名验证失败(4026)"
        case .deviceTimeSkew: return "时间偏差(1134)"
        case .vipExpired(let m): return "会员到期(1131): \(m)"
        case .http(let s, let b): return "HTTP \(s): \(b.prefix(120))"
        case .badResponse(let m): return "响应异常: \(m)"
        case .transport(let m): return "网络错误: \(m)"
        }
    }

    static func from(code: Int?, msg: String?) -> HudunError? {
        switch code {
        case 4003: return .sessionExpired
        case 4026: return .signatureRejected
        case 1134: return .deviceTimeSkew
        case 4002: return .wrongCredentials(msg ?? "")
        case 1131: return .vipExpired(msg ?? "")
        default: return nil
        }
    }
}

// MARK: - 凭证与设备档案

public struct HudunCredentials: Codable, Equatable, Sendable {
    public var token: String
    public var deviceid: String
    public var uid: String

    public init(token: String, deviceid: String, uid: String) {
        self.token = token
        self.deviceid = deviceid
        self.uid = uid
    }

    public var isAnonymous: Bool { token.isEmpty || deviceid.isEmpty || uid.isEmpty }
}

public struct HudunDeviceProfile: Sendable {
    public var brand: String
    public var model: String
    public var apilevel: String
    public var systemVersion: String
    public var manufacturer: String
    public var deviceName: String

    /// 默认取宿主真机信息；传入参数逐项覆盖。
    public init(brand: String? = nil, model: String? = nil, apilevel: String = "",
                systemVersion: String? = nil, manufacturer: String? = nil,
                deviceName: String? = nil) {
        #if canImport(UIKit)
        self.brand = brand ?? "Apple"
        self.model = model ?? Self.unameMachine()
        self.manufacturer = manufacturer ?? "Apple"
        self.systemVersion = systemVersion ?? UIDevice.current.systemVersion
        self.deviceName = deviceName ?? UIDevice.current.name
        #else
        self.brand = brand ?? "Apple"
        self.model = model ?? Self.unameMachine()
        self.manufacturer = manufacturer ?? "Apple"
        self.systemVersion = systemVersion ?? ProcessInfo.processInfo.operatingSystemVersionString
        self.deviceName = deviceName ?? Host.current().localizedName ?? "Mac"
        #endif
        self.apilevel = apilevel
    }

    static func unameMachine() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { buf in
            String(cString: buf.baseAddress!.assumingMemoryBound(to: CChar.self))
                .trimmingCharacters(in: .controlCharacters)
        }
    }

    func uaJSON(versionCode: String, versionName: String) -> String {
        let obj: [String: Any] = [
            "brand": brand, "model": model, "APILevel": apilevel,
            "networkType": "", "channel": "", "spreadNum": "", "country": "CN",
            "manufacturer": manufacturer,
            "versionCode": versionCode, "versionName": versionName,
            "systemVersion": systemVersion, "isEmulator": false, "isTablet": false,
            "openinstallData": ["channelCode": ""], "deviceName": deviceName,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

public struct HudunConfig: Sendable {
    public var signSalt: String
    public var remotePublicKeyHex: String
    public var bootstrapTXTHost: String
    public var bootstrapKey: String
    public var resolvers: [String]
    public var staticEndpoints: [(host: String, ip: String?)]
    public var appVersionName: String
    public var appVersionCode: String
    public var bundleId: String
    public var credentials: HudunCredentials
    public var deviceProfile: HudunDeviceProfile

    /// 当前已知可用值；全部可在运行时覆盖（运营方轮换后改这里即可）。
    public static func standard(credentials: HudunCredentials,
                                profile: HudunDeviceProfile = HudunDeviceProfile()) -> HudunConfig {
        HudunConfig(
            signSalt: "WOYqZGTomCWAFREVnyxiyou",
            remotePublicKeyHex: "b3a0a0b31f7acd579d6e5882b1b1be1e48acefa90ffc2a9b6ecde398af49e924",
            bootstrapTXTHost: "newxyqt.xyapiali.com",
            bootstrapKey: "wriQVbeJqBWC2qJ0",
            resolvers: ["223.5.5.5", "119.29.29.29", "8.8.8.8"],
            staticEndpoints: [
                (host: "ins-r23tsuxy.ias.tencent-cloud.net", ip: "81.71.156.35"),
                (host: "api.yzcyhm.com", ip: nil),
            ],
            appVersionName: "4.4.0",
            appVersionCode: "19",
            bundleId: "com.speed.bilin",
            credentials: credentials,
            deviceProfile: profile)
    }
}

// MARK: - 结果模型

public struct HudunLine: Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let typeName: String
    public let groupName: String
    public let flagName: String
    public let ip: String
    public let imageURL: String?
    public let vipState: Int
    public let isBlocked: Bool
    public let tier: String            // vip | svip
}

public struct HudunWGConfig: Sendable {
    public let privateKeyB64: String
    public let address: String
    public let dns: String
    public let endpoint: String
    public let peerPublicKey: String
    public let mtu: Int
    public let expiresAt: Date?
    public let confString: String
}

public struct HudunBootstrapResult: Sendable {
    public let endpoints: [(host: String, ip: String?)]
    public let remotePublicKeyUpdated: Bool
    public let domains: [String]
}

/// 智能分流规则集描述（route_allot 响应）。
public struct HudunRuleSet: Sendable {
    public let name: String        // "chn" | "nochn"
    public let id: Int
    public let url: String
}

public struct HudunRouteAllot: Sendable {
    public let chn: HudunRuleSet      // 国内 CIDR 段
    public let nochn: HudunRuleSet    // 非国内 CIDR 段
}

// MARK: - 密码学助手

enum HudunCrypto {
    static func md5Hex(_ s: String) -> String {
        hexEncode(Data(Insecure.MD5.hash(data: Data(s.utf8))))
    }

    static func hexEncode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func hexDecode(_ s: String) -> Data {
        let chars = Array(s.utf8)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            case 0x41...0x46: return c - 0x41 + 10
            default: return nil
            }
        }
        var bytes = [UInt8]()
        var i = 0
        while i + 1 < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { break }
            bytes.append(hi << 4 | lo)
            i += 2
        }
        return Data(bytes)
    }

    static func aesCbcDecrypt(_ input: Data, key: Data) throws -> Data {
        let blockSize = Int(kCCBlockSizeAES128)
        guard input.count % blockSize == 0, input.count >= blockSize * 2 else {
            throw HudunError.badResponse("密文长度非法 \(input.count)")
        }
        let iv = input.prefix(blockSize)
        let ct = input.suffix(from: blockSize)
        var out = [UInt8](repeating: 0, count: ct.count)
        var outLen = 0
        let status = key.withUnsafeBytes { kp in
            iv.withUnsafeBytes { vp in
                ct.withUnsafeBytes { cp in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                            kp.baseAddress, key.count, vp.baseAddress,
                            cp.baseAddress, ct.count, &out, out.count, &outLen)
                }
            }
        }
        guard status == kCCSuccess else { throw HudunError.badResponse("CCCrypt \(status)") }
        guard outLen > 0 else { throw HudunError.badResponse("解密输出为空") }
        let pad = Int(out[outLen - 1])
        if pad > 0, pad <= 16, out[(outLen - pad)..<outLen].allSatisfy({ $0 == pad }) {
            outLen -= pad
        }
        return Data(out.prefix(outLen))
    }
}

// MARK: - TLS 传输

struct HudunHTTPResponse: @unchecked Sendable {
    let status: Int
    let body: Data
}

enum HudunTransport {
    struct Request: @unchecked Sendable {
        var host: String
        var ip: String?
        var method: String
        var pathWithQuery: String
        var headers: [String: String]
        var body: Data?
        var timeout: TimeInterval = 15
    }

    static func perform(_ req: Request) async throws -> HudunHTTPResponse {
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, req.host)
        let verifyQueue = DispatchQueue(label: "hudun.tls.verify")
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions, { _, _, complete in complete(true) }, verifyQueue)

        let connection = NWConnection(
            host: NWEndpoint.Host(req.ip ?? req.host), port: 443,
            using: NWParameters(tls: tlsOptions))

        return try await withCheckedThrowingContinuation { cont in
            ConnContext(connection: connection, continuation: cont, request: req)
                .startAndRetain()
        }
    }

    private final class ConnContext: @unchecked Sendable {
        let connection: NWConnection
        let continuation: CheckedContinuation<HudunHTTPResponse, Error>
        let request: Request
        var buffer = [UInt8]()
        var finished = false
        var selfRef: ConnContext?
        let lock = NSLock()
        var timeoutItem: DispatchWorkItem?

        init(connection: NWConnection,
             continuation: CheckedContinuation<HudunHTTPResponse, Error>,
             request: Request) {
            self.connection = connection
            self.continuation = continuation
            self.request = request
        }

        /// 持有自身直到完成（否则创建即释放、continuation 泄漏）。
        func startAndRetain() {
            selfRef = self
            start()
        }

        func start() {
            let item = DispatchWorkItem { [weak self] in
                self?.finish(.failure(HudunError.transport("超时")))
            }
            timeoutItem = item
            DispatchQueue.global().asyncAfter(deadline: .now() + request.timeout, execute: item)

            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.sendHead()
                case .failed(let e): self?.finish(.failure(HudunError.transport("\(e)")))
                case .cancelled: self?.finish(.failure(HudunError.transport("连接取消")))
                default: break
                }
            }
            connection.start(queue: DispatchQueue.global())
        }

        private func sendHead() {
            var head = "\(request.method) \(request.pathWithQuery) HTTP/1.1\r\nHost: \(request.host)\r\n"
            for (k, v) in request.headers.sorted(by: { $0.key < $1.key }) {
                head += "\(k): \(v)\r\n"
            }
            head += "Connection: close\r\n"
            if let b = request.body { head += "Content-Length: \(b.count)\r\n" }
            head += "\r\n"

            var payload = Data(head.utf8)
            if let b = request.body { payload.append(b) }
            connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.finish(.failure(HudunError.transport("发送失败 \(error)")))
                } else {
                    self?.receiveLoop()
                }
            })
        }

        private func receiveLoop() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data { self.buffer.append(contentsOf: [UInt8](data)) }
                if let error {
                    self.finish(.failure(HudunError.transport("接收失败 \(error)")))
                } else if isComplete {
                    self.finish(self.parseResponse())
                } else {
                    self.receiveLoop()
                }
            }
        }

        private func parseResponse() -> Result<HudunHTTPResponse, Error> {
            guard let sep = buffer.firstRange(of: Array("\r\n\r\n".utf8)) else {
                return .failure(HudunError.badResponse("HTTP 头不完整"))
            }
            let statusText = String(bytes: buffer[0..<sep.lowerBound], encoding: .utf8) ?? ""
            guard let status = Int(statusText.split(separator: " ").dropFirst().first ?? "") else {
                return .failure(HudunError.badResponse("状态行解析失败"))
            }
            var body = Array(buffer[sep.upperBound...])
            let lower = statusText.lowercased()
            if lower.contains("transfer-encoding") && lower.contains("chunked") {
                body = dechunk(body)
            }
            return .success(HudunHTTPResponse(status: status, body: Data(body)))
        }

        private func dechunk(_ raw: [UInt8]) -> [UInt8] {
            var out = [UInt8]()
            var i = 0
            while i < raw.count {
                guard let le = raw[i...].firstRange(of: Array("\r\n".utf8)) else { break }
                let hexStr = String(bytes: raw[i..<le.lowerBound], encoding: .utf8) ?? ""
                let size = Int(hexStr.split(separator: ";").first.map(String.init) ?? "0", radix: 16) ?? 0
                if size == 0 { break }
                let s = le.upperBound
                guard s + size <= raw.count else { break }
                out.append(contentsOf: raw[s..<(s + size)])
                i = s + size + 2
            }
            return out
        }

        func finish(_ result: Result<HudunHTTPResponse, Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            lock.unlock()
            timeoutItem?.cancel()
            connection.cancel()
            selfRef = nil          // 解除自持有，允许释放
            continuation.resume(with: result)
        }
    }
}

// MARK: - DNS TXT 查询

enum HudunDNS {
    static func queryTXT(host: String, resolver: String, timeout: TimeInterval = 6) async throws -> String {
        let query = try buildQuery(host: host)
        let conn = NWConnection(host: NWEndpoint.Host(resolver), port: 53,
                                using: .udp)
        defer { conn.cancel() }

        return try await withCheckedThrowingContinuation { cont in
            var finished = false
            let lock = NSLock()
            var timer: DispatchWorkItem?
            func finishWith(_ result: Result<String, Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                timer?.cancel()
                cont.resume(with: result)
            }
            timer = DispatchWorkItem {
                finishWith(.failure(HudunError.transport("DNS 超时")))
            }
            if let timer {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: query, completion: .contentProcessed { err in
                        if let err { finishWith(.failure(err)); return }
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                            if let error { finishWith(.failure(error)); return }
                            guard let data else {
                                finishWith(.failure(HudunError.transport("DNS 无应答"))); return
                            }
                            do {
                                finishWith(.success(try parseTXT(response: [UInt8](data))))
                            } catch {
                                finishWith(.failure(error))
                            }
                        }
                    })
                case .failed(let e):
                    finishWith(.failure(e))
                default:
                    break
                }
            }
            conn.start(queue: DispatchQueue.global())
        }
    }

    static func buildQuery(host: String) throws -> Data {
        var msg = Data()
        func u16(_ v: Int) {
            msg.append(UInt8((v >> 8) & 0xff)); msg.append(UInt8(v & 0xff))
        }
        u16(Int.random(in: 1..<65536)); u16(0x0100)
        u16(1); u16(0); u16(0); u16(0)
        for label in host.split(separator: ".") {
            let bytes = Array(label.utf8)
            guard !bytes.isEmpty, bytes.count <= 63 else {
                throw HudunError.transport("DNS 标签非法")
            }
            msg.append(UInt8(bytes.count)); msg.append(contentsOf: bytes)
        }
        msg.append(0); u16(16); u16(1)
        return msg
    }

    static func parseTXT(response: [UInt8]) throws -> String {
        guard response.count > 12 else { throw HudunError.transport("DNS 应答过短") }
        guard response[3] & 0x0f == 0 else {
            throw HudunError.transport("DNS RCODE=\(response[3] & 0x0f)")
        }
        var i = 12
        while i < response.count && response[i] != 0 { i += Int(response[i]) + 1 }
        i += 5
        var out = ""
        while i + 12 <= response.count {
            if response[i] & 0xc0 == 0xc0 {
                i += 2
            } else {
                while i < response.count && response[i] != 0 { i += Int(response[i]) + 1 }
                i += 1
            }
            guard i + 10 <= response.count else { break }
            let type = (Int(response[i]) << 8) | Int(response[i + 1])
            let rdlen = (Int(response[i + 8]) << 8) | Int(response[i + 9])
            let rdStart = i + 10
            guard rdStart + rdlen <= response.count else { break }
            if type == 16 {
                var j = rdStart
                let end = rdStart + rdlen
                while j < end {
                    let len = Int(response[j]); j += 1
                    if j + len <= end,
                       let s = String(bytes: response[j..<(j + len)], encoding: .utf8) {
                        out += s
                    }
                    j += len
                }
            }
            i = rdStart + rdlen
        }
        return out
    }
}

// MARK: - 客户端

public final class HudunClient: @unchecked Sendable {
    public private(set) var config: HudunConfig
    private let lock = NSLock()
    private var endpoints: [(host: String, ip: String?)]
    private var didAutoBootstrap = false
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    public let publicKeyB64: String
    public let publicKeyHex: String

    /// 初始化零网络：仅生成会话密钥对并保存配置。
    public init(config: HudunConfig) {
        self.config = config
        self.endpoints = config.staticEndpoints
        let key = Curve25519.KeyAgreement.PrivateKey()
        self.privateKey = key
        let raw = key.publicKey.rawRepresentation
        self.publicKeyHex = HudunCrypto.hexEncode(Data(raw))
        self.publicKeyB64 = Data(raw).base64EncodedString()
    }

    // MARK: 阶段0 引导

    /// DNS TXT 动态下发：域名/IP 映射 + 可选服务端公钥轮换。
    @discardableResult
    public func bootstrap(platformKey: String = "ios") async -> HudunBootstrapResult? {
        for resolver in config.resolvers {
            if let result = try? await bootstrapVia(resolver: resolver, platformKey: platformKey) {
                return result
            }
        }
        return nil
    }

    public func bootstrapVia(resolver: String, platformKey: String = "ios") async throws -> HudunBootstrapResult {
        let txt = try await HudunDNS.queryTXT(host: config.bootstrapTXTHost, resolver: resolver)
        guard !txt.isEmpty else { throw HudunError.badResponse("TXT 为空") }
        let cleaned = txt.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r\t"))
        guard let blob = Data(base64Encoded: cleaned) else {
            throw HudunError.badResponse("TXT 非 base64")
        }
        let plain = try HudunCrypto.aesCbcDecrypt(blob, key: Data(config.bootstrapKey.utf8))
        guard let obj = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else {
            throw HudunError.badResponse("引导 JSON 异常")
        }
        return applyBootstrap(obj, platformKey: platformKey)
    }

    /// 直接应用外部获取的引导 JSON。
    @discardableResult
    public func applyBootstrap(_ dict: [String: Any], platformKey: String = "ios") -> HudunBootstrapResult {
        lock.lock(); defer { lock.unlock() }
        var list: [(String, String?)] = []
        var seen = Set<String>()

        if let ips = dict["ips"] as? [String: Any],
           (ips["enabled"] as? Int ?? 1) != 0,
           let mappings = ips["mappings"] as? [[String: Any]] {
            for m in mappings {
                guard let host = m["host"] as? String, let ip = m["ip"] as? String,
                      seen.insert(host).inserted else { continue }
                list.append((host, ip))
            }
        }
        var domains: [String] = []
        if let dm = dict["domains"] as? [String: Any] {
            domains += (dm[platformKey] as? [String]) ?? []
            domains += (dm["all"] as? [String]) ?? []
        }
        for entry in domains {
            guard let url = URL(string: entry), let host = url.host,
                  seen.insert(host).inserted else { continue }
            list.append((host, nil))
        }
        if !list.isEmpty {
            endpoints = list + config.staticEndpoints
        }

        var updated = false
        if let pk = dict["publickey"] as? String, pk.count == 64,
           pk.lowercased() != config.remotePublicKeyHex.lowercased() {
            config.remotePublicKeyHex = pk.lowercased()
            updated = true
        }
        return HudunBootstrapResult(endpoints: currentEndpoints(),
                                    remotePublicKeyUpdated: updated, domains: domains)
    }

    // MARK: 阶段1 登录

    /// 账密登录（明文密码；body 仅 username/password——实测 type 参与即 4026）。
    /// 成功后新凭证自动应用到本客户端并返回。
    @discardableResult
    public func login(account: String, password: String) async throws -> HudunCredentials {
        let payload = try await request("POST", "/api/app/v3/user/login",
                                        ["username": account.trimmingCharacters(in: .whitespaces),
                                         "password": password.trimmingCharacters(in: .whitespaces)])
        guard let code = payload["code"] as? Int, code == 200 else {
            throw HudunError.wrongCredentials(payload["msg"] as? String ?? "")
        }
        guard let data = payload["data"] as? [String: Any],
              let token = data["token"] as? String, !token.isEmpty else {
            throw HudunError.badResponse("登录响应缺 token")
        }
        var uid = config.credentials.uid
        if let user = data["user"] as? [String: Any],
           let u = (user["uid"] as? NSNumber)?.stringValue {
            uid = u
        } else if let u = (data["uid"] as? NSNumber)?.stringValue {
            uid = u
        }
        let newCreds = HudunCredentials(token: token, deviceid: config.credentials.deviceid, uid: uid)
        lock.lock()
        config.credentials = newCreds
        lock.unlock()
        return newCreds
    }

    /// handleLoginSync：登录成功后的资料/签到/公告刷新（可选批量调用）。
    public func postLoginSync() async -> (user: [String: Any]?, checkIn: [String: Any]?, notice: [String: Any]?) {
        async let user = try? userInfo()
        async let checkIn = try? request("POST", "/api/app/v3/user/check_in")
        async let notice = try? request("GET", "/api/app/v3/notice/info")
        return (await user, await checkIn, await notice)
    }

    public func sendSmsCode(phone: String) async throws -> Bool {
        _ = try await request("POST", "/api/app/v3/common/captcha",
                              ["username": phone, "type": "1"])
        return true
    }

    // MARK: 阶段2 选线

    public func lines() async throws -> [HudunLine] {
        let payload = try await request("GET", "/api/app/v3/route_list")
        guard let code = payload["code"] as? Int, code == 200,
              let data = payload["data"] as? [String: Any] else {
            throw HudunError.badResponse("route_list: \(payload)")
        }
        var result = [HudunLine]()
        for tier in ["vip", "svip"] {
            guard let items = data[tier] as? [[String: Any]] else { continue }
            for it in items {
                guard let id = (it["id"] as? NSNumber)?.intValue else { continue }
                result.append(HudunLine(
                    id: id,
                    name: it["name"] as? String ?? "",
                    typeName: it["type_name"] as? String ?? "",
                    groupName: it["group_name"] as? String ?? "",
                    flagName: it["flag_name"] as? String ?? "",
                    ip: it["ip"] as? String ?? "",
                    imageURL: it["image_url"] as? String,
                    vipState: (it["vip_state"] as? NSNumber)?.intValue ?? 0,
                    isBlocked: (it["is_block"] as? NSNumber)?.intValue == 1,
                    tier: tier))
            }
        }
        return result
    }

    // MARK: 阶段3 连接

    /// 智能分流规则地址（对应原 App 连接后写入 tun0 的 chn/nochn CIDR 表）。
    public func routeAllot() async throws -> HudunRouteAllot {
        let payload = try await request("GET", "/api/app/v3/common/route_allot")
        guard let code = payload["code"] as? Int, code == 200,
              let data = payload["data"] as? [String: Any],
              let chn = data["chn"] as? [String: Any],
              let nochn = data["nochn"] as? [String: Any],
              let chnUrl = chn["url"] as? String,
              let nochnUrl = nochn["url"] as? String else {
            throw HudunError.badResponse("route_allot: \(payload)")
        }
        return HudunRouteAllot(
            chn: HudunRuleSet(name: "chn", id: (chn["id"] as? NSNumber)?.intValue ?? 0, url: chnUrl),
            nochn: HudunRuleSet(name: "nochn", id: (nochn["id"] as? NSNumber)?.intValue ?? 0, url: nochnUrl))
    }

    /// 下载 CIDR 规则文本（公开 COS 文件，无需鉴权头），逐行返回。
    public func downloadCIDRList(_ urlString: String) async throws -> [String] {
        guard let url = URL(string: urlString), let host = url.host else {
            throw HudunError.badResponse("规则 URL 非法: \(urlString)")
        }
        var pathWithQuery = url.path.isEmpty ? "/" : url.path
        if let q = url.query { pathWithQuery += "?" + q }
        let resp = try await HudunTransport.perform(HudunTransport.Request(
            host: host, ip: nil, method: "GET", pathWithQuery: pathWithQuery,
            headers: ["user-agent": config.deviceProfile.uaJSON(
                versionCode: config.appVersionCode, versionName: config.appVersionName)],
            body: nil))
        guard resp.status == 200 else {
            throw HudunError.http(status: resp.status,
                                  body: String(data: resp.body.prefix(120), encoding: .utf8) ?? "?")
        }
        return String(data: resp.body, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.contains("/") } ?? []
    }

    public func renew(lineId: Int, fullRoute: Bool = true) async throws -> HudunWGConfig {
        let payload = try await request("GET", "/api/app/v3/user/route_info", [
            "id": String(lineId),
            "public_key": publicKeyB64,
            "is_full_route": fullRoute ? "true" : "false",
        ])
        guard let code = payload["code"] as? Int, code == 200,
              let data = payload["data"] as? [String: Any],
              let theirKey = data["their_public_key"] as? String,
              let allowIp = data["allow_ip"] as? String,
              let endpoint = data["ip"] as? String else {
            throw HudunError.badResponse("route_info: \(payload)")
        }
        let mask = (data["mask"] as? NSNumber)?.stringValue ?? "32"
        let dnss = (data["dnss"] as? [String])?.joined(separator: ",") ?? "22.0.0.2"
        let mtu = (data["mtu"] as? NSNumber)?.intValue ?? 1300
        let privB64 = Data(privateKey.rawRepresentation).base64EncodedString()
        let expiresAt = (data["sign"] as? String).flatMap(Self.jwtExpiry)
        let conf = """
        [Interface]
        PrivateKey = \(privB64)
        Address = \(allowIp)/\(mask)
        DNS = \(dnss)
        MTU = \(mtu)

        [Peer]
        PublicKey = \(theirKey)
        Endpoint = \(endpoint)
        AllowedIPs = 0.0.0.0/0
        PersistentKeepalive = 25
        """
        return HudunWGConfig(privateKeyB64: privB64, address: allowIp, dns: dnss,
                             endpoint: endpoint, peerPublicKey: theirKey, mtu: mtu,
                             expiresAt: expiresAt, confString: conf)
    }

    // MARK: 通用请求

    /// 任意方法/路径/参数；业务错误映射强类型；网络层失败换端点，
    /// 全部端点失败时自动 bootstrap 一次再试（等价 HostHub 容灾）。
    @discardableResult
    public func request(_ method: String, _ path: String,
                        _ params: [String: String] = [:],
                        extraHeaders: [String: String] = [:]) async throws -> [String: Any] {
        let upper = method.uppercased()
        var lastError: Error?

        for attempt in 0..<2 {
            if attempt == 1 && !didAutoBootstrap {
                didAutoBootstrap = true
                await bootstrap()
            } else if attempt == 1 {
                break
            }
            for (host, ip) in currentEndpoints() {
                do {
                    return try await singleRequest(upper, path, params, extraHeaders, host, ip)
                } catch let e as HudunError {
                    switch e {
                    case .sessionExpired, .signatureRejected, .deviceTimeSkew,
                         .wrongCredentials, .vipExpired:
                        throw e
                    default:
                        lastError = e
                    }
                } catch {
                    lastError = error
                }
            }
        }
        throw lastError ?? HudunError.transport("\(upper) \(path) 全部端点失败")
    }

    private func singleRequest(_ upper: String, _ path: String,
                               _ params: [String: String], _ extraHeaders: [String: String],
                               _ host: String, _ ip: String?) async throws -> [String: Any] {
        let ts = String(Int(Date().timeIntervalSince1970))
        var headers = buildHeaders(params: params, ts: ts)
        headers.merge(extraHeaders) { _, new in new }

        var fullPath = path
        var body: Data?
        if upper == "GET" || upper == "HEAD" {
            if !params.isEmpty { fullPath += "?" + Self.urlEncode(params) }
        } else {
            body = Data(Self.urlEncode(params).utf8)
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        }

        if ProcessInfo.processInfo.environment["HUDUN_DEBUG"] != nil {
            var dbg = "== SWIFT REQ \(upper) \(fullPath) host=\(host) ip=\(ip ?? "-")\n"
            for (k, v) in headers.sorted(by: { $0.key < $1.key }) { dbg += "   \(k): \(v)\n" }
            FileHandle.standardError.write(Data(dbg.utf8))
        }

        let resp = try await HudunTransport.perform(HudunTransport.Request(
            host: host, ip: ip, method: upper,
            pathWithQuery: fullPath, headers: headers, body: body))
        guard resp.status == 200 else {
            throw HudunError.http(status: resp.status,
                                  body: String(data: resp.body, encoding: .utf8) ?? "?")
        }
        let text = String(data: resp.body, encoding: .utf8) ?? ""
        if ProcessInfo.processInfo.environment["HUDUN_DEBUG"] != nil {
            FileHandle.standardError.write(Data(
                "== SWIFT RESP len=\(text.count) head=\(text.prefix(100))\n".utf8))
        }
        let payload = try decodeResponse(text)
        if let code = payload["code"] as? Int,
           let mapped = HudunError.from(code: code, msg: payload["msg"] as? String) {
            throw mapped
        }
        return payload
    }

    public func userInfo() async throws -> [String: Any] {
        try await request("GET", "/api/app/v3/user/user_info")
    }

    // MARK: 内部

    private func currentEndpoints() -> [(host: String, ip: String?)] {
        lock.lock(); defer { lock.unlock() }
        return endpoints
    }

    private func buildHeaders(params: [String: String], ts: String) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        let c = config.credentials
        return [
            "uid": c.uid, "ts": ts,
            "sign": Self.generateSign(params, ts: ts, salt: config.signSalt),
            "deviceid": c.deviceid, "authorization": c.token,
            "publickey": publicKeyHex,
            "appversion": config.appVersionName, "versioncode": config.appVersionCode,
            "bundleid": config.bundleId,
            "platform": "Android", "language": "zh", "language-platform": "flutter",
            "channel": "", "xray-support": "1", "appproxy": "0", "istv": "",
            "spreadnum": "", "push-id": "", "devicename": config.deviceProfile.deviceName,
            "last_notice_id": "0", "last_feedback_id": "0",
            "ua": config.deviceProfile.uaJSON(versionCode: config.appVersionCode,
                                              versionName: config.appVersionName),
            "user-agent": config.deviceProfile.uaJSON(versionCode: config.appVersionCode,
                                                      versionName: config.appVersionName),
        ]
    }

    private func currentRemoteKeyHex() -> String {
        lock.lock(); defer { lock.unlock() }
        return config.remotePublicKeyHex
    }

    private func decodeResponse(_ text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"),
           let obj = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] {
            return obj
        }
        guard let blob = Data(base64Encoded: trimmed) else {
            throw HudunError.badResponse("非 JSON/Base64: \(trimmed.prefix(60))")
        }
        let peer = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: HudunCrypto.hexDecode(currentRemoteKeyHex()))
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        let aesKey = Data(SHA256.hash(data: sharedBytes))
        if ProcessInfo.processInfo.environment["HUDUN_DEBUG"] != nil {
            let dbg = "== CRYPTO remote=\(currentRemoteKeyHex()) "
                + "peerRaw=\(HudunCrypto.hexEncode(peer.rawRepresentation)) "
                + "priv=\(HudunCrypto.hexEncode(privateKey.rawRepresentation).prefix(16)).. "
                + "shared=\(HudunCrypto.hexEncode(sharedBytes))\n"
            FileHandle.standardError.write(Data(dbg.utf8))
        }
        let plain = try HudunCrypto.aesCbcDecrypt(blob, key: aesKey)
        guard let obj = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else {
            throw HudunError.badResponse("解密后非 JSON")
        }
        return obj
    }

    static func generateSign(_ params: [String: String], ts: String, salt: String) -> String {
        var merged = params
        merged["ts"] = ts
        let raw = merged.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined()
        return HudunCrypto.md5Hex(raw + salt)
    }

    static func urlEncode(_ params: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        }
        return params.sorted { $0.key < $1.key }
            .map { "\(enc($0.key))=\(enc($0.value))" }.joined(separator: "&")
    }

    static func jwtExpiry(_ jwt: String) -> Date? {
        guard let part = jwt.split(separator: ".").dropFirst().first else { return nil }
        var b64 = String(part)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let exp = (obj["exp"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

// MARK: - 凭证持久化（Keychain 级文件保护，可选使用）

public enum HudunCredsStore {
    public static func fileURL(filename: String = "hudun_credentials.json") -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }

    public static func save(_ creds: HudunCredentials) throws {
        try JSONEncoder().encode(creds)
            .write(to: fileURL(), options: [.atomic, .completeFileProtection])
    }

    public static func load() -> HudunCredentials? {
        guard let data = try? Data(contentsOf: fileURL()),
              let creds = try? JSONDecoder().decode(HudunCredentials.self, from: data) else { return nil }
        return creds
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: fileURL())
    }
}
