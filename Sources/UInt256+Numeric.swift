//

import Foundation

// MARK: - Conforming to Numeric protocol
// details on Numeric protocol:
// https://developer.apple.com/documentation/swift/numeric
extension UInt256: Numeric {

    static func add(_ lhs: UInt256, _ rhs: UInt256) -> (UInt256, Bool) {
        var values = [UInt64]()
        var carry: UInt64 = 0
        for i in (0..<4).reversed() {
            let (result1, overflow1) = lhs[i].addingReportingOverflow(rhs[i])
            let (result2, overflow2) = result1.addingReportingOverflow(carry)
            values.insert(result2, at: 0)
            if overflow1 || overflow2 {
                carry = 1
            } else {
                carry = 0
            }
        }

        let result = UInt256(values)
        let overflow = carry == 1
        return (result, overflow)
    }

    public static func &+(lhs: UInt256, rhs: UInt256) -> UInt256 {
        let (result, _) = add(lhs, rhs)
        return result
    }

    public static func +(lhs: UInt256, rhs: UInt256) -> UInt256 {
        let (result, _) = add(lhs, rhs)
        return result
    }

    public static func +=(_ lhs: inout UInt256, _ rhs: UInt256) {
        lhs = lhs + rhs
    }

    static func subtract(_ lhs: UInt256, _ rhs: UInt256) -> (UInt256, Bool) {
        var values = [UInt64]()
        var carry: UInt64 = 0
        for i in (0..<4).reversed() {
            let (result1, overflow1) = lhs[i].subtractingReportingOverflow(rhs[i])
            let (result2, overflow2) = result1.subtractingReportingOverflow(carry)
            values.insert(result2, at: 0)
            if overflow1 || overflow2 {
                carry = 1
            } else {
                carry = 0
            }
        }

        let result = UInt256(values)
        let overflow = carry == 1
        return (result, overflow)
    }

    public static func &-(_ lhs: UInt256, _ rhs: UInt256) -> UInt256 {
        let (result, _) = subtract(lhs, rhs)
        return result
    }

    public static func -(_ lhs: UInt256, _ rhs: UInt256) -> UInt256 {
        let (result, _) = subtract(lhs, rhs)
        return result
    }

    public static func -=(_ lhs: inout UInt256, _ rhs: UInt256) {
        lhs = lhs - rhs
    }

    public static func *(_ lhs: UInt256, _ rhs: UInt256) -> UInt256 {
        let (_, result) = karatsuba(lhs, rhs)
        return result
    }

    public static func *=(_ lhs: inout UInt256, _ rhs: UInt256) {
        lhs = lhs * rhs
    }

    public static func /(_ lhs: UInt256, _ rhs: UInt256) -> UInt256 {
        let (result, _) = divisionWithRemainder(lhs, rhs)
        return result
    }

    public static func /=(_ lhs: inout UInt256, _ rhs: UInt256) {
        lhs = lhs / rhs
    }

