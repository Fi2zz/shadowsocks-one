import Foundation

struct NonceCounter {
    private var bytes = Array(repeating: UInt8.zero, count: 12)

    mutating func next() -> Data {
        defer { increment() }
        return Data(bytes)
    }

    private mutating func increment() {
        for index in bytes.indices {
            let result = bytes[index].addingReportingOverflow(1)
            bytes[index] = result.partialValue
            if !result.overflow {
                return
            }
        }
    }
}
