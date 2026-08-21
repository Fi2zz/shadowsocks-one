import Foundation

protocol TCPFlowRelaying: AnyObject {
    var onInboundBytes: (@Sendable (Data) async -> Void)? { get set }
    var onClosed: (@Sendable () async -> Void)? { get set }
    /// 客户端 → 服务端方向已在 relay 排队、尚未发出的字节数
    var queuedOutboundBytes: Int { get }
    func start() async throws
    func forwardOutboundPayload(_ payload: Data) async throws
    func stop() async
}

/// 通告窗口策略：客户端 → 隧道方向的在途字节越接近容量，通告窗口越小，
/// 防止高速发送方在 relay 发送队列里堆积打爆内存
enum TCPFlowWindow {
    static let outboundCapacityBytes = 256 * 1024
    static let maximumAdvertised: UInt16 = 0xFFFF

    static func advertised(queuedOutboundBytes: Int) -> UInt16 {
        let remaining = outboundCapacityBytes - queuedOutboundBytes
        return UInt16(clamping: max(remaining, 0))
    }
}
