import Foundation

/// RTT 估计器（Jacobson/Karn）：用平滑 RTT 与偏差算动态 RTO，
/// 替换固定 RTO，让重传节奏随实际链路质量伸缩。
struct RTTEstimator: Equatable, Sendable {
    let minimumRTO: TimeInterval
    let maximumRTO: TimeInterval
    private let initialRTO: TimeInterval
    private var smoothedRTT: TimeInterval?
    private var rttVariance: TimeInterval = 0

    init(
        initialRTO: TimeInterval = 1.0,
        minimumRTO: TimeInterval = 0.2,
        maximumRTO: TimeInterval = 8.0
    ) {
        self.initialRTO = initialRTO
        self.minimumRTO = minimumRTO
        self.maximumRTO = maximumRTO
    }

    var rto: TimeInterval {
        guard let smoothedRTT else {
            return initialRTO
        }
        return min(max(smoothedRTT + 4 * rttVariance, minimumRTO), maximumRTO)
    }

    /// Karn 规则：调用方只传入未重传过的段的样本，避免 ACK 二义性污染估计
    mutating func recordSample(_ rtt: TimeInterval) {
        guard rtt > 0 else {
            return
        }

        guard let current = smoothedRTT else {
            smoothedRTT = rtt
            rttVariance = rtt / 2
            return
        }

        rttVariance = 0.75 * rttVariance + 0.25 * abs(current - rtt)
        smoothedRTT = 0.875 * current + 0.125 * rtt
    }
}
