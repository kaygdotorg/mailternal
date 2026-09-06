#if os(macOS)
import AppKit
import MailternalInterfaces

/// The identity of a plain-text render, independent of its proposed width.
///
/// Font and paragraph style are retained as part of the identity rather than
/// relying on a process-global typography assumption. `appearanceName` keeps
/// semantic colors fresh when the reader changes between light and dark mode.
struct ReaderPlainTextRenderIdentity {
    let messageID: MessageID?
    let text: String
    let query: String
    let selectedMatchIndex: Int?
    let font: NSFont
    let paragraphStyle: NSParagraphStyle
    let appearanceName: String

    func matches(_ other: ReaderPlainTextRenderIdentity) -> Bool {
        messageID == other.messageID
            && query == other.query
            && selectedMatchIndex == other.selectedMatchIndex
            && font.isEqual(other.font)
            && paragraphStyle.isEqual(other.paragraphStyle)
            && appearanceName == other.appearanceName
            && (messageID != nil || text == other.text)
    }
}


/// TextKit surface retained alongside a tab's WebKit surface.
///
/// The text view owns the rendered identity and revision. The pool owns the
/// corresponding width/height entry so geometry is evicted with the tab even
/// when the native view is temporarily detached from the outer ScrollView.
@MainActor
final class ReaderPlainTextView: NSTextView {
    private let ownedTextStorage: NSTextStorage
    private let ownedLayoutManager: NSLayoutManager
    private(set) var renderedIdentity: ReaderPlainTextRenderIdentity?
    private(set) var renderedRevision: UInt64 = 0
    var onAppearanceChange: (@MainActor () -> Void)?
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        let resolvedContainer = container ?? NSTextContainer(
            containerSize: NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(resolvedContainer)
        ownedTextStorage = textStorage
        ownedLayoutManager = layoutManager
        super.init(frame: frameRect, textContainer: resolvedContainer)
        configure()
    }

    convenience init() {
        self.init(frame: .zero, textContainer: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    private func configure() {
        isEditable = false
        isSelectable = true
        drawsBackground = false
        backgroundColor = .clear
        isRichText = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        // The host measures proposed widths independently of its installed
        // frame, then applies the actual container width during layout.
        textContainer?.widthTracksTextView = false
        minSize = .zero
        maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    func identity(
        messageID: MessageID?,
        text: String,
        query: String,
        selectedMatchIndex: Int?,
        font: NSFont,
        paragraphStyle: NSParagraphStyle
    ) -> ReaderPlainTextRenderIdentity {
        ReaderPlainTextRenderIdentity(
            messageID: messageID,
            text: text,
            query: query,
            selectedMatchIndex: selectedMatchIndex,
            font: font,
            paragraphStyle: paragraphStyle,
            appearanceName: effectiveAppearance.name.rawValue
        )
    }

    /// Applies the attributed content only when its rendered identity changed.
    /// Returns `true` when TextKit content or semantic styling was replaced.
    @discardableResult
    func render(
        messageID: MessageID?,
        text: String,
        query: String,
        selectedMatchIndex: Int?,
        font: NSFont,
        paragraphStyle: NSParagraphStyle
    ) -> Bool {
        let nextIdentity = identity(
            messageID: messageID,
            text: text,
            query: query,
            selectedMatchIndex: selectedMatchIndex,
            font: font,
            paragraphStyle: paragraphStyle
        )
        if let renderedIdentity, renderedIdentity.matches(nextIdentity) {
            return false
        }

        let storage = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle,
            ]
        )
        let matches = MessageFind.ranges(in: text, query: query)
        for (offset, range) in matches.enumerated() {
            let nsRange = NSRange(range, in: text)
            let isSelected = offset == selectedMatchIndex
            storage.addAttribute(
                .backgroundColor,
                value: isSelected
                    ? NSColor.selectedContentBackgroundColor
                    : NSColor.findHighlightColor,
                range: nsRange
            )
            if isSelected {
                storage.addAttribute(
                    .foregroundColor,
                    value: NSColor.alternateSelectedControlTextColor,
                    range: nsRange
                )
            }
        }
        ownedTextStorage.setAttributedString(storage)
        renderedIdentity = nextIdentity
        renderedRevision &+= 1
        return true
    }
    func invalidateRenderedStyle() {
        renderedIdentity = nil
        onAppearanceChange?()
    }


    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateRenderedStyle()
    }
}

