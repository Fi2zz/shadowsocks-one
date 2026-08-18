import Foundation

public enum TunnelPacketError: Error, Equatable, Sendable {
    case invalidIPv4Packet
    case invalidTCPPacket
    case invalidUDPPacket
}
