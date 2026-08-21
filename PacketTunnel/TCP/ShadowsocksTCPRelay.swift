import Foundation
import SharedCore

final class ShadowsocksTCPRelay: TCPFlowRelaying {
    private let transport: ShadowsocksTCPTransport
    private let endpoint: String
    private let diagnostics: TunnelDiagnosticsLogging?
    private var receiveTask: Task<Void, Never>?
    private var sendChain: Task<Void, Error>?
    private var firstReceiveLogged = false
    private let queueLock = NSLock()
    private var queuedBytes = 0
    var onInboundBytes: (@Sendable (Data) async -> Void)?
    var onClosed: (@Sendable () async -> Void)?

    var queuedOutboundBytes: Int {
        queueLock.withLock { queuedBytes }
    }

    init(
        launchConfiguration: TunnelLaunchConfiguration,
        destinationHost: String,
        destinationPort: UInt16,
        diagnostics: TunnelDiagnosticsLogging? = nil
    ) throws {
        self.transport = try ShadowsocksTCPTransport(
            config: launchConfiguration.connection,
            destinationHost: destinationHost,
            destinationPort: destinationPort
        )
        self.endpoint = "\(destinationHost):\(destinationPort)"
        self.diagnostics = diagnostics
    }

    func start() async throws {
        guard receiveTask == nil else {
            return
        }

        receiveTask = Task { [weak self] in
            do {
                try await self?.transport.start()
                try await self?.transport.waitUntilReady()
                self?.diagnostics?("PROXY \(self?.endpoint ?? "?") ready")
            } catch {
                self?.diagnostics?("PROXY \(self?.endpoint ?? "?") connect failed: \(error.localizedDescription)")
                await self?.onClosed?()
                return
            }

            await self?.runReceiveLoop()
        }
    }

    func forwardOutboundPayload(_ payload: Data) async throws {
        let prior = sendChain
        adjustQueuedBytes(by: payload.count)
        let task = Task { [weak self] in
            defer { self?.adjustQueuedBytes(by: -payload.count) }
            try await prior?.value
            try await self?.transport.send(payload)
        }
        sendChain = task
    }

    private func adjustQueuedBytes(by delta: Int) {
        queueLock.withLock { queuedBytes += delta }
    }

    func stop() async {
        receiveTask?.cancel()
        receiveTask = nil
        transport.stop()
    }

    private func runReceiveLoop() async {
        while !Task.isCancelled {
            do {
                let payloads = try await transport.receivePayloads()
                if payloads.isEmpty {
                    break
                }

                logFirstReceive(payloads)
                for payload in payloads where !payload.isEmpty {
                    await onInboundBytes?(payload)
                }
            } catch {
                diagnostics?("PROXY \(endpoint) recv error: \(error.localizedDescription)")
                break
            }
        }

        diagnostics?("PROXY \(endpoint) closed")
        await onClosed?()
    }

    private func logFirstReceive(_ payloads: [Data]) {
        guard !firstReceiveLogged, let first = payloads.first else {
            return
        }

        firstReceiveLogged = true
        diagnostics?("PROXY \(endpoint) recv \(first.count)B")
    }
}
