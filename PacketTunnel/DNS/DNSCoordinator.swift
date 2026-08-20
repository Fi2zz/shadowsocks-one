import Darwin
import Foundation
import SharedCore

protocol DNSCoordinating: AnyObject {
    func warmUpWhitelistCache() async
    func handle(_ packet: IPPacket) async throws
}

protocol DNSPayloadQuerying {
    func query(serverIP: String, payload: Data) async throws -> Data
}

final class DNSCoordinator: DNSCoordinating {
    private let cache: DNSCache
    private let whitelist: [String]
    private let resolver: any DNSResolving
    private let upstreamClient: any DNSPayloadQuerying
    private let localUpstreamClient: (any DNSPayloadQuerying)?
    private let matcher: RouteMatcher?
    private let packetWriter: any TunnelPacketWriting

    init(
        cache: DNSCache,
        whitelist: [String],
        resolver: any DNSResolving = SystemDNSResolver(),
        upstreamClient: any DNSPayloadQuerying,
        localUpstreamClient: (any DNSPayloadQuerying)? = nil,
        matcher: RouteMatcher? = nil,
        packetWriter: any TunnelPacketWriting
    ) {
        self.cache = cache
        self.whitelist = whitelist
        self.resolver = resolver
        self.upstreamClient = upstreamClient
        self.localUpstreamClient = localUpstreamClient
        self.matcher = matcher
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

        let responsePayload = try await selectUpstream(for: udp.payload).query(
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
        packetWriter.write([responsePacket], protocols: [NSNumber(value: AF_INET)])
    }

    private static func normalizeHost(_ host: String) -> String {
        host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    private func selectUpstream(for queryPayload: Data) -> any DNSPayloadQuerying {
        guard let matcher, let localUpstreamClient,
              let host = Self.queryHost(in: queryPayload) else {
            return upstreamClient
        }

        return matcher.dnsDecision(forHost: host) == .direct
            ? localUpstreamClient
            : upstreamClient
    }

    private static func queryHost(in payload: Data) -> String? {
        guard let message = try? DNSMessage(data: payload),
              let question = message.questions.first else {
            return nil
        }
        return normalizeHost(question.name)
    }

    private func cacheResponse(_ responsePayload: Data) throws {
        let message = try DNSMessage(data: responsePayload)
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
        }
    }
}
