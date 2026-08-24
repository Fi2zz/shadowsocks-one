import Foundation
import Darwin
import CryptoKit
import SharedCore

/// WireGuard 全局模式数据泵：TUN ↔ Noise IK 会话 ↔ UDP。
final class WireGuardTunnelPump {
    private let configuration: HudunTunnelLaunchConfiguration
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private let peerPublicKey: Curve25519.KeyAgreement.PublicKey
    private let packetFlow: TunnelPacketFlow
    private let diagnostics: TunnelDiagnosticsLogging?
    private let channel: WireGuardUDPChannel

    private var pendingInitiation: WireGuardHandshake.Initiation?
    private var session: WireGuardSession?
    private var readerTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTimer: DispatchSourceTimer?
    private(set) var handshakeSucceeded = false

    init(configuration: HudunTunnelLaunchConfiguration,
         privateKeyBase64: String,
         packetFlow: TunnelPacketFlow,
         diagnostics: TunnelDiagnosticsLogging?) throws {
        self.configuration = configuration
        self.packetFlow = packetFlow
        self.diagnostics = diagnostics
        guard let keyData = Data(base64Encoded: privateKeyBase64) else {
            throw WireGuardError.badPacket("私钥 base64 非法")
        }
        privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyData)
        guard let peerData = Data(base64Encoded: configuration.peerPublicKeyBase64) else {
            throw WireGuardError.badPacket("对端公钥 base64 非法")
        }
        peerPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerData)
        channel = WireGuardUDPChannel(host: configuration.endpointHost,
                                      port: configuration.endpointPort)
    }

    func start() {
        channel.start()
        performHandshake()
        startReader()
        startReceiver()
        scheduleKeepalive()
        diagnostics?("WG pump started \(configuration.endpointHost):\(configuration.endpointPort)")
    }

    func stop() {
        readerTask?.cancel()
        receiveTask?.cancel()
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        channel.cancel()
        diagnostics?("WG pump stopped")
    }

    // MARK: - 握手

    private func performHandshake() {
        do {
            let initiation = try WireGuardHandshake.createInitiation(
                staticPrivate: privateKey, peerStaticPublic: peerPublicKey)
            pendingInitiation = initiation
            channel.send(initiation.packet)
            diagnostics?("WG handshake sent idx=\(initiation.localIndex)")
        } catch {
            diagnostics?("WG handshake build failed: \(error.localizedDescription)")
        }
    }

    /// 重试握手（响应丢失时调用）。
    func retryHandshake() {
        guard !handshakeSucceeded else { return }
        performHandshake()
    }

    private func handleHandshakeResponse(_ datagram: Data) {
        guard !handshakeSucceeded,
              let initiation = pendingInitiation else { return }
        do {
            let keys = try WireGuardHandshake.processResponse(
                datagram, initiation: initiation,
                staticPrivate: privateKey)
            session = WireGuardSession(send: keys.send, receive: keys.receive,
                                       peerIndex: keys.peerIndex,
                                       localIndex: keys.localIndex)
            handshakeSucceeded = true
            sendKeepalive()
            diagnostics?("WG handshake ok")
        } catch {
            diagnostics?("WG handshake rejected: \(error.localizedDescription)")
        }
    }

    // MARK: - 数据面

    private func startReader() {
        readerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let packets = await self.readPackets()
                if Task.isCancelled { break }
                for packet in packets where Self.isIPv4(packet) {
                    self.enqueueOutbound(packet)
                }
            }
        }
    }

    private func enqueueOutbound(_ packet: Data) {
        guard let session, handshakeSucceeded else { return }
        channel.send((try? session.sealPacket(packet)) ?? Data())
    }

    private func startReceiver() {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let datagram = await self?.channel.receive(), !datagram.isEmpty else {
                    continue
                }
                self?.handleInbound(datagram)
            }
        }
    }

    private func handleInbound(_ datagram: Data) {
        guard datagram.count > 4 else { return }
        switch datagram[datagram.startIndex] {
        case 2:
            handleHandshakeResponse(datagram)
        case 4:
            decryptAndWrite(datagram)
        default:
            break
        }
    }

    private func decryptAndWrite(_ datagram: Data) {
        guard let session else { return }
        do {
            if let inner = try session.openDatagram(datagram) {
                writePackets([inner])
            }
        } catch {
            diagnostics?("WG open failed: \(error.localizedDescription)")
        }
    }

    private func sendKeepalive() {
        guard let session, handshakeSucceeded else { return }
        if let packet = try? session.sealPacket(Data()) {
            channel.send(packet)
        }
    }

    private func scheduleKeepalive() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + Double(configuration.keepAliveInterval),
                       repeating: Double(configuration.keepAliveInterval))
        timer.setEventHandler { [weak self] in self?.sendKeepalive() }
        timer.resume()
        keepaliveTimer = timer
    }

    private static func isIPv4(_ packet: Data) -> Bool {
        packet.count >= 20 && (packet[packet.startIndex] >> 4) == 4
    }

    // MARK: - TUN 读写

    private func readPackets() async -> [Data] {
        await withCheckedContinuation { continuation in
            packetFlow.readPackets { packets, _ in
                continuation.resume(returning: packets)
            }
        }
    }

    private func writePackets(_ packets: [Data]) {
        packetFlow.writePackets(packets, withProtocols: [NSNumber(value: AF_INET)])
    }
}
