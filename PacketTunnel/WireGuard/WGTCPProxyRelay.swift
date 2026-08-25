import Foundation
import Darwin
import SharedCore

/// 在 WG 隧道网络上的极简 TCP 客户端栈：供 TCPRouter 代理分支使用。
/// 发送侧停等式重传；接收侧固定通告窗口；MSS 1200（MTU 1300 内）。
final class WGTCPProxyRelay: TCPFlowRelaying, @unchecked Sendable {
    private enum Phase {
        case synSent
        case established
        case closed
    }

    static let maximumSegmentSize = 1_200

    var onInboundBytes: (@Sendable (Data) async -> Void)?
    var onClosed: (@Sendable () async -> Void)?

    private(set) var queuedOutboundBytes: Int = 0

    private let egress: WGProxiedEgress
    private let remoteIP: String
    private let remotePort: UInt16
    private let localAddress: String
    private let localPort: UInt16
    private let diagnostics: TunnelDiagnosticsLogging?

    private var phase: Phase = .synSent
    private var sequenceNumber: UInt32 = 0
    private var ackNumber: UInt32 = 0
    private var pendingOutbound: [Data] = []
    private var unacked: [(seq: UInt32, data: Data, sentAt: Date)] = []
    private var retransmitCount = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "hudun.wg.tcp")
    private var natKey: WGProxiedEgress.NATKey?

    init(egress: WGProxiedEgress, tunnelAddress: String,
         destinationHost: String, destinationPort: UInt16,
         diagnostics: TunnelDiagnosticsLogging?) {
        self.egress = egress
        self.localAddress = tunnelAddress
        self.remoteIP = destinationHost
        self.remotePort = destinationPort
        self.localPort = egress.allocateEphemeralPort()
        self.diagnostics = diagnostics
        sequenceNumber = UInt32.random(in: 1...UInt32.max / 2)
    }

    func start() async throws {
        let key = WGProxiedEgress.NATKey(
            protocolNumber: 6, remoteIP: remoteIP,
            remotePort: remotePort, localPort: localPort)
        natKey = key
        egress.registerTCP(key: key, relay: self)
        startTimer()
        sendSegment(flags: [.syn], payload: Data())
        diagnostics?("WG-TCP SYN → \(remoteIP):\(remotePort) port=\(localPort)")
    }

    func forwardOutboundPayload(_ payload: Data) async throws {
        queue.async { [weak self] in
            guard let self, self.phase == .established else {
                self?.queuePending(payload)
                return
            }
            self.queuePending(payload)
            self.flushPendingLocked()
        }
    }

    func stop() async {
        queue.async { [weak self] in
            guard let self, self.phase == .established else {
                self?.teardown()
                return
            }
            self.sendSegment(flags: [.fin, .ack], payload: Data())
            self.phase = .closed
            self.teardown(keepTimerBriefly: true)
        }
    }

    // MARK: - 入站（egress 分发，串行 queue 上执行）

    func handleInboundSegment(_ packet: IPPacket, tcp: TCPPacket) {
        queue.async { [weak self] in
            self?.handleInboundLocked(packet, tcp: tcp)
        }
    }

    private func handleInboundLocked(_ packet: IPPacket, tcp: TCPPacket) {
        guard phase != .closed else { return }
        if tcp.isRST {
            diagnostics?("WG-TCP RST from \(remoteIP):\(remotePort)")
            finishFlow()
            return
        }

        switch phase {
        case .synSent:
            guard tcp.isSYN, tcp.isACK else { return }
            ackNumber = tcp.sequenceNumber &+ 1
            phase = .established
            sendSegment(flags: [.ack], payload: Data())
            flushPendingLocked()
        case .established:
            consumeInbound(tcp)
        case .closed:
            break
        }
    }

    private func consumeInbound(_ tcp: TCPPacket) {
        if !tcp.payload.isEmpty {
            acknowledgeRemote(bytes: tcp.payload.count)
            let payload = tcp.payload
            Task { await self.onInboundBytes?(payload) }
        }
        if tcp.isFIN {
            sendSegment(flags: [.ack], payload: Data())
            Task { await onClosed?() }
            teardown()
        } else if !tcp.payload.isEmpty || tcp.isACK {
            pruneAcked(ack: tcp.acknowledgmentNumber)
        }
    }

    private func acknowledgeRemote(bytes: Int) {
        ackNumber = ackNumber &+ UInt32(bytes)
        sendSegment(flags: [.ack], payload: Data())
    }

    // MARK: - 出站分段与重传

    private func queuePending(_ payload: Data) {
        queuedOutboundBytes += payload.count
        var offset = 0
        while offset < payload.count {
            let end = min(offset + Self.maximumSegmentSize, payload.count)
            pendingOutbound.append(payload.subdata(in: offset..<end))
            offset = end
        }
    }

    private func flushPendingLocked() {
        while !pendingOutbound.isEmpty {
            let chunk = pendingOutbound.removeFirst()
            sendSegment(flags: [.psh, .ack], payload: chunk)
            unacked.append((sequenceNumber, chunk, Date()))
        }
    }

    private func pruneAcked(ack: UInt32) {
        var freed = 0
        unacked.removeAll { entry in
            let distance = ack &- entry.seq
            let acknowledged = distance > 0 && distance < 0x8000_0000
            if acknowledged { freed += entry.data.count }
            return acknowledged
        }
        queuedOutboundBytes = max(queuedOutboundBytes - freed, 0)
        retransmitCount = 0
    }

    private func sendSegment(flags: Set<TCPPacketFlag>, payload: Data) {
        do {
            let packet = try TCPPacketBuilder.build(
                sourceIP: localAddress,
                sourcePort: localPort,
                destinationIP: remoteIP,
                destinationPort: remotePort,
                sequenceNumber: sequenceNumber,
                acknowledgmentNumber: ackNumber,
                flags: flags,
                payload: payload,
                window: 0xFFFF)
            sequenceNumber = sequenceNumber &+ UInt32(payload.count)
                    + (flags.contains(.syn) ? 1 : 0)
                    + (flags.contains(.fin) ? 1 : 0)
            egress.inject(packet)
        } catch {
            diagnostics?("WG-TCP build failed: \(error.localizedDescription)")
        }
    }

    private func startTimer() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: 0.4)
        source.setEventHandler { [weak self] in self?.retransmitTick() }
        source.resume()
        timer = source
    }

    private func retransmitTick() {
        guard phase == .established || phase == .synSent else { return }
        let now = Date()
        for entry in unacked where now.timeIntervalSince(entry.sentAt) > 0.8 {
            resend(entry)
            retransmitCount += 1
            if retransmitCount > 10 {
                diagnostics?("WG-TCP give up \(remoteIP):\(remotePort)")
                finishFlow()
                return
            }
        }
        if phase == .synSent, let first = unacked.first {
            resend(first)
        }
    }

    private func resend(_ entry: (seq: UInt32, data: Data, sentAt: Date)) {
        do {
            let packet = try TCPPacketBuilder.build(
                sourceIP: localAddress,
                sourcePort: localPort,
                destinationIP: remoteIP,
                destinationPort: remotePort,
                sequenceNumber: entry.seq,
                acknowledgmentNumber: ackNumber,
                flags: [.psh, .ack],
                payload: entry.data,
                window: 0xFFFF)
            egress.inject(packet)
        } catch {}
    }

    private func finishFlow() {
        phase = .closed
        Task { await onClosed?() }
        teardown()
    }

    /// 解除 NAT 注册与定时器；keepTimerBriefly 用于 FIN 后短暂收尾 ACK。
    private func teardown(keepTimerBriefly: Bool = false) {
        if let key = natKey {
            egress.unregisterTCP(key: key)
        }
        if !keepTimerBriefly {
            timer?.cancel()
            timer = nil
        } else {
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.timer?.cancel()
                self?.timer = nil
            }
        }
    }
}
