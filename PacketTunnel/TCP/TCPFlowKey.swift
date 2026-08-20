import Foundation
import SharedCore

struct TCPFlowKey: Hashable, Sendable {
    let sourceAddress: String
    let sourcePort: UInt16
    let destinationAddress: String
    let destinationPort: UInt16

    init(packet: IPPacket) throws {
        let tcp = try packet.tcpSegment()
        self.init(packet: packet, tcp: tcp)
    }

    init(packet: IPPacket, tcp: TCPPacket) {
        self.sourceAddress = packet.sourceAddress
        self.sourcePort = tcp.sourcePort
        self.destinationAddress = packet.destinationAddress
        self.destinationPort = tcp.destinationPort
    }
}
