import Foundation

public struct IPPacket: Sendable {
    public let data: Data
    public let headerLength: Int
    public let totalLength: Int
    public let protocolNumber: UInt8
    public let sourceAddress: String
    public let destinationAddress: String

    public init(data: Data) throws {
        guard data.count >= 20, (data[0] >> 4) == 4 else {
            throw TunnelPacketError.invalidIPv4Packet
        }

        let headerLength = Int(data[0] & 0x0F) * 4
        let totalLength = Int(Self.readUInt16(in: data, at: 2))

        guard headerLength >= 20,
              data.count >= headerLength,
              totalLength >= headerLength,
              data.count >= totalLength else {
            throw TunnelPacketError.invalidIPv4Packet
        }

        let packetData = data.prefix(totalLength)
        self.data = Data(packetData)
        self.headerLength = headerLength
        self.totalLength = totalLength
        self.protocolNumber = data[9]
        self.sourceAddress = Self.readIPv4Address(in: data, at: 12)
        self.destinationAddress = Self.readIPv4Address(in: data, at: 16)
    }

    public var payload: Data {
        data.subdata(in: headerLength..<totalLength)
    }

    public func tcpSegment() throws -> TCPPacket {
        guard protocolNumber == 6 else {
            throw TunnelPacketError.invalidTCPPacket
        }

        return try TCPPacket(data: payload)
    }

    public func udpSegment() throws -> UDPPacket {
        guard protocolNumber == 17 else {
            throw TunnelPacketError.invalidUDPPacket
        }

        return try UDPPacket(data: payload)
    }

    private static func readUInt16(in data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readIPv4Address(in data: Data, at offset: Int) -> String {
        (offset..<(offset + 4))
            .map { String(data[$0]) }
            .joined(separator: ".")
    }
}
