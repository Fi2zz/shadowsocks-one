import Foundation
import SharedCore

/// UDP 代理流：数据报封装为 IP/UDP 包注入 WG；回包经 egress NAT 分发。
final class WGUDPFlowRelay: UDPFlowRelaying, @unchecked Sendable {
    var onInboundDatagram: (@Sendable (Data) async -> Void)?
    var onClosed: (@Sendable () async -> Void)?

    private let egress: WGProxiedEgress
    private let remoteIP: String
    private let remotePort: UInt16
    private let localAddress: String
    private let localPort: UInt16
    private var natKey: WGProxiedEgress.NATKey?
    private var idleTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "hudun.wg.udp")

    init(egress: WGProxiedEgress, tunnelAddress: String,
         destinationHost: String, destinationPort: UInt16) {
        self.egress = egress
        self.localAddress = tunnelAddress
        self.remoteIP = destinationHost
        self.remotePort = destinationPort
        self.localPort = egress.allocateEphemeralPort()
    }

    func start() async throws {
        natKey = WGProxiedEgress.NATKey(
            protocolNumber: 17, remoteIP: remoteIP,
            remotePort: remotePort, localPort: localPort)
        egress.registerUDP(key: natKey!) { [weak self] payload in
            guard let self else { return }
            self.touch()
            Task { await self.onInboundDatagram?(payload) }
        }
        scheduleIdleTimeout()
    }

    func forwardOutboundPayload(_ payload: Data) async throws {
        touch()
        let packet = try UDPPacketBuilder.build(
            sourceIP: localAddress,
            sourcePort: localPort,
            destinationIP: remoteIP,
            destinationPort: remotePort,
            payload: payload)
        egress.inject(packet)
    }

    func stop() async {
        if let key = natKey {
            egress.unregisterUDP(key: key)
        }
        idleTimer?.cancel()
        idleTimer = nil
    }

    private func touch() {
        idleTimer?.schedule(deadline: .now() + 60, repeating: .never)
    }

    private func scheduleIdleTimeout() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 60)
        source.setEventHandler { [weak self] in
            Task { await self?.onClosed?() }
            self?.idleTimer?.cancel()
        }
        source.resume()
        idleTimer = source
    }
}

/// DNS over WG：把查询封装为发往解析器的 UDP/IP 包，经隧道在代理出口侧解析。
final class WGDNSUpstreamClient: DNSPayloadQuerying, @unchecked Sendable {
    private let egress: WGProxiedEgress
    private let resolverHost: String
    private let tunnelAddress: String
    private let timeoutNanoseconds: UInt64

    init(egress: WGProxiedEgress, tunnelAddress: String,
         resolverHost: String = "8.8.8.8",
         timeoutNanoseconds: UInt64 = 8_000_000_000) {
        self.egress = egress
        self.tunnelAddress = tunnelAddress
        self.resolverHost = resolverHost
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func query(serverIP: String, payload: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            registerOneShot(serverIP: serverIP,
                            payload: payload,
                            continuation: continuation)
        }
    }

    private func registerOneShot(serverIP: String,
                                 payload: Data,
                                 continuation: CheckedContinuation<Data, Error>) {
        let localPort = egress.allocateEphemeralPort()
        let key = WGProxiedEgress.NATKey(
            protocolNumber: 17, remoteIP: serverIP,
            remotePort: 53, localPort: localPort)

        var resumed = false
        func resumeOnce(_ result: Result<Data, Error>) {
            guard !resumed else { return }
            resumed = true
            egress.unregisterUDP(key: key)
            continuation.resume(with: result)
        }

        egress.registerUDP(key: key) { response in
            resumeOnce(.success(response))
        }

        let timeout = DispatchWorkItem { resumeOnce(.failure(WGDNSError.timeout)) }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + Double(self.timeoutNanoseconds) / 1_000_000_000,
            execute: timeout)

        do {
            let packet = try UDPPacketBuilder.build(
                sourceIP: tunnelAddress,
                sourcePort: localPort,
                destinationIP: serverIP,
                destinationPort: 53,
                payload: payload)
            egress.inject(packet)
        } catch {
            timeout.cancel()
            resumeOnce(.failure(error))
        }
    }
}

enum WGDNSError: Error, LocalizedError {
    case timeout

    var errorDescription: String? {
        switch self {
        case .timeout: return "WG-DNS 查询超时"
        }
    }
}
