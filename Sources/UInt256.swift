
import Foundation

public struct UInt256: Sendable {
    var parts: [UInt64]

    public init() {
        self.init(withUInt64: 0)
    }

    public init(_ value: Int) {
        if value >= 0 {
            parts = [0, 0, 0, UInt64(value)]
        } else {
            parts = [
                UInt64.max,
                UInt64.max,
                UInt64.max,
                UInt64(truncatingIfNeeded: value)
            ]
        }
    }

    public init(_ value: UInt64) {
        self.init(withUInt64: value)
    }

    public init(withUInt64 value: UInt64) {
        parts = [0, 0, 0, value]
    }

    public init(_ value: UInt256) {
        parts = [value[0], value[1], value[2], value[3]]
    }

    public init(_ values: [UInt64]) {
        self.init(withUInt64Array: values)
    }

    public init(withUInt64Array values: [UInt64]) {
        // Four words are already the representation: keep the array as is.
        if values.count == 4 {
            parts = values
            return
        }
        var _parts = Array(values)
        while _parts.count < 4 {
            _parts.insert(0, at: 0)
        }
        parts = Array(_parts[0...3])
    }

    subscript(index: Int) -> UInt64 {
        get {
            return parts[index]
        }
        mutating set {
            parts[index] = UInt64(newValue)
        }
    }

    subscript(range: CountableClosedRange<Int>) -> [UInt64] {
        get {
            return Array(parts[range])
        }
    }

    /// The 64 lowercase hex digits, most significant first, zero-padded:
    /// what `String(format: "%0.16lx%0.16lx%0.16lx%0.16lx", ...)` gives for
    /// the four words, written a nibble at a time.
    public func toHexString() -> String {
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 64) { buffer in
            var index = 0
            for part in parts {
                var shift: UInt64 = 60
                for _ in 0..<16 {
                    let nibble = UInt8(truncatingIfNeeded: (part >> shift) & 0xf)
                    buffer[index] = nibble < 10 ? nibble + 48 : nibble + 87
                    index += 1
                    shift = shift &- 4
                }
            }
            return String(decoding: buffer, as: UTF8.self)
        }
    }
}
