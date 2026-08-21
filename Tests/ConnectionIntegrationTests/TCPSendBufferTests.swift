import Foundation
import XCTest
@testable import ShadowsocksOnePacketTunnel

final class TCPSendBufferTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testAppendIgnoresEmptyPayload() {
        var buffer = TCPSendBuffer()

        buffer.append(sequenceNumber: 10, payload: Data(), now: t0)

        XCTAssertEqual(buffer.unackedPayloadBytes, 0)
    }

    func testAcknowledgeDropsCoveredSegments() {
        var buffer = TCPSendBuffer()
        buffer.append(sequenceNumber: 10, payload: Data(repeating: 1, count: 5), now: t0)
        buffer.append(sequenceNumber: 15, payload: Data(repeating: 2, count: 5), now: t0)

        buffer.acknowledge(upTo: 15)

        XCTAssertEqual(buffer.pendingSegments.map(\.sequenceNumber), [15])

        buffer.acknowledge(upTo: 20)

        XCTAssertEqual(buffer.unackedPayloadBytes, 0)
    }

    func testAcknowledgeIgnoresStaleAcknowledgment() {
        var buffer = TCPSendBuffer()
        buffer.append(sequenceNumber: 100, payload: Data(repeating: 1, count: 10), now: t0)

        buffer.acknowledge(upTo: 50)

        XCTAssertEqual(buffer.unackedPayloadBytes, 10)
    }

    func testAcknowledgeHandlesSequenceWraparound() {
        var buffer = TCPSendBuffer()
        buffer.append(
            sequenceNumber: UInt32.max - 3,
            payload: Data(repeating: 1, count: 6),
            now: t0
        )

        buffer.acknowledge(upTo: 2)

        XCTAssertEqual(buffer.unackedPayloadBytes, 0)
    }

    func testPopDueSegmentsRespectsRTO() {
        var buffer = TCPSendBuffer()
        buffer.append(sequenceNumber: 1, payload: Data(repeating: 1, count: 4), now: t0)

        XCTAssertTrue(buffer.popDueSegments(now: t0.addingTimeInterval(0.5), rto: 1).isEmpty)

        let due = buffer.popDueSegments(now: t0.addingTimeInterval(1), rto: 1)

        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due.first?.retransmitCount, 1)
    }

    func testPopDueSegmentsAppliesExponentialBackoff() {
        var buffer = TCPSendBuffer()
        buffer.append(sequenceNumber: 1, payload: Data(repeating: 1, count: 4), now: t0)
        _ = buffer.popDueSegments(now: t0.addingTimeInterval(1), rto: 1)

        let early = buffer.popDueSegments(now: t0.addingTimeInterval(2.5), rto: 1)
        let onTime = buffer.popDueSegments(now: t0.addingTimeInterval(3), rto: 1)

        XCTAssertTrue(early.isEmpty)
        XCTAssertEqual(onTime.count, 1)
        XCTAssertEqual(onTime.first?.retransmitCount, 2)
    }

    func testPopDueSegmentsStopsAtMaximumRetransmissions() {
        var buffer = TCPSendBuffer()
        buffer.append(sequenceNumber: 1, payload: Data(repeating: 1, count: 4), now: t0)
        var now = t0

        for _ in 0..<TCPSendBuffer.maximumRetransmissions {
            now = now.addingTimeInterval(100)
            XCTAssertEqual(buffer.popDueSegments(now: now, rto: 1).count, 1)
        }

        now = now.addingTimeInterval(100)
        XCTAssertTrue(buffer.popDueSegments(now: now, rto: 1).isEmpty)
        XCTAssertEqual(buffer.unackedPayloadBytes, 4)
    }

    func testAcknowledgeReturnsRemovedSegmentsForSampling() {
        var buffer = TCPSendBuffer()
        buffer.append(sequenceNumber: 10, payload: Data(repeating: 1, count: 5), now: t0)
        buffer.append(sequenceNumber: 15, payload: Data(repeating: 2, count: 5), now: t0)

        let removed = buffer.acknowledge(upTo: 15)

        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed.first?.sequenceNumber, 10)
        XCTAssertEqual(removed.first?.firstSentAt, t0)
    }

    func testRetransmissionKeepsFirstSentAt() {
        var buffer = TCPSendBuffer()
        buffer.append(sequenceNumber: 1, payload: Data(repeating: 1, count: 4), now: t0)

        let due = buffer.popDueSegments(now: t0.addingTimeInterval(2), rto: 1)

        XCTAssertEqual(due.first?.firstSentAt, t0)
        XCTAssertEqual(due.first?.retransmitCount, 1)
    }
}
