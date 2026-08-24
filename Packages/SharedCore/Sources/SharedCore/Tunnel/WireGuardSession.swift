import Foundation
import CryptoKit

/// 滑动重放窗口：位图记录 highest 之前 2048 个计数器的已见状态。
struct WireGuardReplayWindow {
    private(set) var highest: UInt64 = 0
    private var bits = [UInt64](repeating: 0, count: 32)
    private static let capacity = 2048

    mutating func accept(_ counter: UInt64) -> Bool {
        if counter > highest {
            shift(by: Int(min(counter - highest, UInt64(Self.capacity))))
            highest = counter
            setBit(0)
            return true
        }
        let offset = Int(highest - counter)
        guard offset < Self.capacity else { return false }
        let (word, bit) = locate(offset)
        guard bits[word] & (1 << bit) == 0 else { return false }
        bits[word] |= 1 << bit
        return true
    }

    private func locate(_ offset: Int) -> (Int, UInt64) {
        (offset / 64, UInt64(offset % 64))
    }

    private mutating func setBit(_ offset: Int) {
        let (word, bit) = locate(offset)
        bits[word] |= 1 << bit
    }

    /// 位图整体向高位平移（offset 增大），越界位丢弃。
    private mutating func shift(by n: Int) {
        guard n > 0 else { return }
        if n >= Self.capacity {
            bits = [UInt64](repeating: 0, count: 32)
            return
        }
        let words = n / 64
        let rem = n % 64
        var out = [UInt64](repeating: 0, count: 32)
        for i in stride(from: 31, through: 0, by: -1) {
            var value: UInt64 = 0
            if i - words >= 0 { value |= bits[i - words] << rem }
            if rem > 0 && i - words - 1 >= 0 { value |= bits[i - words - 1] >> (64 - rem) }
            out[i] = value
        }
        bits = out
    }
}

/// WireGuard 传输会话：type=4 数据包加解密 + 计数器 + 重放过滤。
public final class WireGuardSession {
    public let peerIndex: UInt32
    public let localIndex: UInt32
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var replay = WireGuardReplayWindow()
    private let lock = NSLock()

    public init(send: SymmetricKey, receive: SymmetricKey,
         peerIndex: UInt32, localIndex: UInt32) {
        self.sendKey = send
        self.receiveKey = receive
        self.peerIndex = peerIndex
        self.localIndex = localIndex
    }

    /// 加密一个内层 IP 包（空 Data 即 keepalive）。
    public func sealPacket(_ ipPacket: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let counter = sendCounter
        sendCounter += 1
        let payload = try WireGuardCrypto.aeadSeal(
            sendKey, counter: counter, plaintext: ipPacket, aad: Data())
        var packet = Data([4, 0, 0, 0])
        packet += WireGuardHandshake.littleEndian(peerIndex)
        var counterValue = counter.littleEndian
        packet += withUnsafeBytes(of: &counterValue) { Data($0) }
        packet += payload
        return packet
    }

    /// 解密对端数据包；keepalive 返回 nil；重放/校验失败抛错或返回 nil。
    public func openDatagram(_ datagram: Data) throws -> Data? {
        guard datagram.count >= 16 + 16, datagram[datagram.startIndex] == 4 else {
            throw WireGuardError.badPacket("传输包长度/类型非法 \(datagram.count)")
        }
        let bytes = [UInt8](datagram.subdata(in: 8..<16))
        var raw: UInt64 = 0
        for byte in bytes { raw = (raw >> 8) | (UInt64(byte) << 56) }
        let plaintext = try WireGuardCrypto.aeadOpen(
            receiveKey, counter: raw,
            combined: datagram.subdata(in: 16..<datagram.count), aad: Data())
        guard replay.accept(raw) else { return nil }
        return plaintext.isEmpty ? nil : plaintext
    }
}
