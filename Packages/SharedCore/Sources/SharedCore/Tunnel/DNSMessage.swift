import Foundation

public enum DNSMessageError: Error, Equatable, Sendable {
    case invalidMessage
}

public struct DNSMessage: Sendable {
    public struct Question: Equatable, Sendable {
        public let name: String
        public let type: UInt16
        public let recordClass: UInt16
    }

    public struct Answer: Equatable, Sendable {
        public let name: String
        public let type: UInt16
        public let recordClass: UInt16
        public let ttl: UInt32
        public let data: Data

        public var ipv4Address: String? {
            guard type == 1, recordClass == 1, data.count == 4 else {
                return nil
            }

            return data.map(String.init).joined(separator: ".")
        }
    }

    public let questions: [Question]
    public let answers: [Answer]

    public init(data: Data) throws {
        guard data.count >= 12 else {
            throw DNSMessageError.invalidMessage
        }

        let questionCount = Int(Self.readUInt16(in: data, at: 4))
        let answerCount = Int(Self.readUInt16(in: data, at: 6))
        var offset = 12

        var questions = [Question]()
        for _ in 0..<questionCount {
            let name = try Self.readName(in: data, offset: &offset)
            guard offset + 4 <= data.count else {
                throw DNSMessageError.invalidMessage
            }

            questions.append(
                Question(
                    name: name,
                    type: Self.readUInt16(in: data, at: offset),
                    recordClass: Self.readUInt16(in: data, at: offset + 2)
                )
            )
            offset += 4
        }

        var answers = [Answer]()
        for _ in 0..<answerCount {
            let name = try Self.readName(in: data, offset: &offset)
            guard offset + 10 <= data.count else {
                throw DNSMessageError.invalidMessage
            }

            let type = Self.readUInt16(in: data, at: offset)
            let recordClass = Self.readUInt16(in: data, at: offset + 2)
            let ttl = Self.readUInt32(in: data, at: offset + 4)
            let dataLength = Int(Self.readUInt16(in: data, at: offset + 8))
            offset += 10

            guard offset + dataLength <= data.count else {
                throw DNSMessageError.invalidMessage
            }

            answers.append(
                Answer(
                    name: name,
                    type: type,
                    recordClass: recordClass,
                    ttl: ttl,
                    data: data.subdata(in: offset..<(offset + dataLength))
                )
            )
            offset += dataLength
        }

        self.questions = questions
        self.answers = answers
    }

    /// 为查询报文合成 NOERROR 空应答（用于屏蔽 AAAA，强制客户端回落 IPv4）
    public static func emptyResponse(forQuery query: Data) throws -> Data {
        guard query.count >= 12 else {
            throw DNSMessageError.invalidMessage
        }

        let questionCount = Int(readUInt16(in: query, at: 4))
        var offset = 12
        for _ in 0..<questionCount {
            _ = try readName(in: query, offset: &offset)
            guard offset + 4 <= query.count else {
                throw DNSMessageError.invalidMessage
            }
            offset += 4
        }

        var response = Data(query.prefix(offset))
        response[2] |= 0x80
        response[3] = 0x80
        response[6] = 0
        response[7] = 0
        response[8] = 0
        response[9] = 0
        response[10] = 0
        response[11] = 0
        return response
    }

    private static func readUInt16(in data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32(in data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
        | (UInt32(data[offset + 1]) << 16)
        | (UInt32(data[offset + 2]) << 8)
        | UInt32(data[offset + 3])
    }

    private static func readName(in data: Data, offset: inout Int) throws -> String {
        var labels = [String]()
        var cursor = offset
        var jumped = false
        var visitedOffsets = Set<Int>()

        while true {
            guard cursor < data.count else {
                throw DNSMessageError.invalidMessage
            }

            let length = Int(data[cursor])
            if length == 0 {
                if !jumped {
                    offset = cursor + 1
                }
                break
            }

            if (length & 0xC0) == 0xC0 {
                guard cursor + 1 < data.count else {
                    throw DNSMessageError.invalidMessage
                }

                let pointer = ((length & 0x3F) << 8) | Int(data[cursor + 1])
                guard pointer < data.count, visitedOffsets.insert(pointer).inserted else {
                    throw DNSMessageError.invalidMessage
                }

                if !jumped {
                    offset = cursor + 2
                    jumped = true
                }
                cursor = pointer
                continue
            }

            guard (length & 0xC0) == 0 else {
                throw DNSMessageError.invalidMessage
            }

            let labelStart = cursor + 1
            let labelEnd = labelStart + length
            guard labelEnd <= data.count else {
                throw DNSMessageError.invalidMessage
            }

            labels.append(String(decoding: data[labelStart..<labelEnd], as: UTF8.self))
            cursor = labelEnd
            if !jumped {
                offset = cursor
            }
        }

        return labels.joined(separator: ".")
    }
}
