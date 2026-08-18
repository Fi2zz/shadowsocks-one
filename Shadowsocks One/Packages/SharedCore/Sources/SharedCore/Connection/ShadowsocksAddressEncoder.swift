import Foundation
import Network

enum ShadowsocksAddressEncoder {
    static func encode(host: String, port: UInt16) -> Data {
        let portBytes = withUnsafeBytes(of: port.bigEndian, Array.init)

        if let ipv4 = IPv4Address(host) {
            return Data([0x01] + ipv4.rawValue + portBytes)
        }

        if let ipv6 = IPv6Address(host) {
            return Data([0x04] + ipv6.rawValue + portBytes)
        }

        let domain = Array(host.utf8)
        return Data([0x03, UInt8(domain.count)] + domain + portBytes)
    }
}
