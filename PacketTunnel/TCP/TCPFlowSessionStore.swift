import Foundation

final class TCPFlowSessionStore: @unchecked Sendable {
    private let lock = NSLock()
    private struct Session {
        var relay: any TCPFlowRelaying
        var state: TCPFlowState
        var sendBuffer = TCPSendBuffer()
    }

    private var sessions: [TCPFlowKey: Session] = [:]

    func relay(for key: TCPFlowKey) -> (any TCPFlowRelaying)? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[key]?.relay
    }

    func state(for key: TCPFlowKey) -> TCPFlowState? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[key]?.state
    }

    func session(
        for key: TCPFlowKey,
        create: () throws -> (relay: any TCPFlowRelaying, state: TCPFlowState)
    ) rethrows -> (relay: any TCPFlowRelaying, state: TCPFlowState, isNew: Bool) {
        lock.lock()
        defer { lock.unlock() }

        if let session = sessions[key] {
            return (session.relay, session.state, false)
        }

        let created = try create()
        sessions[key] = Session(
            relay: created.relay,
            state: created.state
        )
        return (created.relay, created.state, true)
    }

    func updateState(_ state: TCPFlowState, for key: TCPFlowKey) {
        mutateSession(for: key) { $0.state = state }
    }

    func recordSentSegment(
        sequenceNumber: UInt32,
        payload: Data,
        for key: TCPFlowKey,
        now: Date
    ) {
        mutateSession(for: key) {
            $0.sendBuffer.append(sequenceNumber: sequenceNumber, payload: payload, now: now)
        }
    }

    /// 累积确认，返回被移除的段（供 RTT 采样）
    @discardableResult
    func acknowledgeSentBytes(
        upTo acknowledgment: UInt32,
        for key: TCPFlowKey
    ) -> [TCPSendBuffer.Segment] {
        lock.lock()
        defer { lock.unlock() }
        guard var session = sessions[key] else {
            return []
        }
        let removed = session.sendBuffer.acknowledge(upTo: acknowledgment)
        sessions[key] = session
        return removed
    }

    /// 取出各会话到期未确认的段并推进其重传计时，附带建包所需的状态快照
    func popDueSegments(
        now: Date,
        rto: TimeInterval
    ) -> [(key: TCPFlowKey, state: TCPFlowState, segment: TCPSendBuffer.Segment)] {
        lock.lock()
        defer { lock.unlock() }

        var due: [(key: TCPFlowKey, state: TCPFlowState, segment: TCPSendBuffer.Segment)] = []
        for key in Array(sessions.keys) {
            guard var session = sessions[key] else {
                continue
            }
            let segments = session.sendBuffer.popDueSegments(now: now, rto: rto)
            sessions[key] = session
            due.append(contentsOf: segments.map { (key, session.state, $0) })
        }
        return due
    }

    private func mutateSession(for key: TCPFlowKey, _ body: (inout Session) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard var session = sessions[key] else {
            return
        }
        body(&session)
        sessions[key] = session
    }

    @discardableResult
    func removeRelay(for key: TCPFlowKey) -> (any TCPFlowRelaying)? {
        lock.lock()
        defer { lock.unlock() }
        return sessions.removeValue(forKey: key)?.relay
    }

    func removeAllRelays() -> [any TCPFlowRelaying] {
        lock.lock()
        defer { lock.unlock() }

        let activeRelays = sessions.map(\.value.relay)
        sessions.removeAll()
        return activeRelays
    }
}