    /// Quotient and remainder, by Knuth's Algorithm D (TAOCP vol. 2, 4.3.1)
    /// over the four 64-bit words. A zero divisor gives `(0, 0)`.
    public static func divisionWithRemainder(_ lhs: UInt256, _ rhs: UInt256) -> (UInt256, UInt256) {
        let l = lhs.parts
        let r = rhs.parts
        // Significant words of each operand (`parts` is most significant first).
        var n = 4
        while n > 0 && r[4 - n] == 0 { n -= 1 }
        var m = 4
        while m > 0 && l[4 - m] == 0 { m -= 1 }
        guard n > 0, m > 0 else { return (0, 0) }
        guard m >= n else { return (0, lhs) }

        if n == 1 {
            // One-word divisor: a word at a time; the running remainder stays
            // below the divisor, so no step overflows.
            let divisor = r[3]
            var quotient: [UInt64] = [0, 0, 0, 0]
            var remainder: UInt64 = 0
            for i in (4 - m)..<4 {
                (quotient[i], remainder) = divisor.dividingFullWidth((remainder, l[i]))
            }
            return (UInt256(withUInt64Array: quotient), UInt256(withUInt64: remainder))
        }

        // Words least significant first: `u` the dividend with one word of
        // headroom, `v` the divisor, both shifted so `v`'s top bit is set.
        return withUnsafeTemporaryAllocation(of: UInt64.self, capacity: 9) { storage in
            let u = UnsafeMutableBufferPointer(rebasing: storage[0..<5])
            let v = UnsafeMutableBufferPointer(rebasing: storage[5..<9])
            let shift = r[4 - n].leadingZeroBitCount
            for i in 0..<4 {
                let word = r[3 - i]
                let below = i > 0 ? r[4 - i] : 0
                v[i] = shift == 0 ? word : (word << UInt64(shift)) | (below >> UInt64(64 - shift))
            }
            u[4] = shift == 0 ? 0 : l[0] >> UInt64(64 - shift)
            for i in 0..<4 {
                let word = l[3 - i]
                let below = i > 0 ? l[4 - i] : 0
                u[i] = shift == 0 ? word : (word << UInt64(shift)) | (below >> UInt64(64 - shift))
            }

            var quotient: [UInt64] = [0, 0, 0, 0]
            let top = v[n - 1]
            let next = v[n - 2]
            for j in stride(from: m - n, through: 0, by: -1) {
                // Estimate this quotient word from the top two words, then
                // correct it with the next: it is then exact or one too large.
                var estimate: UInt64
                var rest: UInt64
                var restOverflow = false
                if u[j + n] == top {
                    // The window's top word never exceeds `top`; when equal,
                    // the two-word quotient would not fit a word.
                    estimate = UInt64.max
                    (rest, restOverflow) = u[j + n - 1].addingReportingOverflow(top)
                } else {
                    (estimate, rest) = top.dividingFullWidth((u[j + n], u[j + n - 1]))
                }
                while !restOverflow {
                    let product = estimate.multipliedFullWidth(by: next)
                    guard product.high > rest || (product.high == rest && product.low > u[j + n - 2]) else { break }
                    estimate -= 1
                    (rest, restOverflow) = rest.addingReportingOverflow(top)
                }

                // Subtract estimate × v from the window.
                var carry: UInt64 = 0
                var borrow: UInt64 = 0
                for i in 0..<n {
                    let product = estimate.multipliedFullWidth(by: v[i])
                    let (low, lowOverflow) = product.low.addingReportingOverflow(carry)
                    carry = product.high &+ (lowOverflow ? 1 : 0)
                    let (difference, borrow1) = u[i + j].subtractingReportingOverflow(low)
                    let (result, borrow2) = difference.subtractingReportingOverflow(borrow)
                    u[i + j] = result
                    borrow = (borrow1 ? 1 : 0) + (borrow2 ? 1 : 0)
                }
                let (difference, borrow1) = u[j + n].subtractingReportingOverflow(carry)
                let (result, borrow2) = difference.subtractingReportingOverflow(borrow)
                u[j + n] = result

                // One too large: add one v back.
                if borrow1 || borrow2 {
                    estimate -= 1
                    var addCarry: UInt64 = 0
                    for i in 0..<n {
                        let (sum, overflow1) = u[i + j].addingReportingOverflow(v[i])
                        let (total, overflow2) = sum.addingReportingOverflow(addCarry)
                        u[i + j] = total
                        addCarry = (overflow1 || overflow2) ? 1 : 0
                    }
                    u[j + n] = u[j + n] &+ addCarry
                }
                quotient[3 - j] = estimate
            }

            // The remainder is the low `n` words of `u`, shifted back.
            var remainder: [UInt64] = [0, 0, 0, 0]
            for i in 0..<n {
                let above = i + 1 < n ? u[i + 1] : 0
                remainder[3 - i] = shift == 0 ? u[i] : (u[i] >> UInt64(shift)) | (above << UInt64(64 - shift))
            }
            return (UInt256(withUInt64Array: quotient), UInt256(withUInt64Array: remainder))
        }
    }

    public static func %(_ lhs: UInt256, _ rhs: UInt256) -> UInt256 {
        let (_, result) = divisionWithRemainder(lhs, rhs)
        return result
    }
    
    public static func %=(lhs: inout UInt256, rhs: UInt256) {
        lhs = lhs % rhs
    }
}
