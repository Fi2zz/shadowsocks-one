import Foundation
import SharedCore

final class ShadowsocksTCPRelay: TCPFlowRelaying {
    private let transport: ShadowsocksTCPTransport
    private var receiveTask: Task<Void, Never>?
    var onInboundBytes: (@Sendable (Data) async -> Void)?
    var onClosed: (@Sendable () async -> Void)?

    init(
        launchConfiguration: TunnelLaunchConfiguration,
        destinationHost: String,
        destinationPort: UInt16
    ) throws {
        self.transport = try ShadowsocksTCPTransport(
            config: launchConfiguration.connection,
            destinationHost: destinationHost,
            destinationPort: destinationPort
        )
    }

    func start() async throws {
        try await transport.start()
        guard receiveTask == nil else {
            return
        }

        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }
    }

    func forwardOutboundPayload(_ payload: Data) async throws {
        try await transport.send(payload)
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

                for payload in payloads where !payload.isEmpty {
                    await onInboundBytes?(payload)
                }
            } catch {
                break
            }
        }

        await onClosed?()
    }
}
