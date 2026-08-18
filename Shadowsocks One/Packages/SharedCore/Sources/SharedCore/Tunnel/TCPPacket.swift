import Foundation

public struct TCPPacket: Sendable {
    public let data: Data
    public let sourcePort: UInt16
    public let destinationPort: UInt16
    public let sequenceNumber: UInt32
    public let acknowledgmentNumber: UInt32
    public let headerLength: Int
    public let flags: UInt16

    public init(data: Data) throws {
        guard data.count >= 20 else {
            throw TunnelPacketError.invalidTCPPacket
        }

        let headerLength = Int(data[12] >> 4) * 4
        guard headerLength >= 20, data.count >= headerLength else {
            throw TunnelPacketError.invalidTCPPacket
        }

        self.data = data
        self.sourcePort = Self.readUInt16(in: data, at: 0)
        self.destinationPort = Self.readUInt16(in: data, at: 2)
        self.sequenceNumber = Self.readUInt32(in: data, at: 4)
        self.acknowledgmentNumber = Self.readUInt32(in: data, at: 8)
        self.headerLength = headerLength
        self.flags = (UInt16(data[12] & 0x01) << 8) | UInt16(data[13])
    }

    public var payload: Data {
        data.subdata(in: headerLength..<data.count)
    }

    public var isFIN: Bool { (flags & 0x01) != 0 }
    public var isSYN: Bool { (flags & 0x02) != 0 }
    public var isRST: Bool { (flags & 0x04) != 0 }
    public var isPSH: Bool { (flags & 0x08) != 0 }
    public var isACK: Bool { (flags & 0x10) != 0 }

    private static func readUInt16(in data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32(in data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }
}
