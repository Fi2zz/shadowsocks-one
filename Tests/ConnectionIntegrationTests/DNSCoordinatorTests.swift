import Foundation
import XCTest
import SharedCore
@testable import ShadowsocksBrowserPacketTunnel

final class DNSCoordinatorTests: XCTestCase {
    func testAnswersAAAAQueryWithEmptyResponseWithoutUpstream() async throws {
        let upstream = DNSUpstreamSpy()
        let writer = DNSPacketWriterSpy()
        let coordinator = makeCoordinator(upstream: upstream, packetWriter: writer)

        try await coordinator.handle(
            makeQueryPacket(host: "www.example.com", type: 28)
        )

        XCTAssertEqual(upstream.callCount, 0)
        let response = try XCTUnwrap(writer.packets.first)
        let message = try DNSMessage(data: response.udpSegment().payload)
        XCTAssertEqual(message.questions.first?.name, "www.example.com")
        XCTAssertEqual(message.questions.first?.type, 28)
        XCTAssertTrue(message.answers.isEmpty)
        XCTAssertEqual(response.sourceAddress, "223.5.5.5")
    }

    func testForwardsAQueryToUpstream() async throws {
        let upstream = DNSUpstreamSpy()
        let writer = DNSPacketWriterSpy()
        let coordinator = makeCoordinator(upstream: upstream, packetWriter: writer)

        try await coordinator.handle(
            makeQueryPacket(host: "www.example.com", type: 1)
        )

        XCTAssertEqual(upstream.callCount, 1)
        XCTAssertEqual(writer.packets.count, 1)
    }

    private func makeCoordinator(
        upstream: DNSUpstreamSpy,
        packetWriter: DNSPacketWriterSpy
    ) -> DNSCoordinator {
        DNSCoordinator(
            cache: DNSCache(),
            whitelist: [],
            upstreamClient: upstream,
            packetWriter: packetWriter
        )
    }

    private func makeQueryPacket(host: String, type: UInt16) throws -> IPPacket {
        var payload = Data([
            0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])
        for label in host.split(separator: ".") {
            payload.append(UInt8(label.count))
            payload.append(contentsOf: label.utf8)
        }
        payload.append(0)
        payload.append(UInt8(type >> 8))
        payload.append(UInt8(type & 0xFF))
        payload.append(contentsOf: [0x00, 0x01])

        let packet = try UDPPacketBuilder.build(
            sourceIP: "10.0.0.2",
            sourcePort: 53_000,
            destinationIP: "223.5.5.5",
            destinationPort: 53,
            payload: payload
        )
        return try IPPacket(data: packet)
    }
}

private final class DNSUpstreamSpy: DNSPayloadQuerying, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func query(serverIP: String, payload: Data) async throws -> Data {
        lock.lock()
        calls += 1
        lock.unlock()
        return payload
    }
}

private final class DNSPacketWriterSpy: TunnelPacketWriting {
    private let lock = NSLock()
    private var written: [Data] = []

    var packets: [IPPacket] {
        lock.lock()
        defer { lock.unlock() }
        return written.compactMap { try? IPPacket(data: $0) }
    }

    func write(_ packets: [Data], protocols: [NSNumber]) {
        lock.lock()
        written.append(contentsOf: packets)
        lock.unlock()
    }
}
