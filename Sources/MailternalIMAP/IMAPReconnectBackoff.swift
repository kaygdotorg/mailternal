#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Glibc)
import Glibc  // log/pow: FoundationEssentials does not re-export libm on Linux
#elseif canImport(Darwin)
import Darwin
#endif

/// Jittered exponential backoff for IMAP reconnect / `\Seen` retry loops
/// (spec: sync.md — “jittered exponential backoff”).
///
/// The helper is pure: pass `unitRandom` in `0...1` for tests; omit it to draw
/// from the system generator.
public struct IMAPReconnectBackoff: Sendable, Hashable {
    /// Delay before the first retry.
    public var base: TimeInterval
    /// Upper bound on the exponential term (jitter is applied after clamping).
    public var cap: TimeInterval
    /// Half-width of the jitter band as a fraction of the exponential delay.
    /// `0.2` means the delay is multiplied by a random factor in `[0.8, 1.2]`.
    public var jitterFraction: Double

    /// Creates a backoff schedule.
    /// - Parameters:
    ///   - base: Delay before the first retry. Must be positive.
    ///   - cap: Maximum exponential delay before jitter. Must be ≥ `base`.
    ///   - jitterFraction: Jitter half-width in `0...1`.
    public init(base: TimeInterval = 0.5, cap: TimeInterval = 60, jitterFraction: Double = 0.2) {
        self.base = max(0.001, base)
        self.cap = max(self.base, cap)
        self.jitterFraction = min(1, max(0, jitterFraction))
    }

    /// Delay for `attempt` (1 = first retry after a failure).
    ///
    /// - Parameters:
    ///   - attempt: 1-based retry count. Values `<= 0` are treated as 1.
    ///   - unitRandom: Uniform random in `0...1`. When `nil`, the system generator is used.
    public func delay(forAttempt attempt: Int, unitRandom: Double? = nil) -> TimeInterval {
        IMAPReconnectBackoff.delay(
            attempt: attempt,
            base: base,
            cap: cap,
            jitterFraction: jitterFraction,
            unitRandom: unitRandom
        )
    }

    /// Stateless form used by the sync engine’s reconnect loop.
    ///
    /// - Parameters:
    ///   - attempt: 1-based retry count.
    ///   - base: Delay before the first retry.
    ///   - cap: Maximum exponential delay before jitter.
    ///   - jitterFraction: Jitter half-width in `0...1`.
    ///   - unitRandom: Uniform random in `0...1`. When `nil`, the system generator is used.
    public static func delay(
        attempt: Int,
        base: TimeInterval = 0.5,
        cap: TimeInterval = 60,
        jitterFraction: Double = 0.2,
        unitRandom: Double? = nil
    ) -> TimeInterval {
        let safeBase = max(0.001, base)
        let safeCap = max(safeBase, cap)
        let shift = max(0, attempt - 1)
        // cap / base is finite; clamp the exponent so we don't overflow Double.
        let maxShift = Int((log(safeCap / safeBase) / log(2.0)).rounded(.up)) + 1
        let exp = min(safeCap, safeBase * pow(2.0, Double(min(shift, max(0, maxShift)))))
        let random = unitRandom ?? Double.random(in: 0...1)
        let clampedRandom = min(1, max(0, random))
        let factor = (1.0 - jitterFraction) + (2.0 * jitterFraction * clampedRandom)
        return max(0, exp * factor)
    }
}
