public enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case failed(String)
}
