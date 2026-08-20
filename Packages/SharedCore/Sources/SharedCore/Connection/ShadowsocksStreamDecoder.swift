import Foundation

struct ShadowsocksStreamDecoder {
    private let method: CipherMethod
    private let subkey: Data
    private var nonceCounter = NonceCounter()
    private var buffer = Data()
    private var expectedPayloadLength: Int?

    init(method: CipherMethod, subkey: Data) {
        self.method = method
        self.subkey = subkey
    }

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func readPayloads() throws -> [Data] {
        var payloads: [Data] = []

        while true {
            if expectedPayloadLength == nil {
                let lengthSize = 2 + method.tagSize
                guard buffer.count >= lengthSize else { return payloads }
                let encryptedLength = buffer.prefix(lengthSize)
                buffer.removeFirst(lengthSize)
                let lengthData = try ShadowsocksAEADCipher.open(
                    encryptedLength,
                    method: method,
                    subkey: subkey,
                    nonce: nonceCounter.next()
                )
                let length = UInt16(lengthData[0]) << 8 | UInt16(lengthData[1])
                expectedPayloadLength = Int(length)
            }

            guard let expectedPayloadLength else { return payloads }
            let payloadSize = expectedPayloadLength + method.tagSize
            guard buffer.count >= payloadSize else { return payloads }
            let encryptedPayload = buffer.prefix(payloadSize)
            buffer.removeFirst(payloadSize)
            let payload = try ShadowsocksAEADCipher.open(
                encryptedPayload,
                method: method,
                subkey: subkey,
                nonce: nonceCounter.next()
            )
            payloads.append(payload)
            self.expectedPayloadLength = nil
        }
    }
}
