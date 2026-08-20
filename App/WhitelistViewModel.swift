import Foundation
import SharedCore

@MainActor
final class WhitelistViewModel: ObservableObject {
    private static let storeUnavailableMessage = "路由配置存储不可用，本次修改仅在当前会话有效。"
    private static let changeHintMessage = "白名单内的域名将直连不走代理，修改在下次连接时生效。"

    @Published private(set) var domains: [String] = []
    @Published var newEntry = ""
    @Published private(set) var message: String?

    private let store: RoutingConfigurationStore?
    private var bypassCNIP = false

    init(store: RoutingConfigurationStore?) {
        self.store = store
        load()
    }

    static func makeDefault() -> WhitelistViewModel {
        WhitelistViewModel(
            store: try? RoutingConfigurationStore(
                appGroupID: SharedContainerSettings.appGroupID
            )
        )
    }

    func addEntry() {
        let entry = newEntry
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !entry.isEmpty, !domains.contains(entry) else {
            return
        }

        domains.append(entry)
        newEntry = ""
        persist()
    }

    func deleteEntries(at offsets: IndexSet) {
        domains.remove(atOffsets: offsets)
        persist()
    }

    private func load() {
        guard let store else {
            message = Self.storeUnavailableMessage
            return
        }

        let configuration = (try? store.load()) ?? .default
        domains = configuration.domainWhitelist
        bypassCNIP = configuration.bypassCNIP
        message = Self.changeHintMessage
    }

    private func persist() {
        let configuration = RoutingConfiguration(
            bypassCNIP: bypassCNIP,
            domainWhitelist: domains
        )

        do {
            try store?.save(configuration)
        } catch {
            message = "白名单保存失败：\(error.localizedDescription)"
        }
    }
}
