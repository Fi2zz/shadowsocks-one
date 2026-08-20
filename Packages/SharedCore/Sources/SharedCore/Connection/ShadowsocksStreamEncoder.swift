import Foundation

struct ShadowsocksStreamEncoder {
    private let method: CipherMethod
    private let subkey: Data
    private var nonceCounter = NonceCounter()

    init(method: CipherMethod, subkey: Data) {
        self.method = method
        self.subkey = subkey
    }

    mutating func encodeChunk(_ payload: Data) throws -> Data {
        guard payload.count < 0x4000 else {
            throw ShadowsocksCryptoError.unsupportedPayloadLength
        }

        let length = UInt16(payload.count).bigEndian
        let lengthData = withUnsafeBytes(of: length) { Data($0) }
        let encryptedLength = try ShadowsocksAEADCipher.seal(
            lengthData,
            method: method,
            subkey: subkey,
            nonce: nonceCounter.next()
        )
        let encryptedPayload = try ShadowsocksAEADCipher.seal(
            payload,
            method: method,
            subkey: subkey,
            nonce: nonceCounter.next()
        )

        return encryptedLength + encryptedPayload
    }
}
