import Foundation

/// BLAKE2s（RFC 7693），WireGuard 哈希/MAC 基础原语。
/// 向量已对齐 hashlib.blake2s：含 keyed 模式与多块输入。
struct Blake2s {
    static let blockSize = 64
    private static let iv: [UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
    ]
    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    let digestLength: Int
    private let key: [UInt8]

    init(digestLength: Int = 32, key: [UInt8] = []) {
        precondition((1...32).contains(digestLength))
        precondition(key.count <= 32)
        self.digestLength = digestLength
        self.key = key
    }

    func hash(_ message: [UInt8]) -> [UInt8] {
        var h = Self.iv
        h[0] ^= UInt32(digestLength) | (UInt32(key.count) << 8) | 0x01010000

        var data: [UInt8] = key.isEmpty ? [] : key + [UInt8](repeating: 0, count: Self.blockSize - key.count)
        data += message
        if data.isEmpty {
            data = [UInt8](repeating: 0, count: Self.blockSize)
        }

        var offset = 0
        while data.count - offset > Self.blockSize {
            var block = [UInt8](data[offset..<(offset + Self.blockSize)])
            compress(&h, &block, counter: UInt64(offset + Self.blockSize), last: false)
            offset += Self.blockSize
        }
        var tail = Array(data[offset...])
        tail.append(contentsOf: [UInt8](repeating: 0, count: Self.blockSize - tail.count))
        let finalCounter = key.isEmpty ? UInt64(message.count) : UInt64(message.count + Self.blockSize)
        compress(&h, &tail, counter: finalCounter, last: true)

        var output: [UInt8] = []
        output.reserveCapacity(32)
        for word in h {
            output.append(UInt8(truncatingIfNeeded: word))
            output.append(UInt8(truncatingIfNeeded: word >> 8))
            output.append(UInt8(truncatingIfNeeded: word >> 16))
            output.append(UInt8(truncatingIfNeeded: word >> 24))
        }
        return Array(output.prefix(digestLength))
    }

    private func compress(_ state: inout [UInt32], _ block: inout [UInt8], counter: UInt64, last: Bool) {
        var m = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            let j = i * 4
            m[i] = UInt32(block[j]) | (UInt32(block[j + 1]) << 8)
                | (UInt32(block[j + 2]) << 16) | (UInt32(block[j + 3]) << 24)
        }
        var v = state + Self.iv
        v[12] ^= UInt32(truncatingIfNeeded: counter)
        v[13] ^= UInt32(truncatingIfNeeded: counter >> 32)
        if last { v[14] = ~v[14] }

        for round in 0..<10 {
            let s = Self.sigma[round]
            g(&v, 0, 4, 8, 12, m[s[0]], m[s[1]])
            g(&v, 1, 5, 9, 13, m[s[2]], m[s[3]])
            g(&v, 2, 6, 10, 14, m[s[4]], m[s[5]])
            g(&v, 3, 7, 11, 15, m[s[6]], m[s[7]])
            g(&v, 0, 5, 10, 15, m[s[8]], m[s[9]])
            g(&v, 1, 6, 11, 12, m[s[10]], m[s[11]])
            g(&v, 2, 7, 8, 13, m[s[12]], m[s[13]])
            g(&v, 3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for i in 0..<8 {
            state[i] ^= v[i] ^ v[i + 8]
        }
    }

    private func g(_ v: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt32, _ y: UInt32) {
        v[a] &+= v[b] &+ x
        v[d] ^= v[a]; v[d] = rotr(v[d], 16)
        v[c] &+= v[d]
        v[b] ^= v[c]; v[b] = rotr(v[b], 12)
        v[a] &+= v[b] &+ y
        v[d] ^= v[a]; v[d] = rotr(v[d], 8)
        v[c] &+= v[d]
        v[b] ^= v[c]; v[b] = rotr(v[b], 7)
    }

    private func rotr(_ value: UInt32, _ bits: Int) -> UInt32 {
        (value >> bits) | (value << (32 - bits))
    }
}
