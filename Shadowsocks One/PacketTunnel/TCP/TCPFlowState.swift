import Foundation
import SharedCore

enum TCPFlowPhase: Equatable {
    case initial
    case synReceived
    case established
    case finWaiting
    case closed
}

enum TCPFlowStateError: Error, Equatable {
    case invalidTransition(phase: TCPFlowPhase, event: TCPFlowEvent)
}

struct TCPFlowState {
    var phase: TCPFlowPhase
    var localSequenceNumber: UInt32
    var nextExpectedClientSequence: UInt32
    let clientIP: String
    let clientPort: UInt16
    let remoteIP: String
    let remotePort: UInt16

    static func initial(
        clientIP: String,
        clientPort: UInt16,
        remoteIP: String,
        remotePort: UInt16,
        clientSequenceNumber: UInt32
    ) -> TCPFlowState {
        TCPFlowState(
            phase: .initial,
            localSequenceNumber: 1,
            nextExpectedClientSequence: clientSequenceNumber,
            clientIP: clientIP,
            clientPort: clientPort,
            remoteIP: remoteIP,
            remotePort: remotePort
        )
    }

    mutating func consume(_ event: TCPFlowEvent) throws -> TCPFlowResponse {
        switch (phase, event) {
        case (.initial, .outboundSYN):
            phase = .synReceived
            nextExpectedClientSequence &+= 1
            let response = makeResponse(flags: [.syn, .ack])
            localSequenceNumber &+= 1
            return response

        case (.synReceived, .outboundACK):
            phase = .established
            return makeResponse(flags: [.ack])

        case (.established, .inboundPayload(let payload)):
            let flags: Set<TCPPacketFlag> = payload.isEmpty ? [.ack] : [.psh, .ack]
            let response = makeResponse(flags: flags, payload: payload)
            localSequenceNumber &+= UInt32(payload.count)
            return response

        case (.established, .outboundFIN):
            phase = .finWaiting
            nextExpectedClientSequence &+= 1
            let response = makeResponse(flags: [.fin, .ack])
            localSequenceNumber &+= 1
            return response

        case (.finWaiting, .outboundACK):
            phase = .closed
            return makeResponse(flags: [.ack])

        case (_, .outboundRST):
            phase = .closed
            return makeResponse(flags: [.rst])

        default:
            throw TCPFlowStateError.invalidTransition(phase: phase, event: event)
        }
    }

    mutating func consumeOutboundSYN() throws -> TCPFlowResponse {
        try consume(.outboundSYN)
    }

    mutating func consumeOutboundACK() throws -> TCPFlowResponse {
        try consume(.outboundACK)
    }

    mutating func consumeInboundPayload(_ payload: Data) throws -> TCPFlowResponse {
        try consume(.inboundPayload(payload))
    }

    mutating func consumeOutboundFIN() throws -> TCPFlowResponse {
        try consume(.outboundFIN)
    }

    mutating func consumeOutboundRST() throws -> TCPFlowResponse {
        try consume(.outboundRST)
    }

    private func makeResponse(
        flags: Set<TCPPacketFlag>,
        payload: Data = Data()
    ) -> TCPFlowResponse {
        TCPFlowResponse(
            flags: flags,
            sequenceNumber: localSequenceNumber,
            acknowledgmentNumber: nextExpectedClientSequence,
            payload: payload
        )
    }
}
