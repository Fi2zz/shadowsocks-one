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
    @Published private(set) var bypassCNIP = false
    @Published var directEntry = ""
    @Published var proxyEntry = ""
    @Published private(set) var message: String?
    @Published private(set) var testResults: [String: DomainRouteTestResult] = [:]
    @Published private(set) var testingDomains: Set<String> = []

    typealias RouteTestHandler = (
        String, RoutingConfiguration, CNIPRangeList
    ) async -> DomainRouteTestResult

    private let store: RoutingConfigurationStore?
    private let cnIPRanges: CNIPRangeList
    private let routeTestHandler: RouteTestHandler

    init(
        store: RoutingConfigurationStore?,
        cnIPRanges: CNIPRangeList = .empty,
        routeTestHandler: RouteTestHandler? = nil
    ) {
        self.store = store
        self.cnIPRanges = cnIPRanges
        self.routeTestHandler = routeTestHandler ?? DomainRouteTester().test
        load()
    }

    static func makeDefault() -> RoutingViewModel {
        let groupID = SharedContainerSettings.appGroupID
        let downloaded = try? CNIPListStore(appGroupID: groupID).load()
        let ranges = downloaded.flatMap { try? CNIPRangeList(textContent: $0) } ?? .empty
        return RoutingViewModel(
            store: try? RoutingConfigurationStore(appGroupID: groupID),
            cnIPRanges: ranges
        )
    }

    func testConnection(for domain: String) async {
        testingDomains.insert(domain)
        defer { testingDomains.remove(domain) }

        let configuration = RoutingConfiguration(
            bypassCNIP: bypassCNIP,
            domainWhitelist: directDomains,
            proxyDomains: proxyDomains
        )
        testResults[domain] = await routeTestHandler(domain, configuration, cnIPRanges)
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
        bypassCNIP = configuration.bypassCNIP
    }

    private func persist() {
        let configuration = RoutingConfiguration(
            bypassCNIP: bypassCNIP,
            domainWhitelist: directDomains,
            proxyDomains: proxyDomains
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
