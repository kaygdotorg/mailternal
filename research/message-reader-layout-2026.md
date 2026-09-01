# Mail reader layout research (checked 2026-09-01)

## Scope and evidence rules

This note covers the selected-message reader, not inbox ranking or a generic competitor list. Product facts are taken from first-party support documentation, first-party help pages, or maintained project source documentation. A statement marked **Screenshot-derived inference** describes what is visibly present in an official product screenshot; it is not treated as a documented implementation rule. Values in the recommendation are Mailternal design decisions, not claims that a competitor uses those values.

Current Mailternal integration context is [`MessageViewer.swift`](../App/Sources/Viewer/MessageViewer.swift): the viewer owns one vertical `ScrollView`; `EnvelopeHeader` currently renders subject, From, To, Cc, Date, attachment names, and a divider; `bodyBlock` chooses raw source, sanitized HTML, plain text, or an empty state. The viewer currently applies `MessageViewerLayoutPolicy.edgePadding` (20 points) to the top and sides, ignores the container top safe area, and applies `mailWindowDissolve(.viewer)`. The current policy's titlebar reach is 52 points in [`UILogic.swift`](../App/Sources/Support/UILogic.swift). These code observations are integration context only; this research note makes no production edits.

## Evidence from established readers

### Apple Mail on macOS

