import AppKit

/// Reader and message-list scrollers are overlay scrollers that appear only
/// while scrolling, regardless of the system "Show scroll bars" preference
/// (a connected mouse otherwise pins legacy always-visible bars). AppKit
/// resets `scrollerStyle` when the preference changes, so the choice is
/// re-applied on that notification.
@MainActor
enum OverlayScrollerPolicy {
    static func apply(to scrollView: NSScrollView) {
        scrollView.scrollerStyle = .overlay
        NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak scrollView] _ in
            MainActor.assumeIsolated {
                scrollView?.scrollerStyle = .overlay
            }
        }
    }
}
