import Foundation
import SharedCore

final class ShadowsocksUDPRelay: UDPFlowRelaying {
    private let transport: ShadowsocksUDPTransport
    private let destinationHost: String
    private let destinationPort: UInt16
    private var receiveTask: Task<Void, Never>?
    var onInboundDatagram: (@Sendable (Data) async -> Void)?
    var onClosed: (@Sendable () async -> Void)?

    init(
        launchConfiguration: TunnelLaunchConfiguration,
        destinationHost: String,
        destinationPort: UInt16
    ) throws {
        self.transport = try ShadowsocksUDPTransport(config: launchConfiguration.connection)
        self.destinationHost = destinationHost
        self.destinationPort = destinationPort
    }

    func start() async throws {
        guard receiveTask == nil else {
            return
        }

        try await transport.start()
        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }
    }

    func forwardOutboundPayload(_ payload: Data) async throws {
        guard !payload.isEmpty else {
            return
        }

        try await transport.send(
            payload: payload,
            toHost: destinationHost,
            port: destinationPort
        )
    }

    func stop() async {
        receiveTask?.cancel()
        receiveTask = nil
        transport.stop()
    }

    private func runReceiveLoop() async {
        while !Task.isCancelled {
            do {
                let datagram = try await transport.receive()
                await onInboundDatagram?(datagram.payload)
            } catch {
                break
            }
        }

        await onClosed?()
    }
}
