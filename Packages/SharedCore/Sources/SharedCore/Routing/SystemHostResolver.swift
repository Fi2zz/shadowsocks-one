import Darwin
import Foundation

public protocol DNSResolving: Sendable {
    func resolve(host: String) async throws -> [String]
}

public enum DNSResolverError: Error, Equatable {
    case resolutionFailed(host: String, status: Int32)
}

public struct SystemDNSResolver: DNSResolving {
    public init() {}

    public func resolve(host: String) async throws -> [String] {
        try await Task.detached(priority: .utility) {
            try Self.resolveSynchronously(host: host)
        }.value
    }

    // REASON: getaddrinfo 链表遍历是 C API 固定模式，强行拆分反而降低可读性
    private static func resolveSynchronously(host: String) throws -> [String] {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let firstResult = result else {
            throw DNSResolverError.resolutionFailed(host: host, status: status)
        }
        defer { freeaddrinfo(firstResult) }

        var addresses = Set<String>()
        var cursor: UnsafeMutablePointer<addrinfo>? = firstResult
        while let info = cursor {
            if info.pointee.ai_family == AF_INET,
               let addressPointer = info.pointee.ai_addr?.withMemoryRebound(
                to: sockaddr_in.self,
                capacity: 1,
                { $0 }
               ) {
                var address = addressPointer.pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(
                    AF_INET,
                    &address,
                    &buffer,
                    socklen_t(INET_ADDRSTRLEN)
                ) != nil else {
                    cursor = info.pointee.ai_next
                    continue
                }
                addresses.insert(String(cString: buffer))
            }
            cursor = info.pointee.ai_next
        }

        return addresses.sorted()
    }
}
