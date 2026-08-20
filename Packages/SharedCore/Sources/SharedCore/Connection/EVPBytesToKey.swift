import CryptoKit
import Foundation

enum EVPBytesToKey {
    static func derive(password: String, keySize: Int) -> Data {
        let passwordData = Data(password.utf8)
        var derived = Data()
        var previous = Data()

        while derived.count < keySize {
            var input = Data()
            input.append(previous)
            input.append(passwordData)
            previous = Data(Insecure.MD5.hash(data: input))
            derived.append(previous)
        }

        return derived.prefix(keySize)
    }
}
