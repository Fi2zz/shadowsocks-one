import Foundation

public enum TCPPacketFlag: UInt16, Hashable, Sendable {
    case fin = 0x01
    case syn = 0x02
    case rst = 0x04
    case psh = 0x08
    case ack = 0x10
}

public enum TCPPacketBuilder {
    public static func build(
        sourceIP: String,
        sourcePort: UInt16,
        destinationIP: String,
        destinationPort: UInt16,
        sequenceNumber: UInt32,
        acknowledgmentNumber: UInt32,
        flags: Set<TCPPacketFlag>,
        payload: Data
    ) throws -> Data {
        let sourceAddress = try IPv4AddressCodec.parse(sourceIP)
        let destinationAddress = try IPv4AddressCodec.parse(destinationIP)

        let ipHeaderLength = 20
        let tcpHeaderLength = 20
        let totalLength = ipHeaderLength + tcpHeaderLength + payload.count

        var packet = Data(count: totalLength)

        packet[0] = 0x45
        packet[1] = 0x00
        packet.writeUInt16(UInt16(totalLength), at: 2)
        packet.writeUInt16(0, at: 4)
        packet.writeUInt16(0x4000, at: 6)
        packet[8] = 64
        packet[9] = 6
        packet.writeBytes(sourceAddress, at: 12)
        packet.writeBytes(destinationAddress, at: 16)

        packet.writeUInt16(sourcePort, at: 20)
        packet.writeUInt16(destinationPort, at: 22)
        packet.writeUInt32(sequenceNumber, at: 24)
        packet.writeUInt32(acknowledgmentNumber, at: 28)
        packet[32] = 0x50
        packet[33] = UInt8(flags.reduce(0) { $0 | $1.rawValue })
        packet.writeUInt16(0xFFFF, at: 34)
        packet.writeUInt16(0, at: 36)
        packet.writeUInt16(0, at: 38)
        packet.replaceSubrange(40..<totalLength, with: payload)

        let ipChecksum = InternetChecksum.ipv4Header(packet.prefix(ipHeaderLength))
        packet.writeUInt16(ipChecksum, at: 10)

        let tcpChecksum = try InternetChecksum.tcpSegment(
            sourceIP: sourceIP,
            destinationIP: destinationIP,
            segment: packet.suffix(from: ipHeaderLength)
        )
        packet.writeUInt16(tcpChecksum, at: 36)

        return packet
    }
}

private extension Data {
    mutating func writeBytes(_ bytes: [UInt8], at offset: Int) {
        replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    mutating func writeUInt16(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8((value >> 8) & 0xFF)
        self[offset + 1] = UInt8(value & 0xFF)
    }

    mutating func writeUInt32(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8((value >> 24) & 0xFF)
        self[offset + 1] = UInt8((value >> 16) & 0xFF)
        self[offset + 2] = UInt8((value >> 8) & 0xFF)
        self[offset + 3] = UInt8(value & 0xFF)
    }
}