/// Retains one rendered WebKit or TextKit surface per reader tab.
///
/// A tab switch only changes which retained surface is installed in the reader;
/// it never reloads HTML or reconstructs plain text when the render identity is
/// unchanged. A transient tab changing content kind releases its previous
/// surface before installing the other kind. The pool is deliberately bounded
/// because each WebKit surface owns a WebContent process connection and decoded
/// DOM. Closing a tab removes its surface and all cached geometry immediately.
@MainActor
final class ReaderSurfacePool {
    nonisolated static let defaultCapacity = 8

    let capacity: Int

    /// Called after an LRU entry is removed, allowing its message-side cache
    /// to follow the same bounded lifetime as the native surfaces.
    var onEvict: (@MainActor (UUID) -> Void)?

    /// Tab identities currently represented by the bounded pool. An entry may
    /// be empty while a newly active tab is waiting for its view to attach.
    var retainedTabIDs: Set<UUID> {
        Set(entries.keys)
    }


    private final class Entry {
        var webView: MessageWebView?
        var textView: ReaderPlainTextView?
        var plainLayoutIdentity: ReaderPlainTextRenderIdentity?
        var plainLayoutWidth: CGFloat?
        var plainLayoutRevision: UInt64?
        var plainLayoutHeight: CGFloat?
    }
    private struct ContentHeight {
        let messageID: MessageID
        let value: CGFloat
    }

    private var entries: [UUID: Entry] = [:]
    private var recentIDs: [UUID] = []
    private var contentHeights: [UUID: ContentHeight] = [:]

    init(capacity: Int = ReaderSurfacePool.defaultCapacity) {
        self.capacity = max(capacity, 1)
    }

    /// Returns the retained WebKit surface for `tabID`, creating it on first use.
    func webView(for tabID: UUID) -> MessageWebView {
        let entry = entry(for: tabID)
        if let textView = entry.textView {
            textView.removeFromSuperview()
            entry.textView = nil
            clearPlainLayout(in: entry)
        }
        if let existing = entry.webView {
            touch(tabID)
            return existing
        }

        let view = MessageWebView(frame: .zero)
        entry.webView = view
        touch(tabID)
        evictIfNeeded()
        return view
    }

    /// Returns the retained, non-scrolling TextKit surface for `tabID`.
    func textView(for tabID: UUID) -> ReaderPlainTextView {
        let entry = entry(for: tabID)
        if let webView = entry.webView {
            webView.disposeForPoolRemoval()
            webView.removeFromSuperview()
            entry.webView = nil
            contentHeights.removeValue(forKey: tabID)
        }
        if let existing = entry.textView {
            touch(tabID)
            return existing
        }

        let view = ReaderPlainTextView()
        view.onAppearanceChange = { [weak self] in
            self?.invalidatePlainLayout(for: tabID)
        }
        entry.textView = view
        touch(tabID)
        evictIfNeeded()
        return view
    }

    func contains(_ tabID: UUID) -> Bool {
        entries[tabID] != nil
    }
    func touch(_ tabID: UUID) {
        guard entries[tabID] != nil else { return }
        recentIDs.removeAll { $0 == tabID }
        recentIDs.insert(tabID, at: 0)
    }

