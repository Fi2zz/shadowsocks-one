import Foundation

protocol TCPFlowRelaying: AnyObject {
    var onInboundBytes: (@Sendable (Data) async -> Void)? { get set }
    var onClosed: (@Sendable () async -> Void)? { get set }
    func start() async throws
    func forwardOutboundPayload(_ payload: Data) async throws
    func stop() async
}
