import XCTest
@testable import SharedCore

final class TCPPacketBuilderTests: XCTestCase {
    func testBuildsSYNACKPacket() throws {
        let packetData = try TCPPacketBuilder.build(
            sourceIP: "142.250.72.196",
            sourcePort: 443,
            destinationIP: "10.0.0.2",
            destinationPort: 49_152,
            sequenceNumber: 10,
            acknowledgmentNumber: 101,
            flags: [.syn, .ack],
            payload: Data()
        )

        let packet = try IPPacket(data: packetData)
        let tcp = try packet.tcpSegment()

        XCTAssertEqual(packet.sourceAddress, "142.250.72.196")
        XCTAssertEqual(packet.destinationAddress, "10.0.0.2")
        XCTAssertEqual(packet.totalLength, 40)
        XCTAssertEqual(tcp.sourcePort, 443)
        XCTAssertEqual(tcp.destinationPort, 49_152)
        XCTAssertEqual(tcp.sequenceNumber, 10)
        XCTAssertEqual(tcp.acknowledgmentNumber, 101)
        XCTAssertTrue(tcp.isSYN)
        XCTAssertTrue(tcp.isACK)
        XCTAssertEqual(tcp.payload, Data())
    }

    func testBuildsPSHACKPacketWithPayloadAndValidChecksums() throws {
        let payload = Data("HTTP".utf8)
        let packetData = try TCPPacketBuilder.build(
            sourceIP: "142.250.72.196",
            sourcePort: 443,
            destinationIP: "10.0.0.2",
            destinationPort: 49_152,
            sequenceNumber: 11,
            acknowledgmentNumber: 101,
            flags: [.psh, .ack],
            payload: payload
        )

        let packet = try IPPacket(data: packetData)
        let tcp = try packet.tcpSegment()

        XCTAssertTrue(tcp.isPSH)
        XCTAssertTrue(tcp.isACK)
        XCTAssertEqual(tcp.payload, payload)
        XCTAssertEqual(
            InternetChecksum.ipv4Header(packet.data.prefix(packet.headerLength)),
            0
        )
        XCTAssertEqual(
            try InternetChecksum.tcpSegment(
                sourceIP: packet.sourceAddress,
                destinationIP: packet.destinationAddress,
                segment: packet.payload
            ),
            0
        )
    }

    func testBuildsFINACKPacket() throws {
        let packetData = try TCPPacketBuilder.build(
            sourceIP: "1.1.1.1",
            sourcePort: 443,
            destinationIP: "10.0.0.2",
            destinationPort: 49_152,
            sequenceNumber: 12,
            acknowledgmentNumber: 102,
            flags: [.fin, .ack],
            payload: Data()
        )

        let tcp = try IPPacket(data: packetData).tcpSegment()

        XCTAssertTrue(tcp.isFIN)
        XCTAssertTrue(tcp.isACK)
        XCTAssertFalse(tcp.isPSH)
        XCTAssertEqual(tcp.payload, Data())
    }
}
