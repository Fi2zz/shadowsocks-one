import Foundation
import Network

public enum ShadowsocksUDPPacketCodecError: Error, Equatable, Sendable {
    case truncatedDatagram
    case unknownAddressType(UInt8)
}

public struct ShadowsocksUDPDatagram: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let payload: Data

    public init(host: String, port: UInt16, payload: Data) {
        self.host = host
        self.port = port
        self.payload = payload
    }
}

/// SS UDP（SIP004 AEAD）编解码：每个数据报独立加密为
/// `[salt][AEAD(ATYP + 目的地址 + 端口 + payload)]`；每报随机 salt 派生子密钥，nonce 全零。
public struct ShadowsocksUDPPacketCodec: Sendable {
    private let method: CipherMethod
    private let masterKey: Data

    public init(method: CipherMethod, masterKey: Data) {
        self.method = method
        self.masterKey = masterKey
    }

    public func seal(payload: Data, toHost host: String, port: UInt16) throws -> Data {
        let salt = try RandomBytes.generate(count: method.saltSize)
        var plaintext = ShadowsocksAddressEncoder.encode(host: host, port: port)
        plaintext.append(payload)

        let ciphertext = try ShadowsocksAEADCipher.seal(
            plaintext,
            method: method,
            subkey: subkey(for: salt),
            nonce: zeroNonce()
        )
        return salt + ciphertext
    }

    public func open(_ datagram: Data) throws -> ShadowsocksUDPDatagram {
        let minimumSize = method.saltSize + method.tagSize + 3
        guard datagram.count >= minimumSize else {
            throw ShadowsocksUDPPacketCodecError.truncatedDatagram
        }

        let salt = Data(datagram.prefix(method.saltSize))
        let plaintext = try ShadowsocksAEADCipher.open(
            Data(datagram.suffix(from: method.saltSize)),
            method: method,
            subkey: subkey(for: salt),
            nonce: zeroNonce()
        )
        return try Self.parsePlaintext(plaintext)
    }

    private func subkey(for salt: Data) -> Data {
        ShadowsocksSessionKey.makeSubkey(masterKey: masterKey, salt: salt, method: method)
    }

    private func zeroNonce() -> Data {
        Data(count: method.nonceSize)
    }
}

private extension ShadowsocksUDPPacketCodec {
    typealias HeaderReader = (Data) throws -> (host: String, headerLength: Int)

    static let headerReaders: [UInt8: HeaderReader] = [
        0x01: readIPv4Header,
        0x03: readDomainHeader,
        0x04: readIPv6Header,
    ]

    static func parsePlaintext(_ plaintext: Data) throws -> ShadowsocksUDPDatagram {
        guard let atyp = plaintext.first else {
            throw ShadowsocksUDPPacketCodecError.truncatedDatagram
        }
        guard let reader = headerReaders[atyp] else {
            throw ShadowsocksUDPPacketCodecError.unknownAddressType(atyp)
        }

        let header = try reader(plaintext)
        let portOffset = header.headerLength - 2
        let port = UInt16(plaintext[portOffset]) << 8 | UInt16(plaintext[portOffset + 1])
        return ShadowsocksUDPDatagram(
            host: header.host,
            port: port,
            payload: Data(plaintext.suffix(from: header.headerLength))
        )
    }

    static func readIPv4Header(_ data: Data) throws -> (host: String, headerLength: Int) {
        let headerLength = 1 + 4 + 2
        guard data.count >= headerLength else {
            throw ShadowsocksUDPPacketCodecError.truncatedDatagram
        }
        return (data[1...4].map { String($0) }.joined(separator: "."), headerLength)
    }

    static func readDomainHeader(_ data: Data) throws -> (host: String, headerLength: Int) {
        guard data.count >= 2 else {
            throw ShadowsocksUDPPacketCodecError.truncatedDatagram
        }

        let domainLength = Int(data[1])
        let headerLength = 1 + 1 + domainLength + 2
        guard data.count >= headerLength else {
            throw ShadowsocksUDPPacketCodecError.truncatedDatagram
        }
        return (String(decoding: data[2..<(2 + domainLength)], as: UTF8.self), headerLength)
    }

    static func readIPv6Header(_ data: Data) throws -> (host: String, headerLength: Int) {
        let headerLength = 1 + 16 + 2
        guard data.count >= headerLength, let address = IPv6Address(Data(data[1...16])) else {
            throw ShadowsocksUDPPacketCodecError.truncatedDatagram
        }
        return (address.debugDescription, headerLength)
    }
}
