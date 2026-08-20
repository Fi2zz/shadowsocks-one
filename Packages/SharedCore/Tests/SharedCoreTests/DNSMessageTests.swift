import XCTest
@testable import SharedCore

final class DNSMessageTests: XCTestCase {
    func testParsesQuestionsAndCompressedAAnswers() throws {
        let message = try DNSMessage(data: Data([
            0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00,
            0x07, 0x65, 0x78, 0x61, 0x6D, 0x70, 0x6C, 0x65,
            0x03, 0x63, 0x6F, 0x6D, 0x00,
            0x00, 0x01, 0x00, 0x01,
            0xC0, 0x0C,
            0x00, 0x01, 0x00, 0x01,
            0x00, 0x00, 0x01, 0x2C,
            0x00, 0x04, 93, 184, 216, 34,
        ]))

        XCTAssertEqual(message.questions.count, 1)
        XCTAssertEqual(message.questions.first?.name, "example.com")
        XCTAssertEqual(message.questions.first?.type, 1)
        XCTAssertEqual(message.answers.count, 1)
        XCTAssertEqual(message.answers.first?.name, "example.com")
        XCTAssertEqual(message.answers.first?.ttl, 300)
        XCTAssertEqual(message.answers.first?.ipv4Address, "93.184.216.34")
    }
}
