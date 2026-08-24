import Foundation
import SharedCore

@MainActor
final class RootViewModel: ObservableObject {
    private static let localStoreUnavailableMessage = "本地存储初始化失败，本次导入仅在当前会话可用。"
    private static let tunnelUnavailableMessage = "系统级代理共享存储未就绪，仍可继续 App 内直连。"
    private static let tunnelReadyMessage = "系统 VPN 已就绪，首次连接时会触发系统授权。"

    @Published var rawURL = ""
    @Published private(set) var profiles: [ServerProfile] = []
    @Published var selectedProfileID: UUID?
    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var message: String?

    private let parser: any SSURLParsing
    private let tunnelController: any TunnelControlling
    let hudunTunnels: HudunTunnelCoordinator
    private let store: ProfileStore?
    private let tunnelStore: TunnelConfigurationStore?
    private var stateTask: Task<Void, Never>?

    init(
        parser: any SSURLParsing,
        tunnelController: any TunnelControlling,
        storeBuilder: () throws -> ProfileStore,
        tunnelStoreBuilder: () throws -> TunnelConfigurationStore
    ) {
        self.parser = parser
        self.tunnelController = tunnelController
        self.hudunTunnels = HudunTunnelCoordinator(controller: tunnelController)
        self.store = try? storeBuilder()
        self.tunnelStore = try? tunnelStoreBuilder()
        self.connectionState = tunnelController.state
        refreshInformationalMessage()
        reloadProfiles()
        observeTunnelState()
        Task {
            await tunnelController.prepare()
        }
    }

    deinit {
        stateTask?.cancel()
    }

    static func makeDefault() -> RootViewModel {
        RootViewModel(
            parser: SSURLParser(),
            tunnelController: SystemTunnelManager(
                providerBundleIdentifier: "com.fits.socks.one.PacketTunnel"
            ),
            storeBuilder: {
                try makeProfileStore()
            },
            tunnelStoreBuilder: {
                try TunnelConfigurationStore(
                    appGroupID: SharedContainerSettings.appGroupID,
                    keychainService: SharedContainerSettings.keychainService
                )
            }
        )
    }

    var selectedProfile: ServerProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    func importProfile() {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            message = "请输入 ss:// 节点。"
            return
        }

        do {
            let profile = try parser.parse(trimmed)
            profiles.insert(profile, at: 0)
            try store?.saveProfiles(profiles)
            selectProfile(id: profile.id)
            rawURL = ""
            refreshInformationalMessage()
        } catch {
            message = error.localizedDescription
        }
    }

    func selectProfile(id: UUID) {
        selectedProfileID = id
        store?.saveSelectedProfileID(id)

        guard let profile = profiles.first(where: { $0.id == id }) else {
            return
        }

        do {
            try tunnelStore?.save(profile: profile)
            refreshInformationalMessage()
        } catch {
            message = Self.tunnelUnavailableMessage
        }
    }

    func connectSelectedProfile() {
        guard let selectedProfile else {
            message = "请先选择一个节点。"
            return
        }

        Task {
            do {
                try tunnelStore?.save(profile: selectedProfile)
                await MainActor.run {
                    refreshInformationalMessage()
                }
                try await tunnelController.connect()
            } catch {
                await MainActor.run {
                    message = "系统 VPN 启动失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func disconnect() {
        tunnelController.disconnect()
    }

    func refreshTunnelStatus() {
        tunnelController.refreshStatus()
    }

    func deleteProfile(id: UUID) {
        do {
            try store?.deleteProfile(id: id, from: profiles)
            profiles.removeAll { $0.id == id }
            clearSelectionIfNeeded(deletedProfileID: id)
            refreshInformationalMessage()
        } catch {
            message = "删除节点失败：\(error.localizedDescription)"
        }
    }

    private func clearSelectionIfNeeded(deletedProfileID id: UUID) {
        guard selectedProfileID == id else {
            return
        }

        guard let fallbackID = profiles.first?.id else {
            selectedProfileID = nil
            store?.saveSelectedProfileID(nil)
            try? tunnelStore?.clear()
            return
        }
        selectProfile(id: fallbackID)
    }

    private func reloadProfiles() {
        guard let store else {
            refreshInformationalMessage()
            return
        }

        do {
            profiles = try store.loadProfiles()
            selectedProfileID = store.loadSelectedProfileID() ?? profiles.first?.id
            if let selectedProfileID {
                selectProfile(id: selectedProfileID)
            } else {
                try tunnelStore?.clear()
                refreshInformationalMessage()
            }
        } catch {
            message = "读取节点失败：\(error.localizedDescription)"
        }
    }

    private func observeTunnelState() {
        stateTask = Task {
            let stream = tunnelController.stateStream
            for await state in stream {
                connectionState = state
                if case let .failed(detail) = state {
                    message = "系统 VPN 启动失败：\(detail)"
                } else {
                    refreshInformationalMessage()
                }
            }
        }
    }

    private func refreshInformationalMessage() {
        if store == nil {
            message = Self.localStoreUnavailableMessage
        } else if tunnelStore == nil {
            message = Self.tunnelUnavailableMessage
        } else {
            message = Self.tunnelReadyMessage
        }
    }

    private static func appProfileStoreDirectory() -> URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return baseURL.appendingPathComponent("ShadowsocksOne", isDirectory: true)
    }

    private static func makeProfileStore() throws -> ProfileStore {
        do {
            return try ProfileStore(
                localDirectory: appProfileStoreDirectory(),
                keychainService: SharedContainerSettings.keychainService
            )
        } catch {
            return try ProfileStore(
                localDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("ShadowsocksOne", isDirectory: true),
                keychainService: SharedContainerSettings.keychainService
            )
        }
    }
}
