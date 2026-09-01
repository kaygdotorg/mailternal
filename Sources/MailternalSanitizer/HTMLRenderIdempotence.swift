/// Identity of HTML currently shown (or queued) in `MessageWebView`.
///
/// SwiftUI's `updateNSView` calls `render` on every observation tick. Reloading
/// identical HTML resets scroll and restarts `mailternal-part://` fetches.
/// Skip `loadHTMLString` when this identity is unchanged. Remote-image consent
/// is a different identity and goes through `setRemoteImagesAllowed`, not a
/// fresh `render`.
public struct DisplayedHTMLIdentity: Equatable, Sendable {
    public var htmlHash: UInt64
    public var remoteAllowed: Bool

    public init(htmlHash: UInt64, remoteAllowed: Bool) {
        self.htmlHash = htmlHash
        self.remoteAllowed = remoteAllowed
    }
}

public enum HTMLRenderAction: Equatable, Sendable {
    /// Do not call `loadHTMLString`. The scheme-handler provider may still update.
    case skip
    /// Load (or queue the load while the network fence is compiling).
    case load
}

/// Pure skip table for `MessageWebView.render` / `setRemoteImagesAllowed`.
/// WKWebView is not involved; tests run headlessly.
public enum HTMLRenderIdempotence: Sendable {
    /// FNV-1a 64-bit over UTF-8. Deterministic within a process.
    public static func hash(_ html: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in html.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }

    public static func identity(html: String, remoteAllowed: Bool) -> DisplayedHTMLIdentity {
        DisplayedHTMLIdentity(htmlHash: hash(html), remoteAllowed: remoteAllowed)
    }

    /// `displayed` is the identity last loaded or queued. `nil` means nothing shown.
    public static func action(
        displayed: DisplayedHTMLIdentity?,
        next: DisplayedHTMLIdentity
    ) -> HTMLRenderAction {
        if displayed == next { return .skip }
        return .load
    }
}
