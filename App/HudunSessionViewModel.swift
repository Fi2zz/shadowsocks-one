import Foundation

/// 护盾会话状态：登录、退出、静默恢复与 4003 失效处理（对应文档 §5.4）。
@MainActor
final class HudunSessionViewModel: ObservableObject {
    enum AuthState: Equatable {
        case loggedOut
        case loggedIn
    }

    @Published private(set) var authState: AuthState = .loggedOut
    @Published private(set) var account: HudunAccountSummary?
    @Published private(set) var lines: [HudunLine] = []
    @Published private(set) var busy = false
    @Published var message: String?

    private let service: any HudunServicing
    private let store: any HudunCredentialStoring
    private var restored = false

    init(service: any HudunServicing, store: any HudunCredentialStoring) {
        self.service = service
        self.store = store
    }

    static func makeDefault() -> HudunSessionViewModel {
        let store = HudunFileCredentialStore()
        let stored = store.load() ?? HudunCredentials(
            token: "", deviceid: HudunDeviceIdentity.stableID, uid: "")
        let client = HudunClient(config: .standard(credentials: stored))
        return HudunSessionViewModel(service: client, store: store)
    }

    /// 启动流程：已存 token 静默验证，失效则清凭证回登录页。
    func restoreSessionIfNeeded() async {
        guard !restored else { return }
        restored = true
        guard let creds = store.load(), !creds.token.isEmpty else { return }
        await reloadAccount()
    }

    func login(account: String, password: String) async {
        busy = true
        defer { busy = false }
        do {
            let creds = try await service.login(account: account, password: password)
            try? store.save(creds)
            authState = .loggedIn
            message = nil
            await postLoginRefresh()
        } catch {
            apply(error)
        }
    }

    func logout() {
        restored = false
        store.clear()
        authState = .loggedOut
        account = nil
        lines = []
        message = "已退出登录"
    }

    func refreshLines() async {
        do {
            lines = try await service.lines()
        } catch {
            apply(error)
        }
    }

    func renew(lineId: Int) async -> HudunWGConfig? {
        busy = true
        defer { busy = false }
        do {
            return try await service.renew(lineId: lineId)
        } catch {
            apply(error)
            return nil
        }
    }

    /// 拉取 user_info 校验当前凭证；成功则进入已登录态并加载线路。
    func reloadAccount() async {
        busy = true
        defer { busy = false }
        do {
            let info = try await service.userInfo()
            account = .parse(dataDict(info))
            authState = .loggedIn
            await refreshLines()
        } catch {
            apply(error)
        }
    }

    private func postLoginRefresh() async {
        let sync = await service.postLoginSync()
        if let user = sync.user {
            account = .parse(dataDict(user))
        }
        await refreshLines()
    }

    private func dataDict(_ envelope: [String: Any]?) -> [String: Any] {
        envelope?["data"] as? [String: Any] ?? [:]
    }

    /// 业务错误统一出口：仅 4003 清凭证登出，其余只提示。
    private func apply(_ error: Error) {
        guard let hudun = error as? HudunError else {
            message = error.localizedDescription
            return
        }
        if case .sessionExpired = hudun {
            forceSignOut()
            message = "登录已失效，请重新登录"
            return
        }
        message = HudunMessage.describe(hudun)
    }

    private func forceSignOut() {
        store.clear()
        authState = .loggedOut
    }
}

/// 错误 → 用户可读文案（业务码含义见文档 §2.4）。
enum HudunMessage {
    static func describe(_ error: HudunError) -> String {
        switch error {
        case .wrongCredentials:
            return "账号或密码错误"
        case .vipExpired(let detail):
            return "会员已到期：\(detail)"
        default:
            return error.description
        }
    }
}
