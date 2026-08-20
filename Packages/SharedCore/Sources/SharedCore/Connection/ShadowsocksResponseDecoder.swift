import Foundation

struct ShadowsocksResponseDecoder {
    private let method: CipherMethod
    private let masterKey: Data
    private var buffer = Data()
    private var decoder: ShadowsocksStreamDecoder?

    init(method: CipherMethod, masterKey: Data) {
        self.method = method
        self.masterKey = masterKey
    }

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func readPayloads() throws -> [Data] {
        if decoder == nil {
            guard buffer.count >= method.saltSize else { return [] }
            let salt = buffer.prefix(method.saltSize)
            buffer.removeFirst(method.saltSize)
            decoder = ShadowsocksStreamDecoder(
                method: method,
                subkey: ShadowsocksSessionKey.makeSubkey(
                    masterKey: masterKey,
                    salt: salt,
                    method: method
                )
            )
        }

        decoder?.append(buffer)
        buffer.removeAll(keepingCapacity: true)
        return try decoder?.readPayloads() ?? []
    }
}
