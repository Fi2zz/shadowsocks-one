import Foundation
@preconcurrency import NetworkExtension
import SharedCore

@MainActor
final class SystemTunnelManager {
    private let providerBundleIdentifier: String
    private(set) var state: ConnectionState = .idle
    let stateStream: AsyncStream<ConnectionState>
    private let stateContinuation: AsyncStream<ConnectionState>.Continuation
    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    init(providerBundleIdentifier: String) {
        self.providerBundleIdentifier = providerBundleIdentifier

        var capturedContinuation: AsyncStream<ConnectionState>.Continuation?
        self.stateStream = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.stateContinuation = capturedContinuation!
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    func prepare() async {
        do {
            let manager = try await loadOrCreateManager()
            self.manager = manager
            installStatusObserver(for: manager)
            updateState(mapStatus(manager.connection.status))
        } catch {
            updateState(.failed(error.localizedDescription))
        }
    }

    func connect() async throws {
        let manager = try await loadOrCreateManager()
        self.manager = manager
        installStatusObserver(for: manager)

        guard let session = manager.connection as? NETunnelProviderSession else {
            let error = TunnelManagerError.invalidSession
            updateState(.failed(error.localizedDescription))
            throw error
        }

        updateState(.connecting)

        do {
            try session.startTunnel()
            updateState(mapStatus(manager.connection.status))
        } catch {
            updateState(.failed(error.localizedDescription))
            throw error
        }
    }

    func disconnect() {
        manager?.connection.stopVPNTunnel()
        if let manager {
            updateState(mapStatus(manager.connection.status))
        } else {
            updateState(.idle)
        }
    }

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        let managers = try await loadAllManagers()
        let manager = managers.first ?? NETunnelProviderManager()
        configure(manager)
        try await save(manager)
        try await load(manager)
        return manager
    }

    private func configure(_ manager: NETunnelProviderManager) {
        let providerProtocol = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        providerProtocol.providerBundleIdentifier = providerBundleIdentifier
        providerProtocol.serverAddress = "Shadowsocks One"
        providerProtocol.providerConfiguration = [
            "configurationSource": "app-group",
        ]
        providerProtocol.disconnectOnSleep = false

        manager.localizedDescription = "Shadowsocks One"
        manager.protocolConfiguration = providerProtocol
        manager.isEnabled = true
    }

    private func installStatusObserver(for manager: NETunnelProviderManager) {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }

        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateState(self.mapStatus(manager.connection.status))
            }
        }
    }

    private func updateState(_ newState: ConnectionState) {
        state = newState
        stateContinuation.yield(newState)
    }

    private func mapStatus(_ status: NEVPNStatus) -> ConnectionState {
        switch status {
        case .connected:
            return .connected
        case .connecting, .reasserting, .disconnecting:
            return .connecting
        case .disconnected, .invalid:
            return .idle
        @unknown default:
            return .failed("未知的 Tunnel 状态。")
        }
    }

    private func loadAllManagers() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: managers ?? [])
            }
        }
    }

    private func save(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: ())
            }
        }
    }

    private func load(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: ())
            }
        }
    }
}

private enum TunnelManagerError: LocalizedError {
    case invalidSession

    var errorDescription: String? {
        switch self {
        case .invalidSession:
            return "无法创建 Packet Tunnel 会话。"
        }
    }
}