- Mail groups related messages into a conversation by default, exposes all messages by clicking the conversation's message count, and has a separate **View > Expand All Conversations** command. The preview area supports stepping through messages and changing newest-first versus oldest-first order in Viewing settings: [Apple Mail User Guide — Read and respond to emails on Mac](https://support.apple.com/guide/mail/read-and-respond-to-emails-mlhlp1010/mac).
- Mail's documented message-header action model is contextual: moving the pointer over a header reveals Reply, Reply All, and Forward actions. The same guide's official screenshot shows a selected message with a subject at the top of the message, a sender/avatar row, To/Cc metadata, a right-side Details affordance, and header actions. **Screenshot-derived inference:** this is a clear visual separation between message identity (subject), envelope metadata, and body, while actions remain close to the header instead of competing with body text: [Apple Mail User Guide screenshot and caption](https://support.apple.com/guide/mail/read-and-respond-to-emails-mlhlp1010/mac), [screenshot asset](https://help.apple.com/assets/6940590395B73B67500DF914/69405904627DAC39E4013406/en_US/6aecdeed3151a92563ef73cdf1d9ffa8.png).
- Mail Viewing settings distinguish default/custom message-header fields, support a custom field such as `Return-Path`, optionally hide recipient email addresses through Smart Addresses, and let users choose whether the most recent conversation message appears first: [Apple Mail User Guide — Change Viewing settings](https://support.apple.com/guide/mail/change-viewing-settings-cpmlprefview/mac).
- Attachments may be shown directly in a message (for example, an image or one-page PDF) or represented as an icon. The documented attachment affordance sits below the message date in the list and in the message header; users can Quick Look with Space, open, save one, or Save All: [Apple Mail User Guide — View, save, or delete email attachments](https://support.apple.com/guide/mail/view-save-or-delete-email-attachments-mlhlp1123/mac).
- Apple documents a separate full-header workflow in iCloud Mail: default display includes sender, recipients, and date; **More > Show All Headers** reveals return/delivery paths, Reply-To, and content type. This is a useful information architecture precedent even though it is the iCloud web client rather than the native macOS surface: [Apple iCloud User Guide — View all email headers](https://support.apple.com/guide/icloud/view-all-email-headers-mmcc887ce9/icloud).
- Mail's privacy settings can prevent remote content from downloading until the user chooses to do so and can hide the IP address from senders. That supports treating remote HTML/image loading as a body-content state, not as an opaque decorative background: [Apple Mail User Guide — Change Privacy settings](https://support.apple.com/guide/mail/change-privacy-settings-mlhlae4a4fe6/mac).

### Apple Mail on iPhone

- Apple's iPhone guide describes a tap-to-read message flow, contact actions from a person's name or email address, optional contact photos, and a configurable message-list preview of two lines by default or up to five lines. It also exposes an inbox-level **Show To/Cc Labels** setting and a To or Cc mailbox: [Apple iPhone User Guide — Check your email in Mail on iPhone](https://support.apple.com/guide/iphone/check-your-email-iph461684497/ios).
- iPhone Mail attachments can be inline or appear at the end of a message, depending on file size. The user inserts attachments from the keyboard-adjacent attachment actions; the guide also documents Scan Document and drawing attachments: [Apple iPhone User Guide — Add email attachments](https://support.apple.com/guide/iphone/add-email-attachments-iph8580f163b/ios).
- Apple's iCloud guide uses **More > Show All Headers** for full technical headers on iCloud.com, with a separate **Show Default Headers** reversal. The native iPhone reading guide above does not present that raw-header workflow; therefore Mailternal should keep compact recipient details and raw source as separate disclosures rather than assume that a phone reader can expose desktop-style headers: [Apple iCloud User Guide — View all email headers](https://support.apple.com/guide/icloud/view-all-email-headers-mmcc887ce9/icloud).

### Gmail

- Gmail's official header workflow is deliberately separate from normal reading: open a message, choose the message-level More menu next to Reply, then choose **Show original**; the full header opens in a new window and can be copied. This is a strong precedent for a discoverable raw-source action that does not burden every message header: [Gmail Help — Trace an email with its full header](https://support.google.com/mail/answer/29436?hl=en).
- Gmail puts replies into one conversation thread and documents **Expand all** to reveal the full emails in a thread: [Gmail Help — Fix problems importing mail](https://support.google.com/mail/answer/7239777?hl=en). The page is an import troubleshooting article, but the thread-expansion workflow is first-party documentation of the reader behavior.
- Gmail's attachment model places attachments at the bottom of the individual message, with hover actions for Download and Add to Drive. Inline photos are treated separately from attachments, and original attachments are not automatically included on reply: [Gmail Help — Open and download attachments](https://support.google.com/mail/answer/30719?hl=en-GB&co=GENIE.Platform%3DDesktop).
- Google explicitly tells users to check that the sender name and email address match, check authentication, and inspect the `from` header when a message looks suspicious. Full address visibility is therefore security-relevant, not merely a details preference: [Gmail Help — Avoid and report phishing emails](https://support.google.com/mail/answer/8253?hl=en), [Gmail Help — Trace an email with its full header](https://support.google.com/mail/answer/29436?hl=en).

### Outlook

- New Outlook exposes full message details through a message-level **More actions > View > View message details** path. Microsoft explicitly describes headers as technical details about sender, composing software, and mail servers, and says checking them can reveal an address disguised by spoofing. It also documents locating the sender's address in the From field of Message details: [Microsoft Support — View internet message headers in Outlook](https://support.microsoft.com/en-us/outlook/view-internet-message-headers-in-outlook).
- Outlook's attachment reader places most files in the Reading Pane directly under the message header or subject. The documented actions include preview, open, Download, Save to OneDrive, Download all, and drag-and-drop; potentially unsafe attachment types are blocked or warned: [Microsoft Support — Open, save, and edit attachments received in Outlook](https://support.microsoft.com/en-us/outlook/mail/open-save-and-edit-attachments-received-in-outlook).
- Bcc is a protocol/privacy boundary, not an omitted visual row: Microsoft says a Bcc recipient is hidden from other recipients, while the sender can use Bcc in the sent message. A reader must never imply that it can reveal other recipients' hidden Bcc addresses: [Microsoft Support — Show, hide, and view the Bcc field](https://support.microsoft.com/en-us/outlook/mail/show-hide-and-view-the-bcc-blind-carbon-copy-field-in-outlook-for-windows).

### Thunderbird

- Thunderbird's maintained source documentation describes a three-pane desktop shell and an `about:message` reader that contains UI for message headers and attachment listing. It says the message pane can show a single message, multiple messages, or a web page, and that a message load collects body, header, and attachment data separately before populating the UI: [Thunderbird Source Docs — Mail Display](https://source-docs.thunderbird.net/en/latest/frontend/mail_display.html).
- The same source documentation describes the thread pane as either a table (date, subject, sender, and other columns) or cards, while the message pane is its own reader surface. **Inference from the documented architecture:** list/table density and message-reading hierarchy are independent seams, so a Mailternal reader should not make body measure depend on message-list width or styling: [Thunderbird Source Docs — Mail Display](https://source-docs.thunderbird.net/en/latest/frontend/mail_display.html).
- Current Thunderbird source keeps a `gViewAllHeaders` state, builds an expanded header view, and reconstructs the header view when the all-headers preference changes. It also has a header-view toolbar and keyboard handling for the message header. This is primary source evidence for a compact-versus-expanded header model and for keeping expansion keyboard-addressable: [Thunderbird `msgHdrView.js` source](https://searchfox.org/comm-central/source/mail/base/content/msgHdrView.js).

### Mimestream

- Mimestream documents oldest-to-newest conversation order by default, a user-selectable newest-to-oldest order, collapsed older messages, a top-right expand/collapse control, and the `Shift-Command-E` expansion shortcut. It also puts message-specific actions in an ellipsis menu in each message header and supports replying to the selected message: [Mimestream User Guide — Viewing Messages](https://mimestream.com/help/user-guide/viewing-messages).
- Mimestream's Viewing settings document both attachment destination choices (Internal Folder, like Apple Mail, or Downloads Folder, like Gmail) and privacy controls for blocking remote images and tracking. The `Load Images` action is therefore a deliberate state change rather than an assumed side effect of opening a message: [Mimestream User Guide — Changing Viewing Settings](https://mimestream.com/help/user-guide/viewing-settings).
- Mimestream's official attachment guide documents attachments as first-class message actions, including drag-and-drop and forwarding a message as an attachment; it does not prescribe a raw-header layout, so raw headers should not be inferred from its message-action menu: [Mimestream User Guide — Adding Attachments to Drafts](https://mimestream.com/help/user-guide/adding-attachments).

### Spark

- Spark groups emails into threads by subject, renders oldest messages at the top and latest at the bottom, and does not offer a setting to disable threads or change their order. The thread is also the foundation for Spark's shared threads and private team comments: [Spark Help — Threads](https://sparkmailapp.com/help/manage-your-inbox/threads-in-spark).
- Spark presents attachments as an attachment-handling surface rather than prescribing one desktop-only placement: its official feature page says most attachments open natively, some open in another app, attachments can be searched using natural language, and saves can target cloud services such as Dropbox, Box, Google Drive, OneDrive, or iCloud Drive: [Spark — Attachments](https://sparkmailapp.com/features/attachments).
- Spark's official thread and attachment documentation does not establish a raw-header control or a numeric body measure. **Evidence boundary:** do not treat the absence of that control in these help pages as proof that no internal implementation exists; design the Mailternal raw-header path from the stronger first-party precedents above (Apple iCloud, Gmail, Outlook, and Thunderbird).

## Common invariants and platform-specific choices

### Invariants worth preserving

- **Identity precedes content.** Every first-party reader model treats the selected message as an envelope plus a body: sender/recipient/date metadata is separate from the body, whether the surface is called a message header, Reading Pane, or `about:message`. Apple iCloud explicitly names sender, recipients, and date as the default header set; Thunderbird's source docs explicitly separate headers, attachments, and body collection: [Apple iCloud User Guide](https://support.apple.com/guide/icloud/view-all-email-headers-mmcc887ce9/icloud), [Thunderbird Source Docs](https://source-docs.thunderbird.net/en/latest/frontend/mail_display.html).
- **Subject is the reading anchor, while actions are contextual.** Apple's official macOS screenshot shows subject above sender metadata and body, and Apple's guide places actions in the header on pointer hover. Mimestream similarly locates message-specific actions in the message header: [Apple Mail User Guide](https://support.apple.com/guide/mail/read-and-respond-to-emails-mlhlp1010/mac), [Mimestream User Guide](https://mimestream.com/help/user-guide/viewing-messages).
- **Attachments belong to the message, but placement varies.** Apple Mail supports inline or icon presentation; Gmail documents attachments at the bottom of a message; Outlook places them under the header or subject; Thunderbird documents a separate attachment listing. Mailternal should model attachment items independently from the body renderer and choose inline versus attachment-row presentation from MIME/content disposition, not from arbitrary visual decoration: [Apple Mail attachments](https://support.apple.com/guide/mail/view-save-or-delete-email-attachments-mlhlp1123/mac), [Gmail attachments](https://support.google.com/mail/answer/30719?hl=en-GB&co=GENIE.Platform%3DDesktop), [Outlook attachments](https://support.microsoft.com/en-us/outlook/mail/open-save-and-edit-attachments-received-in-outlook), [Thunderbird Mail Display](https://source-docs.thunderbird.net/en/latest/frontend/mail_display.html).
- **Compact details and raw source are different levels of disclosure.** Apple iCloud, Gmail, Outlook, and Thunderbird all provide an explicit path to more technical headers rather than making raw routing data compete with reading: [Apple iCloud User Guide](https://support.apple.com/guide/icloud/view-all-email-headers-mmcc887ce9/icloud), [Gmail Help](https://support.google.com/mail/answer/29436?hl=en), [Outlook Support](https://support.microsoft.com/en-us/outlook/view-internet-message-headers-in-outlook), [Thunderbird source](https://searchfox.org/comm-central/source/mail/base/content/msgHdrView.js).
- **Threads require a stable reading order plus explicit expansion.** Apple Mail, Gmail, Mimestream, Thunderbird's multi-message architecture, and Spark all document a thread/conversation model or a multi-message reader; Apple, Gmail, and Mimestream explicitly document expand-all or expand/collapse behaviors: [Apple Mail](https://support.apple.com/guide/mail/read-and-respond-to-emails-mlhlp1010/mac), [Gmail](https://support.google.com/mail/answer/7239777?hl=en), [Mimestream](https://mimestream.com/help/user-guide/viewing-messages), [Thunderbird](https://source-docs.thunderbird.net/en/latest/frontend/mail_display.html), [Spark](https://sparkmailapp.com/help/manage-your-inbox/threads-in-spark).
- **A reader must not depend on remote HTML loading.** Apple Mail and Mimestream both document blocking remote content/images, while Gmail and Outlook warn about suspicious attachments/content. Keep a visible body-content state and preserve plain text fallback: [Apple Mail Privacy settings](https://support.apple.com/guide/mail/change-privacy-settings-mlhlae4a4fe6/mac), [Mimestream Viewing settings](https://mimestream.com/help/user-guide/viewing-settings), [Gmail attachments](https://support.google.com/mail/answer/30719?hl=en-GB&co=GENIE.Platform%3DDesktop), [Outlook attachments](https://support.microsoft.com/en-us/outlook/mail/open-save-and-edit-attachments-received-in-outlook).

### Platform-specific choices

- **macOS:** Desktop readers can afford an always-visible subject/header region, pointer-hover actions, menu commands, multiple panes, and a separate raw-source view. Apple Mail's conversation preview and Thunderbird's three-pane architecture make scrolling and expansion explicit desktop concepts: [Apple Mail on Mac](https://support.apple.com/guide/mail/read-and-respond-to-emails-mlhlp1010/mac), [Thunderbird Mail Display](https://source-docs.thunderbird.net/en/latest/frontend/mail_display.html).
- **iOS:** Preserve the same information order, but let safe-area/navigation chrome and Dynamic Type drive the geometry. Apple's iPhone guide favors tap-to-read, contact actions, compact list previews, optional contact photos, To/Cc labels, and inline-or-end attachments rather than a desktop-style persistent details column: [Apple iPhone User Guide](https://support.apple.com/guide/iphone/check-your-email-iph461684497/ios), [Apple iPhone attachments](https://support.apple.com/guide/iphone/add-email-attachments-iph8580f163b/ios).
- **Web/cloud readers:** Gmail and iCloud use message-level overflow menus for raw headers and attachment actions; Outlook uses message details and Reading Pane actions. These workflows support a Mailternal menu/disclosure action rather than always showing technical fields: [Gmail full headers](https://support.google.com/mail/answer/29436?hl=en), [Apple iCloud full headers](https://support.apple.com/guide/icloud/view-all-email-headers-mmcc887ce9/icloud), [Outlook full headers](https://support.microsoft.com/en-us/outlook/view-internet-message-headers-in-outlook).
- **Conversation philosophy:** Apple Mail, Gmail, Mimestream, Thunderbird, and Spark all support conversation/thread reading, but controls differ: Apple Mail can toggle conversation organization, Gmail documents Expand all, Mimestream lets users change order and collapse older messages, while Spark fixes threading and order. Mailternal should preserve a single-message reading hierarchy even if later thread support adds per-message regions: [Apple Mail](https://support.apple.com/guide/mail/read-and-respond-to-emails-mlhlp1010/mac), [Gmail](https://support.google.com/mail/answer/7239777?hl=en), [Mimestream](https://mimestream.com/help/user-guide/viewing-messages), [Spark](https://sparkmailapp.com/help/manage-your-inbox/threads-in-spark).

## Edge cases and accessibility requirements

- **Long subjects:** Never make the subject an ellipsized security or comprehension boundary in the reader. Use unlimited wrapping for the open message (the list may still preview a fixed number of lines), preserve text selection, and let the header grow before the body starts. At very narrow widths, stack actions below metadata rather than compressing the subject. This is a Mailternal recommendation; Apple's iPhone guide's separate configurable list preview shows why list preview limits should not be confused with full-message content: [Apple iPhone User Guide](https://support.apple.com/guide/iphone/check-your-email-iph461684497/ios).
- **Many recipients:** Compact mode may summarize recipient groups as `To: first recipient + N` and `Cc: first recipient + N`, but the disclosure must expand to every visible To/Cc address with wrapping—not horizontal scrolling or inaccessible hover-only text. Never fabricate or expose other recipients' Bcc values; Microsoft's Bcc guidance establishes that those identities are hidden from other recipients: [Microsoft Bcc Support](https://support.microsoft.com/en-us/outlook/mail/show-hide-and-view-the-bcc-blind-carbon-copy-field-in-outlook-for-windows).
- **RTL and localization:** Use leading/trailing layout, semantic rows, locale-formatted dates, bidirectional isolation for addresses, and natural text direction for message bodies. Do not encode disclosure arrows, attachment order, or action placement as left/right coordinates. This is an implementation requirement, not a claim about the undocumented internals of the products reviewed.
- **Dynamic Type/text scaling:** SwiftUI's `Font` is environment-dependent and offers standard text styles; `DynamicTypeSize` includes accessibility sizes through `accessibility5`. Use semantic `.title2`, `.headline`, `.subheadline`, `.body`, and `.caption` styles instead of fixed reader font sizes, and test expansion at every accessibility size: [Apple SwiftUI Font](https://developer.apple.com/documentation/swiftui/font), [Apple SwiftUI DynamicTypeSize](https://developer.apple.com/documentation/swiftui/dynamictypesize), [Apple HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography).
- **Keyboard disclosure:** The disclosure must be a focusable semantic control, not a click-only text label. Apple's `DisclosureGroup` defines a label plus a control that shows or hides content and exposes bound expanded state; Thunderbird source also keeps keyboard handling for its message-header toolbar, and Mimestream documents a keyboard expansion shortcut: [Apple SwiftUI DisclosureGroup](https://developer.apple.com/documentation/swiftui/disclosuregroup), [Thunderbird `msgHdrView.js`](https://searchfox.org/comm-central/source/mail/base/content/msgHdrView.js), [Mimestream Viewing Messages](https://mimestream.com/help/user-guide/viewing-messages). Mailternal should support tab focus and standard Space/Return activation, announce “expanded/collapsed,” and offer the same action through a menu command.
- **Phishing-relevant address visibility:** Compact mode should show the sender's display name *and actual address* when available; do not let a contact/avatar treatment be the only identity signal. Gmail tells users to compare sender name and address and inspect the `from` header; Outlook documents finding the sender address in Message details; Apple Mail's Smart Addresses setting demonstrates the competing convenience trade-off of hiding addresses: [Gmail phishing guidance](https://support.google.com/mail/answer/8253?hl=en), [Outlook headers](https://support.microsoft.com/en-us/outlook/view-internet-message-headers-in-outlook), [Apple Mail Viewing settings](https://support.apple.com/guide/mail/change-viewing-settings-cpmlprefview/mac).
- **HTML and plain text:** Render sanitized HTML when available, retain a selectable plain-text path, and do not make remote images a prerequisite for reading. HTML can use the full available pane for email-authored layout, while plain text should use the comfortable reading measure below. Keep raw MIME/source in a separate monospaced view. Apple's privacy settings and Mimestream's remote-image setting support this explicit loading state; current Mailternal already has sanitized HTML, plain text, remote-image gating, and a raw-source branch in `MessageViewer.swift`: [Apple Mail Privacy settings](https://support.apple.com/guide/mail/change-privacy-settings-mlhlae4a4fe6/mac), [Mimestream Viewing settings](https://mimestream.com/help/user-guide/viewing-settings), [`MessageViewer.swift`](../App/Sources/Viewer/MessageViewer.swift).
- **Reduced transparency and high contrast:** Apple documents `accessibilityReduceTransparency` as a preference where UI backgrounds should not be semi-transparent and documents `ColorSchemeContrast` as a standard/increased contrast value that apps cannot override. Mailternal should therefore switch every reader region to opaque semantic surfaces under Reduce Transparency and strengthen text/divider contrast under Increased Contrast, without relying on glass or blur to distinguish regions: [Apple `accessibilityReduceTransparency`](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducetransparency), [Apple `ColorSchemeContrast`](https://developer.apple.com/documentation/swiftui/colorschemecontrast), [Apple HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility).
- **Safe area/titlebar:** AppKit defines `safeAreaInsets` as the distances from a view's edges that define the safe area, and says the safe area excludes the region covered by a window title bar or ancestor views. The reader must not place the subject under the physical top fade merely because the scrolling surface ignores its container safe area: [Apple AppKit `NSView.safeAreaInsets`](https://developer.apple.com/documentation/appkit/nsview/safeareainsets).

## Three concrete Mailternal layouts

The wireframes use `[...]` for controls, `(...)` for semantic surfaces, and `↓` for the one vertical scroll owner.

### A. Layered full-width reader (recommended)

```text
physical top / titlebar
┌──────────────────────────────────────────────────────────────────────┐
│  fade reach = 52 pt; opaque content begins at 52 + 12 pt guard       │
├──────────────────────────────────────────────────────────────────────┤
│ (subject region; opaque subjectSurface)                         [⋯]  │
│  Quarterly planning notes for the platform migration                 │
│                                                                      │
│ (header region; opaque headerSurface)                                │
│  [avatar] Alex Morgan  <alex@example.com>       Mar 25, 2025  9:20  │
│  To: you + 3    Cc: product + 8                         [Details ▾]  │
│  [paperclip] roadmap.pdf  [paperclip] notes.txt                       │
│                                                                      │
│  ─────────────────────────────────────────────────────────────────── │
│ (body region; opaque bodySurface; full-width pane, readable text)    │
│       Here is the body text with a comfortable measure…              │
│       (HTML can opt into the full pane; plain text wraps at 72ch.)    │
└──────────────────────────────────────────────────────────────────────┘
↓ one ScrollView owns subject, compact header, expanded details, and body
```

**Trade-offs:** It preserves the user's full-width pane request because the surface and scroll container fill the viewer, while a `maxWidth` measure applies only to plain-text/reading text. It gives the subject a stronger contrast role and makes From/To/Cc/date/body distinct without cards, blur, glass, or transparency. The cost is that the header scrolls away on long messages; a separate titlebar action row can remain fixed if needed, but the metadata itself should not become a second scroll view.

### B. Centered reading column inside a full-width pane

```text
┌──────────────────────────────────────────────────────────────────────┐
│                         (viewerSurface)                              │
│   ┌──────────────────────────────────────────────────────────────┐   │
│   │ subject                                                       │   │
│   │ sender / recipients / date / Details                         │   │
│   │ attachments                                                   │   │
│   │ divider                                                       │   │
│   │ body text, max 72ch                                           │   │
│   └──────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
↓ column scrolls as one unit
```

**Trade-offs:** Best scanability for long plain-text messages and very wide windows; it prevents exhausting eye tracking. It can feel like the app has ignored a full-width pane request, and HTML newsletters may look artificially constrained. If used, keep the outer viewer full width and let only the plain-text body choose the measure; do not put a visible floating card around the regions.

### C. Sticky compact header with body-only scrolling

```text
┌──────────────────────────────────────────────────────────────────────┐
│ physical top + fixed titlebar actions                                │
├──────────────────────────────────────────────────────────────────────┤
│ (fixed compact header) subject / sender / To + N / [Details]         │
│ (fixed attachment rail, when present)                                │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│ (body scroll region)                                                 │
│  body…                                                               │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

**Trade-offs:** Useful when the user must keep Reply or sender identity visible while reading a very long message. It introduces nested scroll ownership and a sticky boundary, increases the chance of the header covering HTML content, and makes Dynamic Type expansion harder. Keep this as a later opt-in only; it is not the restrained default.

## Recommended macOS design

Choose **A. Layered full-width reader**. Make the reader canvas full width, but treat subject, envelope/header, and body as separate opaque/tinted semantic regions. Use a single vertical scroll owner. Keep the raw-source action separate from compact details, and keep the physical-top fade as a titlebar treatment rather than a translucent message surface.

### Implementation-ready geometry and roles

| Token/behavior | Recommended value | Implementation note |
|---|---:|---|
| Physical top fade reach | `52 pt` (existing `MailWindowTopDissolvePolicy.titlebarDepth`) | Treat this as the physical fade reach, not readable content padding. |
| Subject top inset | `max(measured safeAreaInsets.top, 52 pt) + 12 pt` | With the current 52-point fade, subject starts at `64 pt` from physical top. If measured titlebar safe area is larger, use the larger value. |
| Horizontal reader padding | `24 pt` at normal width; do not go below `20 pt` | Apply to region surfaces and the full-width pane. Use leading/trailing, not left/right. |
| Subject-to-header spacing | `12 pt` | Subject region ends before header region; do not merge them into one glass card. |
| Header row spacing | `8 pt` compact; `6 pt` within label/value pairs | Wrap rows naturally when recipients or Dynamic Type require it. |
| Header-to-attachment spacing | `10 pt` | Attachments are part of the envelope region, visually separated from the body. |
| Header/body divider | `1 pt` semantic `regionDivider` | In increased contrast, use the strongest available separator role; do not depend on shadow. |
| Body start spacing | `20 pt` after divider | Gives the body a clear reading-region start. |
| Subject style | semantic `.title2`, `.semibold`, primary/strong text role | Unlimited wrapping in the open reader; no security-relevant ellipsis. A list preview may remain limited independently. |
| Sender style | semantic `.headline` or `.subheadline` with strong text role | Display name and actual address are separate selectable text runs when available. |
| Metadata style | semantic `.subheadline` / `.caption` only for secondary labels | Never reduce the address itself to a low-contrast caption. |
| Body style | semantic `.body` (environment-scaled), default readable measure `72ch` | The pane remains full width; plain text can be constrained within it. Do not prescribe a final theme color. |
| Body line/paragraph rhythm | `1.35–1.5` line-height; `10–12 pt` paragraph gap | Use platform text metrics where possible; avoid fixed 13-point typography for accessibility sizes. |
| HTML width | Full available pane by default, with safe horizontal padding | HTML-authored layout may intentionally be wide; preserve sanitization and remote-image gating. |
| Raw source width | Full available pane, monospaced, selectable | Raw source is diagnostics, not the comfortable body measure; allow horizontal scrolling only inside the raw-source surface if unavoidable. |
| Surface roles | `viewerSurface`, `subjectSurface`, `headerSurface`, `bodySurface` | Opaque by default; optional theme tint is semantic and comes later. No blur/glass/transparency. |
| Disclosure default | Compact From + actual address, To/Cc summary, date, attachments; `Details` collapsed | Details expands all visible envelope fields, including Reply-To and full wrapped recipient rows. |
| Recipient summary | First visible address plus `+N` per To/Cc group | The `+N` is a disclosure summary, never the only accessible representation; expanded rows must be selectable. |
| Raw-header action | Separate `View Raw Source` / `Show All Headers` command | Do not put raw MIME/routing data inside the compact Details expansion. |
| Scroll ownership | One vertical `ScrollView` for subject/header/body; no nested body/header scroll | A fixed titlebar/action strip is allowed outside the scroll view; metadata should scroll with its message. |
| Top fade behavior | Mask/dissolve may remain at the window edge, but content begins after fade reach + 12 pt | Do not use the fade as a readable background or allow subject glyphs to sit in its ramp. |
| Reduced transparency | All four surfaces become fully opaque; remove alpha overlays and blur | Follows Apple's `accessibilityReduceTransparency` guidance. |
| Increased contrast | Strengthen primary/secondary text and divider roles; keep borders/underlines available | Follows SwiftUI `ColorSchemeContrast.increased`; never communicate a region only with tint. |
| Reduced motion | Disclosure changes use opacity/layout only, with no spring requirement | Preserve existing reduced-motion environment handling. |

### Disclosure interaction contract

1. Compact state always shows `From`, sender display name plus address, `To` summary, `Cc` summary when present, date, and attachment summary. Unknown or suspicious-looking senders do not get an address-hidden avatar-only treatment.
2. `Details` is a real semantic disclosure control with an accessible label such as “Message details, collapsed/expanded.” Tab focus reaches it; Space/Return toggles it; the menu exposes the same action.
3. Expanded state wraps all visible To/Cc addresses, shows Reply-To when present, exposes the absolute date/time and relevant account/folder context, and keeps every address selectable. A long recipient list grows the header; it does not create horizontal clipping.
4. `View Raw Source` is a sibling action. It opens the existing raw-source pathway in a monospaced, selectable diagnostic region and does not replace the human-readable compact header.
5. If the message is in a thread later, each message gets its own identity/header/body regions. Older messages may collapse, but expansion must preserve sender/date and never hide which message owns an attachment.

## iOS follow-through (same principles, phone-specific geometry)

Keep the same semantic order—subject, sender/address, recipient disclosure, attachments, body, raw-source escape hatch—but do not copy macOS's 52-point titlebar token or desktop hover actions. Start content below the actual navigation safe area, use full-width phone content with 16-point leading/trailing padding as a phone baseline, let the header stack at larger Dynamic Type sizes, and use tap/long-press actions instead of pointer hover. Keep attachments inline or at the end according to MIME/content disposition, matching Apple's documented iPhone behavior: [Apple iPhone User Guide](https://support.apple.com/guide/iphone/check-your-email-iph461684497/ios), [Apple iPhone attachments](https://support.apple.com/guide/iphone/add-email-attachments-iph8580f163b/ios).

The information principles are shared; the layout is not. On iOS, a compact sender row and a tap-to-expand Details row are preferable to a desktop details column. Full headers/raw source can be a sheet or dedicated diagnostic view reached from the message action menu, while normal reading remains calm and body-first after the compact envelope.

## Primary sources consulted

- [Apple Mail User Guide — Read and respond to emails on Mac](https://support.apple.com/guide/mail/read-and-respond-to-emails-mlhlp1010/mac)
- [Apple Mail User Guide — Change Viewing settings](https://support.apple.com/guide/mail/change-viewing-settings-cpmlprefview/mac)
- [Apple Mail User Guide — View, save, or delete email attachments](https://support.apple.com/guide/mail/view-save-or-delete-email-attachments-mlhlp1123/mac)
- [Apple Mail User Guide — Change Privacy settings](https://support.apple.com/guide/mail/change-privacy-settings-mlhlae4a4fe6/mac)
- [Apple iPhone User Guide — Check your email in Mail on iPhone](https://support.apple.com/guide/iphone/check-your-email-iph461684497/ios)
- [Apple iPhone User Guide — Add email attachments](https://support.apple.com/guide/iphone/add-email-attachments-iph8580f163b/ios)
- [Apple iCloud User Guide — View all email headers](https://support.apple.com/guide/icloud/view-all-email-headers-mmcc887ce9/icloud)
- [Gmail Help — Trace an email with its full header](https://support.google.com/mail/answer/29436?hl=en)
- [Gmail Help — Open and download attachments](https://support.google.com/mail/answer/30719?hl=en-GB&co=GENIE.Platform%3DDesktop)
- [Gmail Help — Avoid and report phishing emails](https://support.google.com/mail/answer/8253?hl=en)
- [Gmail Help — Fix problems importing mail (thread expansion)](https://support.google.com/mail/answer/7239777?hl=en)
- [Microsoft Support — View internet message headers in Outlook](https://support.microsoft.com/en-us/outlook/view-internet-message-headers-in-outlook)
- [Microsoft Support — Open, save, and edit attachments received in Outlook](https://support.microsoft.com/en-us/outlook/mail/open-save-and-edit-attachments-received-in-outlook)
- [Microsoft Support — Show, hide, and view the Bcc field](https://support.microsoft.com/en-us/outlook/mail/show-hide-and-view-the-bcc-blind-carbon-copy-field-in-outlook-for-windows)
- [Thunderbird Source Docs — Mail Display](https://source-docs.thunderbird.net/en/latest/frontend/mail_display.html)
- [Thunderbird current `msgHdrView.js`](https://searchfox.org/comm-central/source/mail/base/content/msgHdrView.js)
- [Mimestream User Guide — Viewing Messages](https://mimestream.com/help/user-guide/viewing-messages)
- [Mimestream User Guide — Changing Viewing Settings](https://mimestream.com/help/user-guide/viewing-settings)
- [Mimestream User Guide — Adding Attachments to Drafts](https://mimestream.com/help/user-guide/adding-attachments)
- [Spark Help — Threads](https://sparkmailapp.com/help/manage-your-inbox/threads-in-spark)
- [Spark — Attachments](https://sparkmailapp.com/features/attachments)
- [Apple HIG — Disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls)
- [Apple HIG — Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- [Apple HIG — Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Apple SwiftUI — `DisclosureGroup`](https://developer.apple.com/documentation/swiftui/disclosuregroup)
- [Apple SwiftUI — `Font`](https://developer.apple.com/documentation/swiftui/font)
- [Apple SwiftUI — `DynamicTypeSize`](https://developer.apple.com/documentation/swiftui/dynamictypesize)
- [Apple SwiftUI — `accessibilityReduceTransparency`](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducetransparency)
- [Apple SwiftUI — `ColorSchemeContrast`](https://developer.apple.com/documentation/swiftui/colorschemecontrast)
- [Apple AppKit — `NSView.safeAreaInsets`](https://developer.apple.com/documentation/appkit/nsview/safeareainsets)
