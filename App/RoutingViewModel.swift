import Foundation
import SharedCore

enum RouteListKind {
    case direct
    case proxy
}

@MainActor
final class RoutingViewModel: ObservableObject {
    private static let storeUnavailableMessage = "路由配置存储不可用，本次修改仅在当前会话有效。"

    @Published private(set) var directDomains: [String] = []
    @Published private(set) var proxyDomains: [String] = []
    @Published private(set) var directByDefault = false
    @Published private(set) var bypassCNIP = false
    @Published var directEntry = ""
    @Published var proxyEntry = ""
    @Published private(set) var message: String?

    private let store: RoutingConfigurationStore?

    init(store: RoutingConfigurationStore?) {
        self.store = store
        load()
    }

    static func makeDefault() -> RoutingViewModel {
        RoutingViewModel(
            store: try? RoutingConfigurationStore(
                appGroupID: SharedContainerSettings.appGroupID
            )
        )
    }

    func domains(for kind: RouteListKind) -> [String] {
        kind == .direct ? directDomains : proxyDomains
    }

    func addEntry(for kind: RouteListKind) {
        let rawEntry = kind == .direct ? directEntry : proxyEntry
        let entry = Self.normalizeEntry(rawEntry)
        guard !entry.isEmpty, !domains(for: kind).contains(entry) else {
            return
        }

        if kind == .direct {
            directDomains.append(entry)
            directEntry = ""
        } else {
            proxyDomains.append(entry)
            proxyEntry = ""
        }
        persist()
    }

    func deleteEntries(at offsets: IndexSet, for kind: RouteListKind) {
        if kind == .direct {
            directDomains.remove(atOffsets: offsets)
        } else {
            proxyDomains.remove(atOffsets: offsets)
        }
        persist()
    }

    func setDirectByDefault(_ enabled: Bool) {
        directByDefault = enabled
        persist()
    }

    func setBypassCNIP(_ enabled: Bool) {
        bypassCNIP = enabled
        persist()
    }

    private func load() {
        guard let store else {
            message = Self.storeUnavailableMessage
            return
        }

        let configuration = (try? store.load()) ?? .default
        directDomains = configuration.domainWhitelist
        proxyDomains = configuration.proxyDomains
        directByDefault = configuration.directByDefault
        bypassCNIP = configuration.bypassCNIP
    }

    private func persist() {
        let configuration = RoutingConfiguration(
            bypassCNIP: bypassCNIP,
            domainWhitelist: directDomains,
            proxyDomains: proxyDomains,
            directByDefault: directByDefault
        )

        do {
            try store?.save(configuration)
        } catch {
            message = "路由配置保存失败：\(error.localizedDescription)"
        }
    }

    private static func normalizeEntry(_ entry: String) -> String {
        entry
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }
}
