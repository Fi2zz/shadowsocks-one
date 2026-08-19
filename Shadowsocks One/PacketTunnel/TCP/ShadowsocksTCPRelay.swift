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
        // #region debug-point E:proxy-relay-start
        TunnelDebugReporter.send(
            "E",
            location: "ShadowsocksTCPRelay.start",
            message: "starting proxy relay"
        )
        // #endregion
        try await transport.start()
        guard receiveTask == nil else {
            return
        }

        // #region debug-point E:proxy-relay-ready
        TunnelDebugReporter.send(
            "E",
            location: "ShadowsocksTCPRelay.start",
            message: "proxy relay ready"
        )
        // #endregion
        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }
    }

    func forwardOutboundPayload(_ payload: Data) async throws {
        // #region debug-point E:proxy-relay-send
        TunnelDebugReporter.send(
            "E",
            location: "ShadowsocksTCPRelay.forwardOutboundPayload",
            message: "sending payload over proxy relay",
            data: ["payloadBytes": payload.count]
        )
        // #endregion
        do {
            try await transport.send(payload)
            // #region debug-point E:proxy-relay-send-finished
            TunnelDebugReporter.send(
                "E",
                location: "ShadowsocksTCPRelay.forwardOutboundPayload",
                message: "finished sending payload over proxy relay",
                data: ["payloadBytes": payload.count]
            )
            // #endregion
        } catch {
            // #region debug-point E:proxy-relay-send-failed
            TunnelDebugReporter.send(
                "E",
                location: "ShadowsocksTCPRelay.forwardOutboundPayload",
                message: "failed sending payload over proxy relay",
                data: [
                    "payloadBytes": payload.count,
                    "error": error.localizedDescription,
                ]
            )
            // #endregion
            throw error
        }
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
