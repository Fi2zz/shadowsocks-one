import Foundation
import Security

enum RandomBytes {
    static func generate(count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }

        guard status == errSecSuccess else {
            throw ShadowsocksCryptoError.randomBytesFailed
        }

        return bytes
    }
}
