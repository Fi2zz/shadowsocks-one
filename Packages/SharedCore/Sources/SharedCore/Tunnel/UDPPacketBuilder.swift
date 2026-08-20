import Foundation

public enum UDPPacketBuilder {
    public static func build(
        sourceIP: String,
        sourcePort: UInt16,
        destinationIP: String,
        destinationPort: UInt16,
        payload: Data
    ) throws -> Data {
        let sourceAddress = try IPv4AddressCodec.parse(sourceIP)
        let destinationAddress = try IPv4AddressCodec.parse(destinationIP)

        let ipHeaderLength = 20
        let udpLength = 8 + payload.count
        let totalLength = ipHeaderLength + udpLength
        var packet = Data(count: totalLength)

        packet[0] = 0x45
        packet[1] = 0x00
        packet.writeUInt16(UInt16(totalLength), at: 2)
        packet.writeUInt16(0, at: 4)
        packet.writeUInt16(0x4000, at: 6)
        packet[8] = 64
        packet[9] = 17
        packet.writeBytes(sourceAddress, at: 12)
        packet.writeBytes(destinationAddress, at: 16)

        packet.writeUInt16(sourcePort, at: 20)
        packet.writeUInt16(destinationPort, at: 22)
        packet.writeUInt16(UInt16(udpLength), at: 24)
        packet.writeUInt16(0, at: 26)
        packet.replaceSubrange(28..<totalLength, with: payload)

        let ipChecksum = InternetChecksum.ipv4Header(packet.prefix(ipHeaderLength))
        packet.writeUInt16(ipChecksum, at: 10)

        var udpChecksum = try InternetChecksum.udpSegment(
            sourceIP: sourceIP,
            destinationIP: destinationIP,
            segment: packet.suffix(from: ipHeaderLength)
        )
        if udpChecksum == 0 {
            udpChecksum = 0xFFFF
        }
        packet.writeUInt16(udpChecksum, at: 26)

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
}
