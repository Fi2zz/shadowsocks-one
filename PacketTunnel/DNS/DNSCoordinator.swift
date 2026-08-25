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
    private struct UpstreamChoice {
        let client: any DNSPayloadQuerying
        let host: String
        let label: String
    }

    private let cache: DNSCache
    private let whitelist: [String]
    private let resolver: any DNSResolving
    private let upstreamClient: any DNSPayloadQuerying
    private let localUpstreamClient: (any DNSPayloadQuerying)?
    private let matcher: RouteMatcher?
    private let localFirstFallback: Bool
    private let packetWriter: any TunnelPacketWriting
    private let diagnostics: TunnelDiagnosticsLogging?

    /// localFirstFallback：默认代理的域名先走本地解析，若结果全部落在
    /// CN 段则直接采用（国内站低延迟），否则改走远程解析防污染。
    init(
        cache: DNSCache,
        whitelist: [String],
        resolver: any DNSResolving = SystemDNSResolver(),
        upstreamClient: any DNSPayloadQuerying,
        localUpstreamClient: (any DNSPayloadQuerying)? = nil,
        matcher: RouteMatcher? = nil,
        localFirstFallback: Bool = false,
        packetWriter: any TunnelPacketWriting,
        diagnostics: TunnelDiagnosticsLogging? = nil
    ) {
        self.localFirstFallback = localFirstFallback
        self.cache = cache
        self.whitelist = whitelist
        self.resolver = resolver
        self.upstreamClient = upstreamClient
        self.localUpstreamClient = localUpstreamClient
        self.matcher = matcher
        self.packetWriter = packetWriter
        self.diagnostics = diagnostics
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

        if try suppressAAAAQueryIfNeeded(packet: packet, udp: udp) {
            return
        }

        var choice = selectUpstream(for: udp.payload)
        do {
            var responsePayload = try await choice.client.query(
                serverIP: packet.destinationAddress,
                payload: udp.payload
            )
            if choice.label == "local-first" {
                if let validated = validatedLocalResult(responsePayload, matcher: matcher) {
                    responsePayload = validated
                    choice = UpstreamChoice(
                        client: choice.client, host: choice.host,
                        label: "local-verified")
                } else {
                    diagnostics?("DNS \(choice.host) local-first 未命中 CN，转远程")
                    responsePayload = try await upstreamClient.query(
                        serverIP: packet.destinationAddress,
                        payload: udp.payload)
                    choice = UpstreamChoice(
                        client: upstreamClient, host: choice.host, label: "proxy-fallback")
                }
            }
            let addresses = (try? cacheResponse(responsePayload)) ?? []
            diagnostics?("DNS \(choice.host) via \(choice.label) ok [\(addresses.joined(separator: ","))]")
            try writeResponse(responsePayload, for: packet, udp: udp)
        } catch {
            diagnostics?("DNS \(choice.host) via \(choice.label) failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// 本地解析结果全部落在 CN 段才采纳，防止污染 IP 进入直连路径。
    private func validatedLocalResult(
        _ responsePayload: Data, matcher: RouteMatcher?
    ) -> Data? {
        guard let matcher,
              let message = try? DNSMessage(data: responsePayload),
              !message.answers.isEmpty else {
            return nil
        }

        let addresses = message.answers.compactMap(\.ipv4Address)
        guard !addresses.isEmpty,
              addresses.allSatisfy({ matcher.containsCNIP($0) }) else {
            return nil
        }
        return responsePayload
    }

    private func writeResponse(_ responsePayload: Data, for packet: IPPacket, udp: UDPPacket) throws {
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

    private func selectUpstream(for queryPayload: Data) -> UpstreamChoice {
        guard let matcher, let localUpstreamClient,
              let host = Self.queryHost(in: queryPayload) else {
            return UpstreamChoice(client: upstreamClient, host: "?", label: "proxy")
        }

        if matcher.dnsDecision(forHost: host) == .direct {
            return UpstreamChoice(client: localUpstreamClient, host: host, label: "local")
        }
        if localFirstFallback, !matcher.explicitlyProxied(host: host) {
            return UpstreamChoice(
                client: localUpstreamClient,
                host: host,
                label: "local-first")
        }
        return UpstreamChoice(client: upstreamClient, host: host, label: "proxy")
    }

    private static let aaaaQueryType: UInt16 = 28

    /// 隧道只接管 IPv4：AAAA 查询直接回空应答，让客户端回落 A 记录，
    /// 否则拿到 IPv6 的 App 会绕过隧道直连，被墙站点表现为转圈
    private func suppressAAAAQueryIfNeeded(packet: IPPacket, udp: UDPPacket) throws -> Bool {
        guard let question = Self.queryQuestion(in: udp.payload),
              question.type == Self.aaaaQueryType else {
            return false
        }

        let response = try DNSMessage.emptyResponse(forQuery: udp.payload)
        diagnostics?("DNS \(Self.normalizeHost(question.name)) AAAA suppressed (IPv4-only tunnel)")
        try writeResponse(response, for: packet, udp: udp)
        return true
    }

    private static func queryQuestion(in payload: Data) -> DNSMessage.Question? {
        guard let message = try? DNSMessage(data: payload) else {
            return nil
        }
        return message.questions.first
    }

    private static func queryHost(in payload: Data) -> String? {
        queryQuestion(in: payload).map { normalizeHost($0.name) }
    }

    @discardableResult
    private func cacheResponse(_ responsePayload: Data) throws -> [String] {
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

        return cachedAnswers
            .map { host, entry in "\(host)=\(entry.addresses.sorted().joined(separator: "|"))" }
            .sorted()
    }
}
