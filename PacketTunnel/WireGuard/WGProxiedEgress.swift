import Foundation
import SharedCore

/// WG 代理流共享出口：端口分配、NAT 回包分发、原始 IP 包注入隧道。
final class WGProxiedEgress {
    struct NATKey: Hashable {
        let protocolNumber: UInt8
        let remoteIP: String
        let remotePort: UInt16
        let localPort: UInt16
    }

    typealias OutboundInjector = @Sendable (Data) -> Void

    private let tunnelAddress: String
    private var onOutbound: OutboundInjector?
    private var packetWriter: (any TunnelPacketWriting)?
    private var tcpHandlers: [NATKey: WGTCPProxyRelay] = [:]
    private var udpHandlers: [NATKey: (@Sendable (Data) -> Void)?] = [:]
    private let lock = NSLock()
    private var nextEphemeralPort: UInt16 = 49152

    init(tunnelAddress: String) {
        self.tunnelAddress = tunnelAddress
    }

    var localAddress: String { tunnelAddress }

    func attachOutbound(_ injector: @escaping OutboundInjector) {
        onOutbound = injector
    }

    func attachPacketWriter(_ writer: (any TunnelPacketWriting)?) {
        packetWriter = writer
    }

    /// 分配一个未占用的本地临时端口。
    func allocateEphemeralPort() -> UInt16 {
        lock.lock(); defer { lock.unlock() }
        repeat {
            nextEphemeralPort &+= 1
            if nextEphemeralPort < 49152 { nextEphemeralPort = 49152 }
        } while udpHandlers[NATKey(protocolNumber: 17, remoteIP: "*", remotePort: 0, localPort: nextEphemeralPort)] != nil
        return nextEphemeralPort
    }

    func registerTCP(key: NATKey, relay: WGTCPProxyRelay) {
        lock.lock(); defer { lock.unlock() }
        tcpHandlers[key] = relay
    }

    func unregisterTCP(key: NATKey) {
        lock.lock(); defer { lock.unlock() }
        tcpHandlers.removeValue(forKey: key)
    }

    func registerUDP(key: NATKey, handler: @escaping (Data) -> Void) {
        lock.lock(); defer { lock.unlock() }
        udpHandlers[key] = handler
    }

    func unregisterUDP(key: NATKey) {
        lock.lock(); defer { lock.unlock() }
        udpHandlers.removeValue(forKey: key)
    }

    /// relay 出站：封装好的完整 IPv4 包注入 WG 会话。
    func inject(_ ipPacket: Data) {
        onOutbound?(ipPacket)
    }

    func writePacketsToTUN(_ packets: [Data]) {
        packetWriter?.write(packets, protocols: [NSNumber(value: AF_INET)])
    }

    /// pump 解密出的内层 IP 包在此分发：代理流回包 → 对应 relay；其余写 TUN。
    func deliverInbound(_ inner: Data) async {
        guard let packet = try? IPPacket(data: inner), inner.count >= 20 else {
            return
        }
        switch packet.protocolNumber {
        case 6:
            if deliverTCP(packet) { return }
        case 17:
            if await deliverUDP(packet) { return }
        default:
            break
        }
        writePacketsToTUN([inner])
    }

    private func deliverTCP(_ packet: IPPacket) -> Bool {
        guard let tcp = try? packet.tcpSegment() else { return false }
        let key = NATKey(
            protocolNumber: 6,
            remoteIP: packet.sourceAddress,
            remotePort: tcp.sourcePort,
            localPort: tcp.destinationPort)
        lock.lock()
        let relay = tcpHandlers[key]
        lock.unlock()
        guard let relay else { return false }
        relay.handleInboundSegment(packet, tcp: tcp)
        return true
    }

    private func deliverUDP(_ packet: IPPacket) async -> Bool {
        guard let udp = try? packet.udpSegment() else { return false }
        let key = NATKey(
            protocolNumber: 17,
            remoteIP: packet.sourceAddress,
            remotePort: udp.sourcePort,
            localPort: udp.destinationPort)
        lock.lock()
        let handler = udpHandlers[key]
        lock.unlock()
        guard let handler = handler.flatMap({ $0 }) else { return false }
        await handler(udp.payload)
        return true
    }
}
