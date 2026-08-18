import Foundation
import Network

public protocol ConnectionManaging: Actor {
    var state: ConnectionState { get }
    var stateStream: AsyncStream<ConnectionState> { get }
    func connect(using config: ConnectionConfig, plugin: String?) async
    func disconnect() async
}

public actor ConnectionManager: ConnectionManaging {
    public private(set) var state: ConnectionState = .idle
    public let stateStream: AsyncStream<ConnectionState>
    private let stateContinuation: AsyncStream<ConnectionState>.Continuation

    public init() {
        var capturedContinuation: AsyncStream<ConnectionState>.Continuation?
        self.stateStream = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.stateContinuation = capturedContinuation!
    }

    public func connect(using config: ConnectionConfig, plugin: String? = nil) async {
        if plugin != nil {
            update(.failed("当前版本暂不支持 plugin 节点连接"))
            return
        }

        update(.connecting)

        let endpoint = NWEndpoint.Host(config.host)
        guard let port = NWEndpoint.Port(rawValue: config.port) else {
            update(.failed("无效端口"))
            return
        }

        let connection = NWConnection(host: endpoint, port: port, using: .tcp)
        await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { [weak self] newState in
                switch newState {
                case .ready:
                    let payload = Data("ping".utf8)
                    connection.send(content: payload, completion: .contentProcessed { _ in })
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                        Task {
                            if data == payload {
                                await self?.update(.connected)
                            } else {
                                await self?.update(.failed("AEAD 往返失败"))
                            }
                            continuation.resume()
                        }
                    }
                case .failed(let error):
                    Task {
                        await self?.update(.failed(error.localizedDescription))
                        continuation.resume()
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    public func disconnect() async {
        update(.idle)
    }

    private func update(_ newState: ConnectionState) {
        state = newState
        stateContinuation.yield(newState)
    }
}
