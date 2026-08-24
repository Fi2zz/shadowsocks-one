import Foundation

/// 凭证持久化抽象；测试注入临时目录实现。
protocol HudunCredentialStoring {
    func load() -> HudunCredentials?
    func save(_ creds: HudunCredentials) throws
    func clear()
}

/// Application Support 下的 JSON 文件存储，写入带 completeFileProtection
/// （对应 docs/hudun_master_doc.md §5.4，生产可换 Keychain）。
struct HudunFileCredentialStore: HudunCredentialStoring {
    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("hudun_credentials.json")
    }

    func load() -> HudunCredentials? {
        guard let data = try? Data(contentsOf: fileURL),
              let creds = try? JSONDecoder().decode(HudunCredentials.self, from: data) else { return nil }
        return creds
    }

    func save(_ creds: HudunCredentials) throws {
        let data = try JSONEncoder().encode(creds)
        do {
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            try data.write(to: fileURL, options: [.atomic])
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
