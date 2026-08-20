import Foundation
import SharedCore

final class ShadowsocksTCPRelay: TCPFlowRelaying {
    private let transport: ShadowsocksTCPTransport
    private var receiveTask: Task<Void, Never>?
    private var sendChain: Task<Void, Error>?
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
        guard receiveTask == nil else {
            return
        }

        // #region debug-point E:proxy-relay-start
        TunnelDebugReporter.send(
            "E",
            location: "ShadowsocksTCPRelay.start",
            message: "starting proxy relay"
        )
        // #endregion
        receiveTask = Task { [weak self] in
            do {
                try await self?.transport.start()
                try await self?.transport.waitUntilReady()
            } catch {
                // #region debug-point E:proxy-relay-start-failed
                TunnelDebugReporter.send(
                    "E",
                    location: "ShadowsocksTCPRelay.start",
                    message: "proxy relay connect failed",
                    data: ["error": error.localizedDescription]
                )
                // #endregion
                await self?.onClosed?()
                return
            }

            // #region debug-point E:proxy-relay-ready
            TunnelDebugReporter.send(
                "E",
                location: "ShadowsocksTCPRelay.start",
                message: "proxy relay ready"
            )
            // #endregion
            await self?.runReceiveLoop()
        }
    }

    func forwardOutboundPayload(_ payload: Data) async throws {
        // #region debug-point E:proxy-relay-send
        TunnelDebugReporter.send(
            "E",
            location: "ShadowsocksTCPRelay.forwardOutboundPayload",
            message: "queueing payload for proxy relay",
            data: ["payloadBytes": payload.count]
        )
        // #endregion
        let prior = sendChain
        let task = Task { [weak self] in
            try await prior?.value
            try await self?.transport.send(payload)
        }
        sendChain = task
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
                    // #region debug-point E:proxy-relay-receive-empty
                    TunnelDebugReporter.send(
                        "E",
                        location: "ShadowsocksTCPRelay.runReceiveLoop",
                        message: "proxy relay receive returned empty payload batch"
                    )
                    // #endregion
                    break
                }

                // #region debug-point E:proxy-relay-receive-batch
                TunnelDebugReporter.send(
                    "E",
                    location: "ShadowsocksTCPRelay.runReceiveLoop",
                    message: "proxy relay received payload batch",
                    data: ["payloadCount": payloads.count]
                )
                // #endregion
                for payload in payloads where !payload.isEmpty {
                    // #region debug-point E:proxy-relay-receive
                    TunnelDebugReporter.send(
                        "E",
                        location: "ShadowsocksTCPRelay.runReceiveLoop",
                        message: "proxy relay received payload",
                        data: ["payloadBytes": payload.count]
                    )
                    // #endregion
                    await onInboundBytes?(payload)
                }
            } catch {
                // #region debug-point E:proxy-relay-receive-failed
                TunnelDebugReporter.send(
                    "E",
                    location: "ShadowsocksTCPRelay.runReceiveLoop",
                    message: "proxy relay receive loop failed",
                    data: ["error": error.localizedDescription]
                )
                // #endregion
                break
            }
        }

        // #region debug-point E:proxy-relay-closed
        TunnelDebugReporter.send(
            "E",
            location: "ShadowsocksTCPRelay.runReceiveLoop",
            message: "proxy relay receive loop closed"
        )
        // #endregion
        await onClosed?()
    }
}
