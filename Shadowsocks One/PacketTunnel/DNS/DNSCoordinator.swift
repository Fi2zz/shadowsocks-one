import Darwin
import Foundation
import SharedCore

protocol DNSCoordinating: AnyObject {
    func warmUpWhitelistCache() async
    func handle(_ packet: IPPacket) async throws
}

protocol DNSResolving: Sendable {
    func resolve(host: String) async throws -> [String]
}

enum DNSResolverError: Error, Equatable {
    case resolutionFailed(host: String, status: Int32)
}

struct SystemDNSResolver: DNSResolving {
    func resolve(host: String) async throws -> [String] {
        try await Task.detached(priority: .utility) {
            try Self.resolveSynchronously(host: host)
        }.value
    }

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

final class DNSCoordinator: DNSCoordinating {
    private let cache: DNSCache
    private let whitelist: [String]
    private let resolver: any DNSResolving

    init(
        cache: DNSCache,
        whitelist: [String],
        resolver: any DNSResolving = SystemDNSResolver()
    ) {
        self.cache = cache
        self.whitelist = whitelist
        self.resolver = resolver
    }

    func warmUpWhitelistCache() async {
        for host in whitelist.map(Self.normalizeHost) {
            guard !host.isEmpty, !host.contains("*") else {
                continue
            }

            guard let addresses = try? await resolver.resolve(host: host),
                  !addresses.isEmpty else {
                continue
            }

            cache.insert(domain: host, addresses: addresses, ttl: 300)
        }
    }

    func handle(_ packet: IPPacket) async throws {
        let udp = try packet.udpSegment()
        guard udp.destinationPort == 53 || udp.sourcePort == 53 else {
            return
        }
    }

    private static func normalizeHost(_ host: String) -> String {
        host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }
}
