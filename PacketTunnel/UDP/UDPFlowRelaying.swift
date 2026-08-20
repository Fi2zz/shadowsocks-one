import Foundation

protocol UDPFlowRelaying: AnyObject {
    var onInboundDatagram: (@Sendable (Data) async -> Void)? { get set }
    var onClosed: (@Sendable () async -> Void)? { get set }
    func start() async throws
    func forwardOutboundPayload(_ payload: Data) async throws
    func stop() async
}
