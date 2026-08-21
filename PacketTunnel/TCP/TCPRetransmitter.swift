import Foundation
import Darwin
import SharedCore

/// 出站重传器：周期扫描所有 TCP 会话的发送缓冲，
/// 把到期未确认的 payload 段按原序列号重新写回 TUN。
final class TCPRetransmitter: @unchecked Sendable {
    private let sessionStore: TCPFlowSessionStore
    private let diagnostics: TunnelDiagnosticsLogging?
    private let now: @Sendable () -> Date
    private let retransmitTimeout: TimeInterval
    private let sweepIntervalNanoseconds: UInt64
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var packetWriter: (any TunnelPacketWriting)?

    init(
        sessionStore: TCPFlowSessionStore,
        diagnostics: TunnelDiagnosticsLogging? = nil,
        now: @Sendable @escaping () -> Date = Date.init,
        retransmitTimeout: TimeInterval = 1.0,
        sweepIntervalNanoseconds: UInt64 = 250_000_000
    ) {
        self.sessionStore = sessionStore
        self.diagnostics = diagnostics
        self.now = now
        self.retransmitTimeout = retransmitTimeout
        self.sweepIntervalNanoseconds = sweepIntervalNanoseconds
    }

    func setPacketWriter(_ packetWriter: (any TunnelPacketWriting)?) {
        lock.lock()
        self.packetWriter = packetWriter
        lock.unlock()

        if packetWriter != nil {
            startSweep()
        } else {
            stop()
        }
    }

    func stop() {
        lock.lock()
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }

    private func startSweep() {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else {
            return
        }

        let interval = sweepIntervalNanoseconds
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else {
                    break
                }
                self?.retransmitDueSegments()
            }
        }
    }

    private func retransmitDueSegments() {
        let due = sessionStore.popDueSegments(now: now(), rto: retransmitTimeout)
        for entry in due {
            writeRetransmission(entry)
        }
    }

    private func writeRetransmission(
        _ entry: (key: TCPFlowKey, state: TCPFlowState, segment: TCPSendBuffer.Segment)
    ) {
        guard let packet = buildRetransmissionPacket(for: entry) else {
            return
        }

        diagnostics?(
            "TCP rexmit \(entry.key.destinationAddress):\(entry.key.destinationPort) seq=\(entry.segment.sequenceNumber) bytes=\(entry.segment.payload.count) tries=\(entry.segment.retransmitCount)"
        )
        packetWriter?.write([packet], protocols: [NSNumber(value: AF_INET)])
    }

    private func buildRetransmissionPacket(
        for entry: (key: TCPFlowKey, state: TCPFlowState, segment: TCPSendBuffer.Segment)
    ) -> Data? {
        try? TCPPacketBuilder.build(
            sourceIP: entry.state.remoteIP,
            sourcePort: entry.state.remotePort,
            destinationIP: entry.state.clientIP,
            destinationPort: entry.state.clientPort,
            sequenceNumber: entry.segment.sequenceNumber,
            acknowledgmentNumber: entry.state.nextExpectedClientSequence,
            flags: [.psh, .ack],
            payload: entry.segment.payload
        )
    }
}
