import Foundation
import SharedCore

struct UDPFlowKey: Hashable, Sendable {
    let sourceAddress: String
    let sourcePort: UInt16
    let destinationAddress: String
    let destinationPort: UInt16

    init(packet: IPPacket) throws {
        try self.init(packet: packet, udp: packet.udpSegment())
    }

    init(packet: IPPacket, udp: UDPPacket) {
        self.sourceAddress = packet.sourceAddress
        self.sourcePort = udp.sourcePort
        self.destinationAddress = packet.destinationAddress
        self.destinationPort = udp.destinationPort
    }
}
