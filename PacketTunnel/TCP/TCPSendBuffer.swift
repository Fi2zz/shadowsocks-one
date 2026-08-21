import Foundation

/// 出站（隧道 → 客户端）payload 发送缓冲：记录已发未 ACK 的段，
/// 超时未确认时由 TCPRouter 重发。只按整段累积确认，部分确认不裁剪。
struct TCPSendBuffer: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let sequenceNumber: UInt32
        let payload: Data
        private(set) var lastSentAt: Date
        private(set) var retransmitCount: Int

        mutating func markRetransmitted(at now: Date) {
            lastSentAt = now
            retransmitCount += 1
        }
    }

    static let maximumRetransmissions = 10

    private var segments: [Segment] = []

    var pendingSegments: [Segment] {
        segments
    }

    var unackedPayloadBytes: Int {
        segments.reduce(0) { $0 + $1.payload.count }
    }

    mutating func append(sequenceNumber: UInt32, payload: Data, now: Date) {
        guard !payload.isEmpty else {
            return
        }

        segments.append(
            Segment(
                sequenceNumber: sequenceNumber,
                payload: payload,
                lastSentAt: now,
                retransmitCount: 0
            )
        )
    }

    mutating func acknowledge(upTo acknowledgment: UInt32) {
        segments.removeAll { segment in
            Self.ackCoversEnd(ack: acknowledgment, end: Self.endSequence(of: segment))
        }
    }

    /// 取出到期未确认的段并推进其重传计时（指数退避，封顶 8 倍 RTO）
    mutating func popDueSegments(now: Date, rto: TimeInterval) -> [Segment] {
        var due: [Segment] = []
        for index in segments.indices {
            let segment = segments[index]
            guard segment.retransmitCount < Self.maximumRetransmissions,
                  now.timeIntervalSince(segment.lastSentAt)
                      >= Self.dueInterval(rto: rto, retransmitCount: segment.retransmitCount) else {
                continue
            }

            segments[index].markRetransmitted(at: now)
            due.append(segments[index])
        }
        return due
    }

    static func dueInterval(rto: TimeInterval, retransmitCount: Int) -> TimeInterval {
        rto * TimeInterval(1 << min(retransmitCount, 3))
    }

    /// 回绕安全的「end ≤ ack」判断：ack 到 end 的正向距离须落在半序号空间内
    static func ackCoversEnd(ack: UInt32, end: UInt32) -> Bool {
        ack &- end < 0x8000_0000
    }

    private static func endSequence(of segment: Segment) -> UInt32 {
        segment.sequenceNumber &+ UInt32(segment.payload.count)
    }
}
