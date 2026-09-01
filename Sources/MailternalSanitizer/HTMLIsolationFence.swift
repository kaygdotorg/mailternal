/// Deny-by-default network fence around untrusted HTML in `WKWebView`.
///
/// The content-rule list is the subresource fence (`docs/spec/sync.md`). A
/// compile failure must never be treated as "ready": that was a fail-open hole.
public enum NetworkFenceState: Equatable, Sendable {
    /// `WKContentRuleList` compile is in flight. Do not load HTML yet.
    case compiling
    /// The categorical block list is installed. HTML may load.
    case installed
    /// Compile returned nil or errored. HTML must not load.
    case failed
}

/// What the viewer may do with already-sanitized HTML given ``NetworkFenceState``.
public enum HTMLLoadDecision: Equatable, Sendable {
    case waitForFence
    case loadHTML
    case refuseHTML
}

/// Pure decision table used by `MessageWebView`. Tested headlessly — WKWebView
/// compile is not exercised here; only the fail-closed mapping is.
public enum HTMLIsolationFence: Sendable {
    /// Nil/`false` is failure. Never map a missing list to ``NetworkFenceState/installed``.
    public static func state(compiledList: Bool) -> NetworkFenceState {
        compiledList ? .installed : .failed
    }

    public static func decision(for fence: NetworkFenceState) -> HTMLLoadDecision {
        switch fence {
        case .compiling:
            return .waitForFence
        case .installed:
            return .loadHTML
        case .failed:
            return .refuseHTML
        }
    }
}
