import Foundation

enum ShadowsocksSessionKey {
    static let info = Data("ss-subkey".utf8)

    static func makeMasterKey(config: ConnectionConfig) -> Data {
        EVPBytesToKey.derive(password: config.password, keySize: config.method.keySize)
    }

    static func makeSubkey(masterKey: Data, salt: Data, method: CipherMethod) -> Data {
        HKDFSHA1.derive(
            inputKey: masterKey,
            salt: salt,
            info: info,
            outputSize: method.keySize
        )
    }
}
