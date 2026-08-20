import Foundation

final class TCPFlowSessionStore: @unchecked Sendable {
    private let lock = NSLock()
    private struct Session {
        var relay: any TCPFlowRelaying
        var state: TCPFlowState
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
        lock.lock()
        defer { lock.unlock() }
        guard var session = sessions[key] else {
            return
        }
        session.state = state
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
