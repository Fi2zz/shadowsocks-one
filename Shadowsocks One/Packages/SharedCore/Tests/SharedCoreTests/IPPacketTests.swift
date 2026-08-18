import XCTest
@testable import SharedCore

final class IPPacketTests: XCTestCase {
    func testParsesIPv4TCPPacket() throws {
        let packet = try IPPacket(data: Data([
            0x45, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x40, 0x00,
            0x40, 0x06, 0x00, 0x00, 10, 0, 0, 2,
            142, 250, 72, 196,
            0x1F, 0x90, 0x01, 0xBB, 0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00, 0x50, 0x18, 0xFA, 0xF0,
            0x00, 0x00, 0x00, 0x00,
            0x50, 0x49, 0x4E, 0x47,
        ]))

        let tcp = try packet.tcpSegment()

        XCTAssertEqual(packet.protocolNumber, 6)
        XCTAssertEqual(packet.sourceAddress, "10.0.0.2")
        XCTAssertEqual(packet.destinationAddress, "142.250.72.196")
        XCTAssertEqual(packet.headerLength, 20)
        XCTAssertEqual(packet.totalLength, 44)
        XCTAssertEqual(tcp.sourcePort, 8080)
        XCTAssertEqual(tcp.destinationPort, 443)
        XCTAssertEqual(tcp.sequenceNumber, 1)
        XCTAssertTrue(tcp.isACK)
        XCTAssertTrue(tcp.isPSH)
        XCTAssertEqual(tcp.payload, Data("PING".utf8))
    }

    func testParsesIPv4UDPPacket() throws {
        let packet = try IPPacket(data: Data([
            0x45, 0x00, 0x00, 0x21, 0x00, 0x00, 0x40, 0x00,
            0x40, 0x11, 0x00, 0x00, 10, 0, 0, 2,
            8, 8, 8, 8,
            0x30, 0x39, 0x00, 0x35, 0x00, 0x0D, 0x00, 0x00,
            0x68, 0x65, 0x6C, 0x6C, 0x6F,
        ]))

        let udp = try packet.udpSegment()

        XCTAssertEqual(packet.protocolNumber, 17)
        XCTAssertEqual(packet.destinationAddress, "8.8.8.8")
        XCTAssertEqual(udp.sourcePort, 12345)
        XCTAssertEqual(udp.destinationPort, 53)
        XCTAssertEqual(udp.length, 13)
        XCTAssertEqual(udp.payload, Data("hello".utf8))
    }

    func testRejectsTruncatedIPv4Packet() {
        XCTAssertThrowsError(try IPPacket(data: Data([0x45, 0x00, 0x00]))) { error in
            XCTAssertEqual(error as? TunnelPacketError, .invalidIPv4Packet)
        }
    }
}
