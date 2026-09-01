import Foundation
import Testing
@testable import MailternalMIME

@Test func fuzzMutationsDoNotCrashAndEnforceLimits() throws {
    let corpus = try MIMETestSupport.loadAllCorpus()
    #expect(!corpus.isEmpty)
    var rng = SplitMix64(seed: 0xC0FFEE_F00D)

    var generated: [(name: String, data: Data)] = corpus
    generated.append((name: "gen-nested", data: makeNestedMultipart(levels: 12)))
    generated.append((
        name: "gen-large-text",
        data: MIMETestSupport.message(
            headers: [
                "From: a@b.com",
                "Date: Wed, 01 Jan 2020 00:00:00 +0000",
                "Subject: fuzz",
            ],
            body: String(repeating: "Z", count: 64 * 1024)
        )
    ))

    var parsed = 0
    for source in generated {
        for mutation in 0..<20 {
            let mutated = mutate(source.data, rng: &rng, salt: UInt64(mutation))
            do {
                let msg = try MIMEParser.parse(mutated, internalDate: MIMETestSupport.t0)
                parsed += 1
                #expect(msg.parts.count <= MIMELimits.maxParts + 8)
                for part in msg.parts {
                    if let text = part.text {
                        #expect(
                            text.utf8.count <= MIMELimits.decodedTextPart,
                            "limit broken after mutating \(source.name) #\(mutation)"
                        )
                    }
                    #expect(specifierComponentCount(part.specifier) <= MIMELimits.maxNestingDepth)
                }
            } catch is MIMEParseError {
                // empty or totally unparseable after truncation to zero
            } catch is CancellationError {
                Issue.record("cancellation during fuzz")
            }
        }
    }
    #expect(parsed > 0)
}

private func mutate(_ data: Data, rng: inout SplitMix64, salt: UInt64) -> Data {
    if data.isEmpty { return data }
    var bytes = Array(data)
    let mode = Int((rng.next() &+ salt) % 7)
    switch mode {
    case 0:
        let i = rng.int(inMax: bytes.count)
        bytes[i] ^= UInt8(truncatingIfNeeded: rng.next())
    case 1:
        let i = rng.int(inMax: bytes.count + 1)
        bytes.insert(UInt8(truncatingIfNeeded: rng.next()), at: i)
    case 2:
        if !bytes.isEmpty {
            bytes.remove(at: rng.int(inMax: bytes.count))
        }
    case 3:
        let cut = rng.int(inMax: bytes.count)
        bytes = Array(bytes.prefix(cut))
    case 4:
        let i = rng.int(inMax: bytes.count)
        let n = min(16, bytes.count - i)
        bytes.insert(contentsOf: bytes[i..<(i + n)], at: i)
    case 5:
        let crlf: [UInt8] = [13, 10]
        let i = rng.int(inMax: bytes.count + 1)
        bytes.insert(contentsOf: crlf, at: i)
    default:
        let dash: [UInt8] = [45, 45]
        let i = rng.int(inMax: bytes.count + 1)
        bytes.insert(contentsOf: dash, at: i)
    }
    return Data(bytes)
}

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(inMax max: Int) -> Int {
        guard max > 0 else { return 0 }
        return Int(next() % UInt64(max))
    }
}