    /// Reserves an LRU slot for an active tab before its native view attaches.
    /// This lets the detail cache and surface pool evict the same tab.
    func retain(_ tabID: UUID) {
        if entries[tabID] == nil {
            _ = entry(for: tabID)
        } else {
            touch(tabID)
        }
    }
    /// Drops both native surfaces and all cached geometry when a reader tab closes.
    func drop(_ tabID: UUID) {
        guard let entry = entries.removeValue(forKey: tabID) else {
            contentHeights.removeValue(forKey: tabID)
            recentIDs.removeAll { $0 == tabID }
            return
        }
        recentIDs.removeAll { $0 == tabID }
        contentHeights.removeValue(forKey: tabID)
        entry.webView?.disposeForPoolRemoval()
        entry.webView?.removeFromSuperview()
        entry.textView?.removeFromSuperview()
        entry.webView = nil
        entry.textView = nil
        clearPlainLayout(in: entry)
    }

    func height(for tabID: UUID, messageID: MessageID) -> CGFloat {
        guard let cached = contentHeights[tabID],
              cached.messageID == messageID
        else {
            return 0
        }
        return cached.value
    }

    func recordContentHeight(
        _ height: CGFloat,
        for tabID: UUID,
        messageID: MessageID
    ) {
        guard height.isFinite, height > 0, entries[tabID] != nil else { return }
        guard let cached = contentHeights[tabID],
              cached.messageID == messageID,
              abs(cached.value - height) <= 0.5
        else {
            contentHeights[tabID] = ContentHeight(messageID: messageID, value: height)
            return
        }
    }

    func invalidatePlainLayout(for tabID: UUID) {
        guard let entry = entries[tabID] else { return }
        clearPlainLayout(in: entry)
    }

    func cachedPlainHeight(
        for tabID: UUID,
        identity: ReaderPlainTextRenderIdentity,
        width: CGFloat
    ) -> CGFloat? {
        guard let entry = entries[tabID],
              let textView = entry.textView,
              let cachedIdentity = entry.plainLayoutIdentity,
              cachedIdentity.matches(identity),
              let cachedWidth = entry.plainLayoutWidth,
              abs(cachedWidth - width) <= 0.5,
              entry.plainLayoutRevision == textView.renderedRevision,
              let height = entry.plainLayoutHeight
        else {
            return nil
        }
        return height
    }

    func recordPlainHeight(
        _ height: CGFloat,
        for tabID: UUID,
        identity: ReaderPlainTextRenderIdentity,
        width: CGFloat,
        revision: UInt64
    ) {
        guard let entry = entries[tabID],
              let textView = entry.textView,
              textView.renderedRevision == revision,
              textView.renderedIdentity?.matches(identity) == true,
              height.isFinite,
              height > 0,
              width.isFinite,
              width > 0
        else {
            return
        }
        entry.plainLayoutIdentity = identity
        entry.plainLayoutWidth = width
        entry.plainLayoutRevision = revision
        entry.plainLayoutHeight = height
    }

    /// Applies a reading-mode change to every retained HTML document without
    /// navigating any of them.
    func updateReadingMode(_ mode: EmailReadingMode) {
        for entry in entries.values {
            entry.webView?.updateReadingMode(mode)
        }
    }

    func remoteImagesAllowed(for tabID: UUID) -> Bool {
        entries[tabID]?.webView?.remoteImagesAreAllowed ?? false
    }

    private func entry(for tabID: UUID) -> Entry {
        if let existing = entries[tabID] {
            return existing
        }
        let entry = Entry()
        entries[tabID] = entry
        recentIDs.insert(tabID, at: 0)
        evictIfNeeded()
        return entry
    }

    private func clearPlainLayout(in entry: Entry) {
        entry.plainLayoutIdentity = nil
        entry.plainLayoutWidth = nil
        entry.plainLayoutRevision = nil
        entry.plainLayoutHeight = nil
    }

    private func evictIfNeeded() {
        while entries.count > capacity, let evictedID = recentIDs.last {
            recentIDs.removeLast()
            guard let entry = entries.removeValue(forKey: evictedID) else { continue }
            contentHeights.removeValue(forKey: evictedID)
            entry.webView?.disposeForPoolRemoval()
            entry.webView?.removeFromSuperview()
            entry.textView?.removeFromSuperview()
            entry.webView = nil
            entry.textView = nil
            clearPlainLayout(in: entry)
            onEvict?(evictedID)
        }
    }
}
#endif
