import Foundation
import XCTest
import SharedCore
@testable import ShadowsocksBrowser

@MainActor
final class RootViewModelSystemTunnelTests: XCTestCase {
    func testConnectSelectedProfileUsesSystemTunnelController() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let tunnelController = TunnelControllerSpy()
        let viewModel = RootViewModel(
            parser: ParserStub(profile: .fixture()),
            tunnelController: tunnelController,
            storeBuilder: {
                try ProfileStore(
                    localDirectory: tempDirectory,
                    keychainService: UUID().uuidString
                )
            },
            tunnelStoreBuilder: {
                throw DummyError.disabled
            }
        )

        viewModel.rawURL = "ss://demo"
        viewModel.importProfile()
        viewModel.connectSelectedProfile()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(tunnelController.connectCalls, 1)
    }

    func testTunnelStateStreamUpdatesConnectionState() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let tunnelController = TunnelControllerSpy()
        let viewModel = RootViewModel(
            parser: ParserStub(profile: .fixture()),
            tunnelController: tunnelController,
            storeBuilder: {
                try ProfileStore(
                    localDirectory: tempDirectory,
                    keychainService: UUID().uuidString
                )
            },
            tunnelStoreBuilder: {
                throw DummyError.disabled
            }
        )

        tunnelController.send(.connecting)
        try await assertEventually(viewModel.connectionState, equals: .connecting)

        tunnelController.send(.connected)
        try await assertEventually(viewModel.connectionState, equals: .connected)
    }

    func testFailedTunnelStateShowsErrorMessage() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let tunnelController = TunnelControllerSpy()
        let viewModel = RootViewModel(
            parser: ParserStub(profile: .fixture()),
            tunnelController: tunnelController,
            storeBuilder: {
                try ProfileStore(
                    localDirectory: tempDirectory,
                    keychainService: UUID().uuidString
                )
            },
            tunnelStoreBuilder: {
                throw DummyError.disabled
            }
        )

        tunnelController.send(.failed("permission denied"))

        try await assertEventually(viewModel.message, equals: "系统 VPN 启动失败：permission denied")
    }

    func testConnectFailureShowsSystemVPNError() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let tunnelController = FailingTunnelControllerSpy()
        let viewModel = RootViewModel(
            parser: ParserStub(profile: .fixture()),
            tunnelController: tunnelController,
            storeBuilder: {
                try ProfileStore(
                    localDirectory: tempDirectory,
                    keychainService: UUID().uuidString
                )
            },
            tunnelStoreBuilder: {
                throw DummyError.disabled
            }
        )

        viewModel.rawURL = "ss://demo"
        viewModel.importProfile()
        viewModel.connectSelectedProfile()

        try await assertEventually(viewModel.message, equals: "系统 VPN 启动失败：permission denied")
    }

    private func assertEventually<Value: Equatable>(
        _ expression: @autoclosure () -> Value,
        equals expected: Value,
        timeoutNanoseconds: UInt64 = 1_000_000_000
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if expression() == expected {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(expression(), expected)
    }
}

private enum DummyError: Error {
    case disabled
}

private struct ParserStub: SSURLParsing {
    let profile: ServerProfile

    func parse(_ raw: String) throws -> ServerProfile {
        profile
    }
}

private struct DummyLocalizedError: LocalizedError {
    let errorDescription: String?
}

@MainActor
private final class TunnelControllerSpy: TunnelControlling {
    private(set) var prepareCalls = 0
    private(set) var connectCalls = 0
    private(set) var disconnectCalls = 0
    private(set) var state: ConnectionState = .idle
    let stateStream: AsyncStream<ConnectionState>
    private let continuation: AsyncStream<ConnectionState>.Continuation

    init() {
        var capturedContinuation: AsyncStream<ConnectionState>.Continuation?
        stateStream = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation!
    }

    func prepare() async {
        prepareCalls += 1
    }

    func connect() async throws {
        connectCalls += 1
    }

    func disconnect() {
        disconnectCalls += 1
    }

    func refreshStatus() {}

    func send(_ newState: ConnectionState) {
        state = newState
        continuation.yield(newState)
    }
}

@MainActor
private final class FailingTunnelControllerSpy: TunnelControlling {
    let stateStream: AsyncStream<ConnectionState> = AsyncStream { _ in }
    var state: ConnectionState = .idle

    func prepare() async {}

    func connect() async throws {
        throw DummyLocalizedError(errorDescription: "permission denied")
    }

    func disconnect() {}

    func refreshStatus() {}
}

private extension ServerProfile {
    static func fixture() -> ServerProfile {
        ServerProfile(
            host: "1.2.3.4",
            port: 8388,
            method: .aes128GCM,
            password: "pass",
            remark: "demo"
        )
    }
}
