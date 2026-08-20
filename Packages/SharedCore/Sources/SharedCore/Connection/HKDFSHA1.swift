import CryptoKit
import Foundation

enum HKDFSHA1 {
    static func derive(inputKey: Data, salt: Data, info: Data, outputSize: Int) -> Data {
        let saltData = salt.isEmpty ? Data(repeating: 0, count: 20) : salt
        let pseudoRandomKey = HMAC<Insecure.SHA1>.authenticationCode(
            for: inputKey,
            using: SymmetricKey(data: saltData)
        )

        var output = Data()
        var previous = Data()
        var counter: UInt8 = 1

        while output.count < outputSize {
            var input = Data()
            input.append(previous)
            input.append(info)
            input.append(counter)
            previous = Data(
                HMAC<Insecure.SHA1>.authenticationCode(
                    for: input,
                    using: SymmetricKey(data: Data(pseudoRandomKey))
                )
            )
            output.append(previous)
            counter &+= 1
        }

        return output.prefix(outputSize)
    }
}
