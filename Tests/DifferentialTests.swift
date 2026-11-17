import XCTest
import Foundation
@testable import UInt256

/// Division, `words` and `toHexString` were rewritten for speed. Each must
/// give exactly what the 1.1.0 code gave, for every input. The 1.1.0 code is
/// kept below, verbatim, as the oracle; inputs are edge values (zero, one,
/// the maximum, every power of two and its neighbours, words drawn from the
/// boundaries of a 64-bit word), real chain targets, and random values of
/// every length.
class DifferentialTests: XCTestCase {

    // MARK: - The 1.1.0 code

    /// 1.1.0 `divisionWithRemainder`: binary long division, a bit at a time.
    static func referenceDivision(_ lhs: UInt256, _ rhs: UInt256) -> (UInt256, UInt256) {
        guard rhs > 0 else { return (0, 0) }
        guard lhs > 0 else { return (0, 0) }
        if rhs == UInt256(1) { return (lhs, 0) }

        guard lhs >= rhs else {
            return (0, lhs)
        }

        var quotient: UInt256 = 0
        var remainder: UInt256 = lhs
        var partial: UInt256 = 1
        var chunk: UInt256 = rhs
        var trail: [(UInt256, UInt256)] = [(1, rhs)]

        while remainder - chunk >= chunk {
            chunk = chunk << 1
            partial = partial << 1
            trail.append((partial, chunk))
        }

        for (partial, chunk) in trail.reversed() {
            if remainder >= chunk {
                remainder -= chunk
                quotient += partial
            }
        }

        return (quotient, remainder)
    }

    /// 1.1.0 `words`.
    static func referenceWords(_ value: UInt256) -> [UInt] {
        var result = [UInt]()
        for part in value.parts.reversed() {
            result.append(contentsOf: part.words)
        }
        return result
    }

    /// 1.1.0 `toHexString`.
    static func referenceHex(_ value: UInt256) -> String {
        return String(format: "%0.16lx%0.16lx%0.16lx%0.16lx", value.parts[0], value.parts[1], value.parts[2], value.parts[3])
    }

    // MARK: - Inputs

    /// Words at the boundaries a word-wise division turns on.
    static let edgeWords: [UInt64] = [
        0, 1, 2, 3, 0x7fff_ffff_ffff_ffff, 0x8000_0000_0000_0000, 0x8000_0000_0000_0001,
        0xffff_ffff_ffff_fffe, 0xffff_ffff_ffff_ffff, 0x0000_0000_ffff_ffff, 0x0000_0001_0000_0000,
    ]

