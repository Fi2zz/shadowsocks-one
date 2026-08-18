import Foundation

public struct UDPPacket: Sendable {
    public let data: Data
    public let sourcePort: UInt16
    public let destinationPort: UInt16
    public let length: Int

    public init(data: Data) throws {
        guard data.count >= 8 else {
            throw TunnelPacketError.invalidUDPPacket
        }

        let length = Int(Self.readUInt16(in: data, at: 4))
        guard length >= 8, data.count >= length else {
            throw TunnelPacketError.invalidUDPPacket
        }

        self.data = Data(data.prefix(length))
        self.sourcePort = Self.readUInt16(in: data, at: 0)
        self.destinationPort = Self.readUInt16(in: data, at: 2)
        self.length = length
    }

    public var payload: Data {
        data.subdata(in: 8..<length)
    }

    private static func readUInt16(in data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }
}
