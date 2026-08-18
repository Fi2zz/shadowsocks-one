import XCTest
import SharedCore
@testable import ShadowsocksOnePacketTunnel

final class TCPFlowStateTests: XCTestCase {
    func testConsumesClientSYNAndProducesSYNACK() throws {
        var state = makeInitialState()

        let response = try state.consumeOutboundSYN()

        XCTAssertEqual(response.flags, [.syn, .ack])
        XCTAssertEqual(response.sequenceNumber, 1)
        XCTAssertEqual(response.acknowledgmentNumber, 101)
        XCTAssertEqual(state.phase, .synReceived)
        XCTAssertEqual(state.localSequenceNumber, 2)
        XCTAssertEqual(state.nextExpectedClientSequence, 101)
    }

    func testHandshakeACKTransitionsToEstablished() throws {
        var state = makeInitialState()
        _ = try state.consumeOutboundSYN()

        let response = try state.consumeOutboundACK()

        XCTAssertEqual(response.flags, [.ack])
        XCTAssertEqual(response.sequenceNumber, 2)
        XCTAssertEqual(response.acknowledgmentNumber, 101)
        XCTAssertEqual(state.phase, .established)
        XCTAssertEqual(state.localSequenceNumber, 2)
    }

    func testBuildsPSHACKForInboundPayload() throws {
        var state = try makeEstablishedState()

        let response = try state.consumeInboundPayload(Data("HTTP".utf8))

        XCTAssertEqual(response.flags, [.psh, .ack])
        XCTAssertEqual(response.sequenceNumber, 2)
        XCTAssertEqual(response.acknowledgmentNumber, 101)
        XCTAssertEqual(response.payload, Data("HTTP".utf8))
        XCTAssertEqual(state.phase, .established)
        XCTAssertEqual(state.localSequenceNumber, 6)
    }

    func testConsumesClientFINAndClosesAfterFinalACK() throws {
        var state = try makeEstablishedState()

        let finResponse = try state.consumeOutboundFIN()

        XCTAssertEqual(finResponse.flags, [.fin, .ack])
        XCTAssertEqual(finResponse.sequenceNumber, 2)
        XCTAssertEqual(finResponse.acknowledgmentNumber, 102)
        XCTAssertEqual(state.phase, .finWaiting)
        XCTAssertEqual(state.localSequenceNumber, 3)
        XCTAssertEqual(state.nextExpectedClientSequence, 102)

        let finalAckResponse = try state.consumeOutboundACK()

        XCTAssertEqual(finalAckResponse.flags, [.ack])
        XCTAssertEqual(finalAckResponse.sequenceNumber, 3)
        XCTAssertEqual(finalAckResponse.acknowledgmentNumber, 102)
        XCTAssertEqual(state.phase, .closed)
    }

    func testConsumesClientRSTAndClosesFlow() throws {
        var state = try makeEstablishedState()

        let response = try state.consumeOutboundRST()

        XCTAssertEqual(response.flags, [.rst])
        XCTAssertEqual(response.sequenceNumber, 2)
        XCTAssertEqual(response.acknowledgmentNumber, 101)
        XCTAssertEqual(state.phase, .closed)
    }

    func testRejectsInboundPayloadBeforeHandshakeCompletes() throws {
        var state = makeInitialState()

        XCTAssertThrowsError(try state.consumeInboundPayload(Data("HTTP".utf8))) { error in
            XCTAssertEqual(
                error as? TCPFlowStateError,
                .invalidTransition(
                    phase: .initial,
                    event: .inboundPayload(Data("HTTP".utf8))
                )
            )
        }
    }

    private func makeInitialState() -> TCPFlowState {
        TCPFlowState.initial(
            clientIP: "10.0.0.2",
            clientPort: 49_152,
            remoteIP: "142.250.72.196",
            remotePort: 443,
            clientSequenceNumber: 100
        )
    }

    private func makeEstablishedState() throws -> TCPFlowState {
        var state = makeInitialState()
        _ = try state.consumeOutboundSYN()
        _ = try state.consumeOutboundACK()
        return state
    }
}
