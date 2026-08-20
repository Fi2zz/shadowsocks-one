import CryptoKit
import Foundation

enum ShadowsocksAEADCipher {
    static func seal(
        _ plaintext: Data,
        method: CipherMethod,
        subkey: Data,
        nonce: Data
    ) throws -> Data {
        let key = SymmetricKey(data: subkey)

        switch method {
        case .aes128GCM, .aes256GCM:
            let box = try AES.GCM.seal(plaintext, using: key, nonce: try AES.GCM.Nonce(data: nonce))
            return box.ciphertext + box.tag
        case .chacha20IETFPoly1305:
            let box = try ChaChaPoly.seal(plaintext, using: key, nonce: try ChaChaPoly.Nonce(data: nonce))
            return box.ciphertext + box.tag
        }
    }

    static func open(_ ciphertext: Data, method: CipherMethod, subkey: Data, nonce: Data) throws -> Data {
        let key = SymmetricKey(data: subkey)
        let tagIndex = ciphertext.count - method.tagSize
        let body = ciphertext.prefix(tagIndex)
        let tag = ciphertext.suffix(method.tagSize)

        switch method {
        case .aes128GCM, .aes256GCM:
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: body,
                tag: tag
            )
            return try AES.GCM.open(box, using: key)
        case .chacha20IETFPoly1305:
            let box = try ChaChaPoly.SealedBox(
                nonce: try ChaChaPoly.Nonce(data: nonce),
                ciphertext: body,
                tag: tag
            )
            return try ChaChaPoly.open(box, using: key)
        }
    }
}
