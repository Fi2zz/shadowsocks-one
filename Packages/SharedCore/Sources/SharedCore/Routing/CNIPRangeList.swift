import Foundation

public enum CNIPRangeListError: Error, Equatable {
    case invalidCIDR(String)
}

public struct CNIPRangeList: Sendable {
    // 空列表不含任何 CIDR，解析不会失败
    public static let empty = try! CNIPRangeList(ranges: [])

    private let ranges: [IPv4CIDR]

    public init(ranges: [String]) throws {
        self.ranges = try ranges.map(IPv4CIDR.init(cidrNotation:))
    }

    public init(textContent: String) throws {
        let ranges = textContent
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !ranges.isEmpty else {
            throw CNIPRangeListError.invalidCIDR("(empty)")
        }
        try self.init(ranges: ranges)
    }

    public func contains(_ ipString: String) -> Bool {
        guard let address = IPv4Address(ipString) else {
            return false
        }

        return ranges.contains { $0.contains(address) }
    }
}

private struct IPv4CIDR: Sendable {
    private let networkAddress: UInt32
    private let mask: UInt32

    init(cidrNotation: String) throws {
        let components = cidrNotation.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              let address = IPv4Address(String(components[0])),
              let prefixLength = Int(components[1]),
              (0...32).contains(prefixLength) else {
            throw CNIPRangeListError.invalidCIDR(cidrNotation)
        }

        if prefixLength == 0 {
            self.mask = 0
        } else {
            self.mask = UInt32.max << UInt32(32 - prefixLength)
        }
        self.networkAddress = address.rawValue & mask
    }

    func contains(_ address: IPv4Address) -> Bool {
        (address.rawValue & mask) == networkAddress
    }
}

private struct IPv4Address: Sendable {
    let rawValue: UInt32

    init?(_ string: String) {
        let octets = string.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else {
            return nil
        }

        var value: UInt32 = 0
        for octet in octets {
            guard let byte = UInt8(octet) else {
                return nil
            }
            value = (value << 8) | UInt32(byte)
        }

        self.rawValue = value
    }
}
