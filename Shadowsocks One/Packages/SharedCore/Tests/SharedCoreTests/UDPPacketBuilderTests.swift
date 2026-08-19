import XCTest
@testable import SharedCore

final class UDPPacketBuilderTests: XCTestCase {
    func testBuildsDNSResponsePacketWithValidChecksums() throws {
        let payload = Data([0x12, 0x34, 0x81, 0x80])
        let packetData = try UDPPacketBuilder.build(
            sourceIP: "8.8.8.8",
            sourcePort: 53,
            destinationIP: "10.0.0.2",
            destinationPort: 49_152,
            payload: payload
        )

        let packet = try IPPacket(data: packetData)
        let udp = try packet.udpSegment()

        XCTAssertEqual(packet.sourceAddress, "8.8.8.8")
        XCTAssertEqual(packet.destinationAddress, "10.0.0.2")
        XCTAssertEqual(packet.protocolNumber, 17)
        XCTAssertEqual(udp.sourcePort, 53)
        XCTAssertEqual(udp.destinationPort, 49_152)
        XCTAssertEqual(udp.payload, payload)
        XCTAssertEqual(
            InternetChecksum.ipv4Header(packet.data.prefix(packet.headerLength)),
            0
        )
        XCTAssertEqual(
            try InternetChecksum.udpSegment(
                sourceIP: packet.sourceAddress,
                destinationIP: packet.destinationAddress,
                segment: packet.payload
            ),
            0
        )
    }
}
