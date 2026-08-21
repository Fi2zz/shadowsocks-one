import XCTest
@testable import SharedCore

final class ShadowsocksAddressEncoderTests: XCTestCase {
    func testEncodesIPv4AddressWithATYP1() {
        let encoded = ShadowsocksAddressEncoder.encode(host: "142.250.72.196", port: 443)

        XCTAssertEqual(Array(encoded), [0x01, 142, 250, 72, 196, 0x01, 0xBB])
    }

    func testEncodesDomainWithATYP3() {
        let encoded = ShadowsocksAddressEncoder.encode(host: "www.google.com", port: 443)

        let expected = [0x03, 0x0E] + Array("www.google.com".utf8) + [0x01, 0xBB]
        XCTAssertEqual(Array(encoded), expected)
    }
}
