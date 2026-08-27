import Foundation
import SharedCore
@testable import ShadowsocksBrowserPacketTunnel

final class UDPRelaySpy: UDPFlowRelaying {
    let key: UDPFlowKey
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var forwardedPayloads: [Data] = []
    var onInboundDatagram: (@Sendable (Data) async -> Void)?
    var onClosed: (@Sendable () async -> Void)?

    init(key: UDPFlowKey) {
        self.key = key
    }

    func start() async throws {
        startCalls += 1
    }

    func forwardOutboundPayload(_ payload: Data) async throws {
        forwardedPayloads.append(payload)
    }

    func stop() async {
        stopCalls += 1
    }

    func emitInbound(_ data: Data) async {
        await onInboundDatagram?(data)
    }
}

final class UDPRelayFactorySpy: @unchecked Sendable {
    private let lock = NSLock()
    private var relays: [UDPRelaySpy] = []

    var createdRelayCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return relays.count
    }

    var totalStartCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return relays.reduce(0) { $0 + $1.startCalls }
    }

    var totalStopCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return relays.reduce(0) { $0 + $1.stopCalls }
    }

    var allForwardedPayloads: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return relays.flatMap(\.forwardedPayloads)
    }

    var firstRelayForwardedPayloads: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return relays.first?.forwardedPayloads ?? []
    }

    var firstRelay: UDPRelaySpy? {
        lock.lock()
        defer { lock.unlock() }
        return relays.first
    }

    func makeRelay(key: UDPFlowKey) throws -> any UDPFlowRelaying {
        let relay = UDPRelaySpy(key: key)
        lock.lock()
        relays.append(relay)
        lock.unlock()
        return relay
    }
}

final class TunnelPacketWriterSpy: TunnelPacketWriting {
    private(set) var writtenPackets: [Data] = []
    private(set) var writtenProtocols: [NSNumber] = []

    func write(_ packets: [Data], protocols: [NSNumber]) {
        writtenPackets.append(contentsOf: packets)
        writtenProtocols.append(contentsOf: protocols)
    }
}

func makeUDPPacket(
    destination: String,
    destinationPort: UInt16,
    payload: String,
    source: String = "10.0.0.2",
    sourcePort: UInt16 = 49_152
) -> IPPacket {
    let payloadBytes = Array(payload.utf8)
    let length = UInt16(8 + payloadBytes.count)
    let udpHeader: [UInt8] = [
        UInt8(sourcePort >> 8),
        UInt8(sourcePort & 0x00FF),
        UInt8(destinationPort >> 8),
        UInt8(destinationPort & 0x00FF),
        UInt8(length >> 8),
        UInt8(length & 0x00FF),
        0x00,
        0x00,
    ]

    return try! IPPacket(
        data: makeUDPIPv4Packet(
            sourceAddress: source.split(separator: ".").compactMap { UInt8($0) },
            destinationAddress: destination.split(separator: ".").compactMap { UInt8($0) },
            transportPayload: udpHeader + payloadBytes
        )
    )
}

private func makeUDPIPv4Packet(
    sourceAddress: [UInt8],
    destinationAddress: [UInt8],
    transportPayload: [UInt8]
) -> Data {
    let totalLength = UInt16(20 + transportPayload.count)
    let header: [UInt8] = [
        0x45,
        0x00,
        UInt8(totalLength >> 8),
        UInt8(totalLength & 0x00FF),
        0x00, 0x00,
        0x40, 0x00,
        0x40,
        17,
        0x00, 0x00,
    ] + sourceAddress + destinationAddress

    return Data(header + transportPayload)
}
