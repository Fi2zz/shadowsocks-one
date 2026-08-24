import Foundation
import Network

/// WireGuard UDP 通道（对端 endpoint，含异步收发）。
final class WireGuardUDPChannel {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "hudun.wg.udp")

    init(host: String, port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 51820,
            using: .udp)
    }

    func start() {
        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                NSLog("WireGuardUDPChannel failed: %@", String(describing: error))
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
    }

    func send(_ datagram: Data) {
        connection.send(content: datagram, completion: .contentProcessed { _ in })
    }

    /// 单次接收；EOF/错误返回 nil。
    func receive() async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receiveMessage { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
