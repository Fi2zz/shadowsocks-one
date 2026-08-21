import Foundation

/// 服务端 → 客户端方向的发送侧拥塞控制（慢启动 + 拥塞避免）：
/// 限制在途未 ACK 字节数，TUN 写丢失或弱网时避免向客户端无界重发；
/// 超时重传视为丢包信号，阈值折半、窗口退回慢启动。
struct TCPCongestionController: Equatable, Sendable {
    static let segmentSizeBytes = 1_460
    /// RFC 6928 初始窗口：10 个 MSS
    static let initialWindowBytes = 10 * segmentSizeBytes
    static let minimumWindowBytes = segmentSizeBytes

    private(set) var windowBytes: Int
    private var slowStartThresholdBytes: Int

    init(
        windowBytes: Int = Self.initialWindowBytes,
        slowStartThresholdBytes: Int = TCPFlowWindow.outboundCapacityBytes
    ) {
        self.windowBytes = windowBytes
        self.slowStartThresholdBytes = slowStartThresholdBytes
    }

    /// 当前还允许新写入 TUN 的字节数
    func allowance(inFlightBytes: Int) -> Int {
        max(windowBytes - inFlightBytes, 0)
    }

    /// 每个有效 ACK：慢启动阶段 +1 MSS，拥塞避免阶段 +MSS²/cwnd
    mutating func noteAcknowledgment() {
        guard windowBytes >= slowStartThresholdBytes else {
            windowBytes += Self.segmentSizeBytes
            return
        }
        windowBytes += Self.segmentSizeBytes * Self.segmentSizeBytes / windowBytes
    }

    /// 丢包（段进入超时重传）：阈值折半，窗口退回 1 MSS 重新慢启动
    mutating func noteLoss() {
        slowStartThresholdBytes = max(windowBytes / 2, 2 * Self.segmentSizeBytes)
        windowBytes = Self.minimumWindowBytes
    }
}
