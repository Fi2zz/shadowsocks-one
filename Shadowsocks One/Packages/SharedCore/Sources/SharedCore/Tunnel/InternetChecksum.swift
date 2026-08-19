import Foundation

enum IPv4AddressCodec {
    static func parse(_ address: String) throws -> [UInt8] {
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else {
            throw TunnelPacketError.invalidIPv4Packet
        }

        return try octets.map { component in
            guard let octet = UInt8(component) else {
                throw TunnelPacketError.invalidIPv4Packet
            }
            return octet
        }
    }
}

enum InternetChecksum {
    static func ipv4Header<HeaderBytes: DataProtocol>(_ header: HeaderBytes) -> UInt16 {
        checksum(bytes: Array(header))
    }

    static func tcpSegment<SegmentBytes: DataProtocol>(
        sourceIP: String,
        destinationIP: String,
        segment: SegmentBytes
    ) throws -> UInt16 {
        try transportSegment(
            sourceIP: sourceIP,
            destinationIP: destinationIP,
            protocolNumber: 6,
            segment: segment
        )
    }

    static func udpSegment<SegmentBytes: DataProtocol>(
        sourceIP: String,
        destinationIP: String,
        segment: SegmentBytes
    ) throws -> UInt16 {
        try transportSegment(
            sourceIP: sourceIP,
            destinationIP: destinationIP,
            protocolNumber: 17,
            segment: segment
        )
    }

    private static func transportSegment<SegmentBytes: DataProtocol>(
        sourceIP: String,
        destinationIP: String,
        protocolNumber: UInt8,
        segment: SegmentBytes
    ) throws -> UInt16 {
        let sourceAddress = try IPv4AddressCodec.parse(sourceIP)
        let destinationAddress = try IPv4AddressCodec.parse(destinationIP)
        let segmentBytes = Array(segment)
        let segmentLength = UInt16(segmentBytes.count)

        var pseudoHeader = [UInt8]()
        pseudoHeader.reserveCapacity(12 + segmentBytes.count + (segmentBytes.count % 2))
        pseudoHeader.append(contentsOf: sourceAddress)
        pseudoHeader.append(contentsOf: destinationAddress)
        pseudoHeader.append(0)
        pseudoHeader.append(protocolNumber)
        pseudoHeader.append(UInt8((segmentLength >> 8) & 0xFF))
        pseudoHeader.append(UInt8(segmentLength & 0xFF))
        pseudoHeader.append(contentsOf: segmentBytes)

        return checksum(bytes: pseudoHeader)
    }

    private static func checksum(bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0

        while index + 1 < bytes.count {
            let word = (UInt32(bytes[index]) << 8) | UInt32(bytes[index + 1])
            sum += word
            index += 2
        }

        if index < bytes.count {
            sum += UInt32(bytes[index]) << 8
        }

        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }

        return ~UInt16(sum & 0xFFFF)
    }
}
