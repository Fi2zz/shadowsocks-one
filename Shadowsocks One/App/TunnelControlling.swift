import SharedCore

@MainActor
protocol TunnelControlling: AnyObject {
    var state: ConnectionState { get }
    var stateStream: AsyncStream<ConnectionState> { get }

    func prepare() async
    func connect() async throws
    func disconnect()
    func refreshStatus()
}
