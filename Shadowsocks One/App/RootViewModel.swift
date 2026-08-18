import Foundation
import SharedCore

@MainActor
final class RootViewModel: ObservableObject {
    @Published var rawURL = ""
    @Published private(set) var profiles: [ServerProfile] = []
    @Published var selectedProfileID: UUID?
    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var message: String?

    private let parser: any SSURLParsing
    private let connectionManager: ConnectionManager
    private let store: ProfileStore?
    private var stateTask: Task<Void, Never>?

    init(
        parser: any SSURLParsing,
        connectionManager: ConnectionManager,
        storeBuilder: () throws -> ProfileStore
    ) {
        self.parser = parser
        self.connectionManager = connectionManager
        self.store = try? storeBuilder()
        self.message = store == nil ? "ProfileStore 初始化失败，请检查 App Group 配置。" : nil
        reloadProfiles()
        observeConnectionState()
    }

    deinit {
        stateTask?.cancel()
    }

    static func makeDefault() -> RootViewModel {
        RootViewModel(
            parser: SSURLParser(),
            connectionManager: ConnectionManager(),
            storeBuilder: {
                try ProfileStore(
                    appGroupID: AppConstants.appGroupID,
                    keychainService: AppConstants.keychainService
                )
            }
        )
    }

    var selectedProfile: ServerProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    func importProfile() {
        guard let store else { return }
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            message = "请输入 ss:// 节点。"
            return
        }

        do {
            let profile = try parser.parse(trimmed)
            profiles.insert(profile, at: 0)
            try store.saveProfiles(profiles)
            selectProfile(id: profile.id)
            rawURL = ""
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func selectProfile(id: UUID) {
        selectedProfileID = id
        store?.saveSelectedProfileID(id)
    }

    func connectSelectedProfile() {
        guard let selectedProfile else {
            message = "请先选择一个节点。"
            return
        }

        message = nil
        let config = ConnectionConfig(profile: selectedProfile)
        Task {
            await connectionManager.connect(using: config, plugin: selectedProfile.plugin)
        }
    }

    func disconnect() {
        Task {
            await connectionManager.disconnect()
        }
    }

    private func reloadProfiles() {
        guard let store else { return }

        do {
            profiles = try store.loadProfiles()
            selectedProfileID = store.loadSelectedProfileID() ?? profiles.first?.id
        } catch {
            message = "读取节点失败：\(error.localizedDescription)"
        }
    }

    private func observeConnectionState() {
        stateTask = Task {
            let stream = await connectionManager.stateStream
            for await state in stream {
                connectionState = state
            }
        }
    }
}
