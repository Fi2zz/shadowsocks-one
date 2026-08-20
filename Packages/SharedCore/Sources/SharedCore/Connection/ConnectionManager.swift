import Foundation

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
    private let probeClient: any ShadowsocksProbing
    private let probeTarget: ConnectionProbeTarget
    private let healthCheckNanoseconds: UInt64
    private let reconnectNanoseconds: UInt64
    private var shouldStayConnected = false
    private var loopTask: Task<Void, Never>?

    public init(
        probeClient: any ShadowsocksProbing = ShadowsocksProbeClient(),
        probeTarget: ConnectionProbeTarget = .default,
        healthCheckNanoseconds: UInt64 = 15_000_000_000,
        reconnectNanoseconds: UInt64 = 3_000_000_000
    ) {
        self.probeClient = probeClient
        self.probeTarget = probeTarget
        self.healthCheckNanoseconds = healthCheckNanoseconds
        self.reconnectNanoseconds = reconnectNanoseconds
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

        shouldStayConnected = true
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            await self?.runConnectionLoop(config: config)
        }
    }

    public func disconnect() async {
        shouldStayConnected = false
        loopTask?.cancel()
        loopTask = nil
        update(.idle)
    }

    private func runConnectionLoop(config: ConnectionConfig) async {
        while shouldStayConnected && !Task.isCancelled {
            update(.connecting)

            do {
                try await probeClient.probe(using: config, target: probeTarget)
                guard shouldStayConnected else { break }
                update(.connected)
                try await Task.sleep(nanoseconds: healthCheckNanoseconds)
            } catch is CancellationError {
                return
            } catch {
                guard shouldStayConnected else { break }
                update(.failed(error.localizedDescription))

                do {
                    try await Task.sleep(nanoseconds: reconnectNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    private func update(_ newState: ConnectionState) {
        state = newState
        stateContinuation.yield(newState)
    }
}
