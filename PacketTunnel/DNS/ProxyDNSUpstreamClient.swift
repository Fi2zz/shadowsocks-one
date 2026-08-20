import Foundation
import SharedCore

enum ProxyDNSUpstreamError: Error, Equatable {
    case timeout
    case unexpectedEOF
}

/// 通过 Shadowsocks 隧道做 DNS over TCP 查询，让目标域名在代理出口侧解析，
/// 避免本地受污染的 DNS 结果（google/x 等域名必须走远程解析）。
final class ProxyDNSUpstreamClient: DNSPayloadQuerying {
    private let config: ConnectionConfig
    private let resolverHost: String
    private let timeoutNanoseconds: UInt64

    init(
        config: ConnectionConfig,
        resolverHost: String = "8.8.8.8",
        timeoutNanoseconds: UInt64 = 10_000_000_000
    ) {
        self.config = config
        self.resolverHost = resolverHost
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func query(serverIP: String, payload: Data) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await self.performQuery(payload: payload)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: self.timeoutNanoseconds)
                throw ProxyDNSUpstreamError.timeout
            }
            defer { group.cancelAll() }

            return try await group.next()!
        }
    }

    private func performQuery(payload: Data) async throws -> Data {
        let transport = try ShadowsocksTCPTransport(
            config: config,
            destinationHost: resolverHost,
            destinationPort: 53
        )
        defer { transport.stop() }

        try await transport.start()
        try await transport.send(makeFramedQuery(payload))
        return try await readFramedResponse(from: transport)
    }

    private func makeFramedQuery(_ payload: Data) -> Data {
        var framed = Data()
        framed.append(UInt8(payload.count >> 8))
        framed.append(UInt8(payload.count & 0x00FF))
        framed.append(payload)
        return framed
    }

    private func readFramedResponse(
        from transport: ShadowsocksTCPTransport
    ) async throws -> Data {
        var buffer = Data()
        var expectedLength: Int?

        while true {
            if let expectedLength, buffer.count >= 2 + expectedLength {
                return buffer.subdata(in: 2 ..< 2 + expectedLength)
            }

            let payloads = try await transport.receivePayloads()
            guard !payloads.isEmpty else {
                throw ProxyDNSUpstreamError.unexpectedEOF
            }
            for payload in payloads {
                buffer.append(payload)
            }

            if expectedLength == nil, buffer.count >= 2 {
                expectedLength = (Int(buffer[buffer.startIndex]) << 8)
                    | Int(buffer[buffer.index(after: buffer.startIndex)])
            }
        }
    }
}
