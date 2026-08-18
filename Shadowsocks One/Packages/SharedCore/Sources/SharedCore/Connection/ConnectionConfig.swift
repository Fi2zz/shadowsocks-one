public struct ConnectionConfig: Sendable {
    public let host: String
    public let port: UInt16
    public let method: CipherMethod
    public let password: String

    public init(host: String, port: UInt16, method: CipherMethod, password: String) {
        self.host = host
        self.port = port
        self.method = method
        self.password = password
    }

    public init(profile: ServerProfile) {
        self.host = profile.host
        self.port = profile.port
        self.method = profile.method
        self.password = profile.password
    }
}
