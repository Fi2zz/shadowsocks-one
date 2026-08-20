import Foundation

enum ShadowsocksRequestEncoder {
    static func encode(config: ConnectionConfig, target: ConnectionProbeTarget) throws -> Data {
        let masterKey = ShadowsocksSessionKey.makeMasterKey(config: config)
        let salt = try RandomBytes.generate(count: config.method.saltSize)
        let subkey = ShadowsocksSessionKey.makeSubkey(
            masterKey: masterKey,
            salt: salt,
            method: config.method
        )
        var encoder = ShadowsocksStreamEncoder(method: config.method, subkey: subkey)
        var data = Data()
        data.append(salt)
        data.append(try encoder.encodeChunk(ShadowsocksAddressEncoder.encode(host: target.host, port: target.port)))
        data.append(try encoder.encodeChunk(target.requestData))
        return data
    }
}
