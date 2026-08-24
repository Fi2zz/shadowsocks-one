import Foundation

/// HudunClient 的最小接口抽象；会话层单测用替身实现替换。
protocol HudunServicing {
    func login(account: String, password: String) async throws -> HudunCredentials
    func postLoginSync() async -> (user: [String: Any]?, checkIn: [String: Any]?, notice: [String: Any]?)
    func userInfo() async throws -> [String: Any]
    func lines() async throws -> [HudunLine]
    func renew(lineId: Int) async throws -> HudunWGConfig
}

extension HudunClient: HudunServicing {
    func renew(lineId: Int) async throws -> HudunWGConfig {
        try await renew(lineId: lineId, fullRoute: true)
    }
}
