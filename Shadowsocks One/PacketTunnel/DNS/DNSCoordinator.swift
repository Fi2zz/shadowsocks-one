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

protocol DNSPayloadQuerying {
    func query(serverIP: String, payload: Data) async throws -> Data
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
    private let upstreamClient: any DNSPayloadQuerying
    private let packetWriter: any TunnelPacketWriting

    init(
        cache: DNSCache,
        whitelist: [String],
        resolver: any DNSResolving = SystemDNSResolver(),
        upstreamClient: any DNSPayloadQuerying,
        packetWriter: any TunnelPacketWriting
    ) {
        self.cache = cache
        self.whitelist = whitelist
        self.resolver = resolver
        self.upstreamClient = upstreamClient
        self.packetWriter = packetWriter
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
        guard udp.destinationPort == 53 else {
            return
        }

        // #region debug-point A:dns-query
        TunnelDebugReporter.send(
            "A",
            location: "DNSCoordinator.handle",
            message: "handling DNS query packet",
            data: [
                "serverIP": packet.destinationAddress,
                "clientIP": packet.sourceAddress,
                "sourcePort": udp.sourcePort,
                "payloadBytes": udp.payload.count,
            ]
        )
        // #endregion
        let responsePayload = try await upstreamClient.query(
            serverIP: packet.destinationAddress,
            payload: udp.payload
        )
        try? cacheResponse(responsePayload)

        let responsePacket = try UDPPacketBuilder.build(
            sourceIP: packet.destinationAddress,
            sourcePort: udp.destinationPort,
            destinationIP: packet.sourceAddress,
            destinationPort: udp.sourcePort,
            payload: responsePayload
        )
        // #region debug-point A:dns-response-written
        TunnelDebugReporter.send(
            "A",
            location: "DNSCoordinator.handle",
            message: "writing DNS response back to packet flow",
            data: [
                "responseBytes": responsePayload.count,
                "packetBytes": responsePacket.count,
            ]
        )
        // #endregion
        packetWriter.write([responsePacket], protocols: [NSNumber(value: AF_INET)])
    }

    private static func normalizeHost(_ host: String) -> String {
        host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    private func cacheResponse(_ responsePayload: Data) throws {
        let message = try DNSMessage(data: responsePayload)
        // #region debug-point C:dns-cache-parse
        TunnelDebugReporter.send(
            "C",
            location: "DNSCoordinator.cacheResponse",
            message: "parsed DNS response for caching",
            data: [
                "questionCount": message.questions.count,
                "answerCount": message.answers.count,
            ]
        )
        // #endregion
        var cachedAnswers: [String: (addresses: Set<String>, ttl: UInt32)] = [:]

        for answer in message.answers {
            guard let address = answer.ipv4Address else {
                continue
            }

            let host = Self.normalizeHost(answer.name)
            guard !host.isEmpty else {
                continue
            }

            if var existing = cachedAnswers[host] {
                existing.addresses.insert(address)
                existing.ttl = min(existing.ttl, answer.ttl)
                cachedAnswers[host] = existing
            } else {
                cachedAnswers[host] = (Set([address]), answer.ttl)
            }
        }

        for (host, entry) in cachedAnswers {
            cache.insert(
                domain: host,
                addresses: Array(entry.addresses),
                ttl: TimeInterval(entry.ttl)
            )
            // #region debug-point C:dns-cache-insert
            TunnelDebugReporter.send(
                "C",
                location: "DNSCoordinator.cacheResponse",
                message: "cached DNS answer",
                data: [
                    "host": host,
                    "addressCount": entry.addresses.count,
                    "ttl": entry.ttl,
                ]
            )
            // #endregion
        }
    }
}
