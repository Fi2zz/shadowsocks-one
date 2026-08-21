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

    func testBuildsEmptyResponsePreservingQueryContext() throws {
        let query = Data([
            0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x03, 0x77, 0x77, 0x77,
            0x07, 0x65, 0x78, 0x61, 0x6D, 0x70, 0x6C, 0x65,
            0x03, 0x63, 0x6F, 0x6D, 0x00,
            0x00, 0x1C, 0x00, 0x01,
        ])

        let response = try DNSMessage.emptyResponse(forQuery: query)

        XCTAssertEqual(response[0], 0x12)
        XCTAssertEqual(response[1], 0x34)
        XCTAssertEqual(response[2] & 0x80, 0x80)
        XCTAssertEqual(response[2] & 0x01, 0x01)
        XCTAssertEqual(response[3] & 0x80, 0x80)
        XCTAssertEqual(response[6], 0x00)
        XCTAssertEqual(response[7], 0x00)

        let message = try DNSMessage(data: response)
        XCTAssertEqual(message.questions.first?.name, "www.example.com")
        XCTAssertEqual(message.questions.first?.type, 28)
        XCTAssertTrue(message.answers.isEmpty)
    }
}