    /// Targets real chains carried (Nexus, testnet and app chains), and the
    /// easiest and a hard target.
    static let chainTargets: [UInt256] = [
        "0x610d3fffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "0x6067bfffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "0xcc4bffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "0xcc2affffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "0x7742bfffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "0x00000000ffff0000000000000000000000000000000000000000000000000000",
        "0x0000000000000000000a4b5c00000000000000000000000000000000000000ff",
        "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    ].map(hex)

    static func hex(_ text: String) -> UInt256 {
        let digits = Array(text.dropFirst(2))
        let padded = Array(repeating: Character("0"), count: 64 - digits.count) + digits
        var parts: [UInt64] = []
        for i in 0..<4 {
            parts.append(UInt64(String(padded[(i * 16)..<(i * 16 + 16)]), radix: 16)!)
        }
        return UInt256(parts)
    }

    static func edgeValues() -> [UInt256] {
        var values: [UInt256] = [0, 1, 2, 3, UInt256.max, UInt256.max - 1]
        for bit in 0..<256 {
            let power = UInt256(1) << bit
            values.append(power)
            values.append(power - 1)
            values.append(power + 1)
            values.append(UInt256.max >> bit)
        }
        values.append(contentsOf: chainTargets)
        for target in chainTargets {
            values.append(target + 1)
            values.append(UInt256.max - target)
        }
        return values
    }

    /// A value of random length: `significantWords` words, each either an edge
    /// word or uniform.
    static func randomValue<G: RandomNumberGenerator>(using generator: inout G) -> UInt256 {
        let significantWords = Int.random(in: 0...4, using: &generator)
        var parts: [UInt64] = [0, 0, 0, 0]
        for i in (4 - significantWords)..<4 {
            parts[i] = Bool.random(using: &generator)
                ? edgeWords.randomElement(using: &generator)!
                : UInt64.random(in: 0...UInt64.max, using: &generator)
        }
        let value = UInt256(parts)
        // Sometimes cut at a random bit, so every length occurs, not just
        // whole words.
        return Bool.random(using: &generator) ? value >> Int.random(in: 0..<256, using: &generator) : value
    }

    // MARK: - Tests

    func testDivisionMatchesBitwiseLongDivision() {
        var generator = SplitMix64(seed: 0x5eed_0001)
        let edges = DifferentialTests.edgeValues()
        var pairs: [(UInt256, UInt256)] = []
        for a in edges {
            for b in edges.prefix(80) {
                pairs.append((a, b))
            }
            pairs.append((a, edges.randomElement(using: &generator)!))
        }
        // Every word count of dividend over divisor, words from the edge set.
        for _ in 0..<30_000 {
            pairs.append((DifferentialTests.randomValue(using: &generator),
                          DifferentialTests.randomValue(using: &generator)))
        }
        for _ in 0..<10_000 {
            pairs.append((arc4random256(generator: &generator), arc4random256(generator: &generator)))
        }
        for (a, b) in pairs {
            let expected = DifferentialTests.referenceDivision(a, b)
            let actual = UInt256.divisionWithRemainder(a, b)
            XCTAssertEqual(actual.0, expected.0, "\(a) / \(b)")
            XCTAssertEqual(actual.1, expected.1, "\(a) % \(b)")
            XCTAssertEqual(a / b, expected.0)
            XCTAssertEqual(a % b, expected.1)
            if b > 0 {
                // Independently: q·b + r = a and r < b.
                let product = expected.0.multipliedFullWidth(by: b)
                let (sum, overflow) = product.low.addingReportingOverflow(expected.1)
                XCTAssertEqual(product.high, 0)
                XCTAssertFalse(overflow)
                XCTAssertEqual(sum, a)
                XCTAssertLessThan(expected.1, b)
            }
        }
    }

    /// The add-back step of Algorithm D runs for about one quotient word in
    /// 2^63 at random; these dividends are built to need it.
    func testDivisionAddBackCases() {
        var generator = SplitMix64(seed: 0x5eed_0002)
        var cases: [(UInt256, UInt256)] = []
        // Divisor with top word 0x8000…, next word large; dividend whose top
        // words equal the divisor's top: the estimate is B-1 and too large.
        for _ in 0..<20_000 {
            let n = Int.random(in: 2...4, using: &generator)
            var v: [UInt64] = Array(repeating: 0, count: 4)
            v[4 - n] = DifferentialTests.edgeWords.filter { $0 != 0 }.randomElement(using: &generator)!
            for i in (5 - n)..<4 {
                v[i] = DifferentialTests.edgeWords.randomElement(using: &generator)!
            }
            var u: [UInt64] = (0..<4).map { _ in DifferentialTests.edgeWords.randomElement(using: &generator)! }
            if Bool.random(using: &generator) {
                // Window top equal to the divisor's top words.
                for i in 0..<n where i < 4 { u[i] = v[4 - n + i] }
            }
            cases.append((UInt256(u), UInt256(v)))
        }
        // Reaches add-back, and add-back right after a B-1 estimate.
        cases.append((UInt256([0x7fff_ffff_ffff_ffff, 0x8000_0000_0000_0000, 0, 0]),
                      UInt256([0, 0x8000_0000_0000_0000, 0, 1])))
        cases.append((UInt256([0xffff_ffff_ffff_fffe, 0x0000_0000_0000_0001, 0xffff_ffff_ffff_fffe, 0]),
                      UInt256([0, 0xffff_ffff_ffff_ffff, 0, 0xffff_ffff_ffff_ffff])))
        // Dividends one off a multiple of a 3- or 4-word divisor, where the
        // estimate is most often one too large.
        for _ in 0..<20_000 {
            let n = Int.random(in: 3...4, using: &generator)
            var v: [UInt64] = Array(repeating: 0, count: 4)
            for i in (4 - n)..<4 {
                v[i] = DifferentialTests.edgeWords.randomElement(using: &generator)!
            }
            if v[4 - n] == 0 { v[4 - n] = 1 }
            let b = UInt256(v)
            let q = UInt256.max >> (64 * (n - 1) + Int.random(in: 0..<64, using: &generator))
            let product = q.multipliedFullWidth(by: b)
            guard product.high == 0 else { continue }
            for k in [UInt256(0), UInt256(1), b - 1] {
                let (above, overflow) = product.low.addingReportingOverflow(k)
                if !overflow { cases.append((above, b)) }
            }
            if product.low > 0 { cases.append((product.low - 1, b)) }
        }
        for (a, b) in cases {
            let expected = DifferentialTests.referenceDivision(a, b)
            let actual = UInt256.divisionWithRemainder(a, b)
            XCTAssertEqual(actual.0, expected.0, "\(a) / \(b)")
            XCTAssertEqual(actual.1, expected.1, "\(a) % \(b)")
        }
    }

    func testReportingOverflowDivisionMatches() {
        var generator = SplitMix64(seed: 0x5eed_0003)
        for _ in 0..<5_000 {
            let a = DifferentialTests.randomValue(using: &generator)
            let b = Bool.random(using: &generator) ? 0 : DifferentialTests.randomValue(using: &generator)
            let expected = DifferentialTests.referenceDivision(a, b)
            let quotient = a.dividedReportingOverflow(by: b)
            let remainder = a.remainderReportingOverflow(dividingBy: b)
            if b == 0 {
                XCTAssertEqual(quotient.partialValue, a)
                XCTAssertTrue(quotient.overflow)
                XCTAssertEqual(remainder.partialValue, a)
                XCTAssertTrue(remainder.overflow)
            } else {
                XCTAssertEqual(quotient.partialValue, expected.0)
                XCTAssertFalse(quotient.overflow)
                XCTAssertEqual(remainder.partialValue, expected.1)
                XCTAssertFalse(remainder.overflow)
            }
            let full = a.quotientAndRemainder(dividingBy: b == 0 ? 1 : b)
            let fullExpected = DifferentialTests.referenceDivision(a, b == 0 ? 1 : b)
            XCTAssertEqual(full.quotient, fullExpected.0)
            XCTAssertEqual(full.remainder, fullExpected.1)
        }
    }

    func testHexAndWordsMatch() {
        var generator = SplitMix64(seed: 0x5eed_0004)
        var values = DifferentialTests.edgeValues()
        for _ in 0..<20_000 {
            values.append(DifferentialTests.randomValue(using: &generator))
            values.append(arc4random256(generator: &generator))
        }
        for value in values {
            let hex = value.toHexString()
            XCTAssertEqual(hex, DifferentialTests.referenceHex(value))
            XCTAssertEqual(value.description, hex)
            XCTAssertEqual(value.hashValue, DifferentialTests.referenceHex(value).hashValue)
            // `String(radix:)` reads `words`: no leading zeros, "0" for zero.
            let trimmed = hex.drop(while: { $0 == "0" })
            XCTAssertEqual(String(value, radix: 16), trimmed.isEmpty ? "0" : String(trimmed))

            let words = value.words
            let expected = DifferentialTests.referenceWords(value)
            XCTAssertEqual(Array(words), expected)
            XCTAssertEqual(words.count, expected.count)
            XCTAssertEqual(words.first, expected.first)
            XCTAssertEqual(words.last, expected.last)
            for (index, word) in words.enumerated() {
                XCTAssertEqual(word, expected[index])
            }
            // Conversions the standard library makes through `words`.
            XCTAssertEqual(UInt64(truncatingIfNeeded: value), value.parts[3])
            XCTAssertEqual(UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value.parts[3]))
            XCTAssertEqual(UInt64(exactly: value), value.leadingZeroBitCount >= 192 ? value.parts[3] : nil)
            XCTAssertEqual(Int(clamping: value), value.leadingZeroBitCount >= 193 ? Int(value.parts[3]) : Int.max)
            XCTAssertEqual(value == UInt256(value.parts[3]), value.leadingZeroBitCount >= 192)
        }
    }

    func testFourWordInitKeepsTheWords() {
        var generator = SplitMix64(seed: 0x5eed_0005)
        for _ in 0..<1_000 {
            let words = (0..<Int.random(in: 0...6, using: &generator)).map { _ in
                UInt64.random(in: 0...UInt64.max, using: &generator)
            }
            var expected = words
            while expected.count < 4 { expected.insert(0, at: 0) }
            XCTAssertEqual(UInt256(words).parts, Array(expected[0...3]))
        }
    }
}

/// A seeded generator, so a failure replays.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

func arc4random256<G: RandomNumberGenerator>(generator: inout G) -> UInt256 {
    return UInt256((0..<4).map { _ in UInt64.random(in: 0...UInt64.max, using: &generator) })
}
