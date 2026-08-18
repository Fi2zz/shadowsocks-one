import Foundation

public struct ConnectionProbeTarget: Sendable, Equatable {
    public let host: String
    public let port: UInt16
    public let requestData: Data
    public let responsePrefix: Data

    public init(host: String, port: UInt16, requestData: Data, responsePrefix: Data) {
        self.host = host
        self.port = port
        self.requestData = requestData
        self.responsePrefix = responsePrefix
    }

    public static let `default` = ConnectionProbeTarget(
        host: "example.com",
        port: 80,
        requestData: Data(
            "HEAD / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n".utf8
        ),
        responsePrefix: Data("HTTP/".utf8)
    )
}
