import Foundation
import SharedCore

enum TCPFlowEvent: Equatable {
    case outboundSYN
    case outboundACK
    case outboundPayload(Int)
    case inboundPayload(Data)
    case outboundFIN
    case outboundRST
}

struct TCPFlowResponse: Equatable {
    let flags: Set<TCPPacketFlag>
    let sequenceNumber: UInt32
    let acknowledgmentNumber: UInt32
    let payload: Data
}
