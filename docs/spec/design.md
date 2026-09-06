# Mailternal — Design Language (derived from Hermternal)

Mailternal matches Hermternal's aesthetics. **The values in this document are the
normative contract** — implementable with no other input. Hermternal source-file
pointers (`~/Developer/hermternal-apple`, e.g. `MainWindowController.swift`) are
non-normative provenance/examples only; absence of that checkout never blocks
implementation. Performance, aesthetics, polish are the product's top priorities.

## Governing rules (from Hermternal AGENTS.md/CLAUDE.md — adopted verbatim)
- **Native-first**: use a public AppKit or SwiftUI system component whenever it
  supplies the required behavior. Do not recreate its sizing, adaptive appearance,
  hover/pressed chrome, focus, or accessibility with custom drawing or gestures.
  Custom surfaces require a documented functional gap, approval, and measurement.
  No stacked materials. Preserve clean AppKit⇄SwiftUI seams.
- Semantic colors and text styles everywhere; dynamic light/dark/contrast for free.
- Respect Reduce Motion and Reduce Transparency with explicit alternate paths.

## Interaction polish references

When designing or reviewing interactions, consult [Jakub Krehel's UI skills](https://jakub.kr/skills)
([source](https://github.com/jakubkrehel/skills)) for optical alignment, hit areas,
state feedback, and motion restraint. These are supplementary design references,
not a second design system; this document and native platform behavior govern.

- Apply the principles through standard AppKit/SwiftUI components and existing
  motion tokens. Preserve system hover, pressed, focus, selection, and disabled
  treatment rather than copying CSS values, web controls, or animation libraries.
- Small interactions are product quality: feedback should be immediate, transitions
  should preserve context and tolerate interruption, and motion must have a static
  state cue. Keep routine navigation and scrolling free of decorative delays.
- Review the actual native surface across hover, press, keyboard focus, loading,
  empty and disabled states, interrupted transitions, and Reduce Motion. Polish
  must preserve accessibility, stable layout, and the existing performance gates.

## Architecture pattern
- AppKit owns the window shell; SwiftUI owns content.
  (`MainWindowController.swift`: NSWindow titled/closable/miniaturizable/resizable/
  fullSizeContentView; `HermternalApp.swift`: suppressed Settings scene, commands.)
- Main window: title text hidden (`title=""`, `titleVisibility=.hidden`,
  `titlebarAppearsTransparent=true`), `toolbarStyle=.unified`; default 1040×720,
  min 760×480.
- Content: `NavigationSplitView` with
  `.navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 340)` sidebar.
  Mailternal's three-pane (folders / message list / viewer) extends the same
  NavigationSplitView vocabulary.
- Settings: AppKit `NSSplitViewController`, full-height non-collapsible source-list
  sidebar (150…280, divider 172, `titlebarSeparatorStyle=.none`), detail min 480;
  window 720×460 (min 660×460), AX floating-window subrole.
  (`SettingsSplitView.swift`)

## Typography
System San Francisco via semantic styles only.
- Body: `.body` (13 pt macOS), line spacing 2 / line height 18, paragraph gap 10.
- Headings: L1 `.title2`, L2 `.title3`, L3 `.headline`, L4 semibold body; default
  `.subheadline`.
- Code/monospace: `.monospacedSystemFont(ofSize: .callout.pointSize, weight:.regular)`;
  inline code = current size monospaced. (`MarkdownMessage.swift`,
  `BlockTranscriptView.swift`)
- Reading measure 490 pt max content width, 20 pt inset — apply to the message viewer's
  plain-text rendering.

## Shape tokens (`Support/ShapeScale.swift`) — continuous corners
window 24 · card 18 · toast 14 · row 12 · compact 8.

## Color & materials
- **No color asset catalog.** Dynamic semantic NSColors only: label/secondary/
  tertiary, controlBackground, windowBackground, separator, link, findHighlight,
  selection. Accent = `controlAccentColor` or persisted sRGB override
  (`AppearanceSettings.swift`); tint propagates via environment.
- Accent-foreground contrast: black/white chosen at luminance 0.179128784747792
  (`PlatformPalette.swift`, WCAG policy).
- Window backdrop: opaque / blur / Liquid Glass are **mutually exclusive**; default
  opacity 0.85. Blur uses **public API only**: `NSVisualEffectView`
  `.underWindowBackground`, `.behindWindow`, `.active`. (Hermternal's private CGS
  blur is NOT adopted — Mailternal is MAS-distributed; private SPI is prohibited.)
  Glass = `.glassEffect(.regular)` clipped to continuous window radius.
  Reduce Transparency / fullscreen forces opaque.

## Pane edge dissolves (`MailWindowDissolvePolicy`)
- One compositing mask per pane, no material overlay: the exposed window backdrop
  supplies the blur. Shape is Hermternal's smoothstep sampled at eighths; panes
  share it and differ only in where the top ramp starts.
- **Sidebar**: the top ramp is anchored at the fixed 52 pt window titlebar
  depth and is opaque 32 pt below it, leaving the account title's cap-height
  band clear; the `List` ignores the container top safe area and carries a
  fixed 40 pt scroll-content inset plus the header's 12 pt optical padding.
  The account title uses the same 26 pt bold type as the message-list folder
  heading. It stands alone—never followed by a redundant “Folders” label—and
  retains 10 pt of header air before the first folder row. The
  system scroll-edge pocket is suppressed on this list. Bottom ramp 48 pt,
  ending above the fixed account inset.
- **Message list**: the pane ignores the top safe area, its large title is
  anchored at the same fixed 52 pt window depth, and the table reserves the
  title's measured frame below that anchor. Its top dissolve is independent
  of safe-area changes; the system scroll-edge pocket is suppressed on the
  AppKit table scroll view. Bottom ramp 48 pt at the pane edge. Cards carry
  **no column-header chrome**. The optional dense columns presentation pins a
  24 pt native table header below the title band, outside its dissolve, and
  uses compact status icons with full accessibility labels. Windowed-mode
  coverage is disclosed in the ⌘K panel.
  When multiple messages are selected, the title moves up by the subtitle's
  measured height plus its 1 pt separation, and a secondary, tabular-number
  “X messages selected” subtitle fades in. Selection takes precedence over
  current-folder downloading, indexing, or moving status; otherwise show that
  real activity, with progress only when supplied by the operation. Keep the
  title-only header footprint: subtitle presence must not push the first row
  or the 16 pt top dissolve down or reset the list scroll position. The resting
  gap follows the [approved reference](https://img.kayg.org/u/iFvdoh.png), not
  the [excess-spacing regression](https://img.kayg.org/u/iWMiiV.png); row text's
  own 10 pt top inset is additional to the ramp, not another header band.
  Keep one stable `Text` with `.numericText()` across subtitle updates, driven
  by a zero-bounce `.smooth(duration: 0.24)` animation. Numeric runs roll;
  whole-word/state changes use the content transition's fallback rather than
  replacing the view. The same animation lifts the title for subtitle
  presence; Reduce Motion updates immediately.
- **Reader, side-by-side**: the top ramp starts exactly where the tab strip ends
  (46 pt: the 40 pt strip centred in the 52 pt titlebar) and reaches 24 pt into
  the pane. The subject glyph rests one 12 pt guard below the ramp. No bottom ramp.
- **Reader, list above reader**: tabs and reader actions occupy one 40 pt row
  at the top of the lower split pane. The scroll viewport below that row uses
  a local 16 pt ramp and the same 12 pt glyph guard; it MUST NOT reserve the
  window titlebar again. The panes meet at the native split divider with no
  additional spacer. The sidebar toggle remains in the window titlebar.

## Component vocabulary (reuse the pattern, adapt to mail)
- **Sidebar rows**: native `List` label rows with context menus, swipes, drag/drop
  (Hermternal `SessionRow`/`FolderRow`/`AccountRow` → Mailternal folder rows with
  unread badges and backfill progress).
- **Large virtualized list**: AppKit `NSTableView` with reused cells behind a SwiftUI
  seam (`BlockTranscriptView.swift`) — this is the message-list pattern; SwiftUI
  `List` is not acceptable at 100k rows.
- **Glass card** (composer pattern): `glassEffect(.regular.interactive())`, rounded
  continuous toast radius, rows H16/V11, outer H18/top10/bottom16.
- **Command-K search panel** (`SearchPanel.swift`): full-screen material backdrop;
  card thinMaterial radius 18, border 0.18/0.75 (1.5 in increased contrast), shadow
  black 0.28 radius 28 y14; glass capsule field H16/V11, 17 pt rounded font; panel
  width max 680/min 280, top third of window, max height ⅓. **This is Mailternal's
  mail-search surface.**
- **Find capsule** (`FindBar.swift`): H12/V8, thickMaterial capsule, 0.5 separator —
  in-message find.
- **Toasts** (`ToastPresenter.swift`, `ToastQueue.swift`): gap 14, scale step 0.05,
  rendered limit 3, width max 360, card min height 44, H14/V11, radius 14; use for
  transient sync/auth errors.
- **Empty states**: centered mark + secondary text (Hermternal empty-transcript
  pattern).

## Settings panes

- **Accounts** uses a native `List` so account rows retain platform swipe actions:
  Enable/Disable and Remove. Context-menu and hover actions remain available as
  secondary affordances.
- Expanding an account inserts its inline editor as a separate `List` row inside
  `withAnimation(MailMotion.expand)`; collapsing removes that row. The native Add
  Account toolbar item remains the entry point and expansion scrolls the account
  row into view.
- A disabled account remains in the Accounts list as a dimmed row with a red
  status dot. The “No accounts” empty state is shown only when there are no
  account configurations.
- **Cache** keeps the top-level **All** toggle. Each account row reads left to
  right as disclosure caret, unlabeled tri-state “all folders” checkbox, account
  name, and right-aligned secondary email. Folder rows retain a checkbox, name,
  and message-count caption, with the pane's breathing-room spacing.
- **Pair Device** lives inside **Sync** on macOS and iOS, not in a separate
  top-level section. It remains available with iCloud workspace sync disabled:
  explicit account handoff and ongoing workspace synchronization are distinct.
- The macOS pairing sheet has a 560 × 600 pt minimum presentation size so the
  complete QR code and white quiet zone are visible at the initial scroll
  position. Longer account lists and secondary controls remain scrollable.
- **iOS Settings** uses a native navigation stack in a clear Liquid Glass sheet.
  One presentation material backs translucent grouped rows; do not stack a glass
  effect on each row. Reduce Transparency uses an opaque semantic background.
  Each settings section is a navigation row by default, including Accounts,
  Appearance, Gestures, Sync, Mail state, and Pending actions.
- A native **Search settings** field stays at the top of the iOS settings root.
  Search covers setting labels and vocabulary across sections and navigates to
  the existing controls; it never indexes passwords or mail content. Empty
  searches restore the selected settings layout. macOS settings search is not
  part of this surface yet.
- Directly below search, **Flat View** is a full-row checkbox, off by default.
  Checking it presents those same sections and controls inline. The preference
  persists across sheet dismissal and app launches, participates in appearance
  sync, and is retained through pairing. Older saved state defaults to off without
  discarding navigation or reading preferences. On iOS, the checkbox drawing
  retains native Toggle accessibility and a minimum 44 pt touch target.

## Reader envelope

- Sender and recipient remain separate content-sized copy targets, with optional
  monograms controlled by **Appearance ▸ Sender icons**. Each pill's hover,
  keyboard-focus and copy-feedback bounds fit its text/icon plus padding,
  never stretch into unused reader width, and compress for narrow windows.
  A single accent
  connector occupies the left direction column: it leaves the sender toward
  the left, rounds into a straight vertical segment, then rounds right into an
  open arrowhead pointing at the recipient. Its endpoints track the measured
  row centers, so spacing and row-height changes stretch the middle segment
  without distorting the rounded corners. It has round caps/joins, no waviness
  or motion, and is hidden from accessibility. Reference:
  [rounded envelope connector](https://img.kayg.org/u/blS8vt.png).
- The former per-row arrow-circle symbols MUST NOT appear. Sent/delivered date
  rows retain their semantic paper-plane and tray glyphs.

## Motion (exact values; all with Reduce Motion alternates)
- Sidebar toggle: `.snappy(duration: 0.24, extraBounce: 0)`.
- Disclosure/hover: easeOut 0.12.
- Search panel: spring response 0.36 damping 1 (RM: easeOut 0.18).
- Composer-class cards: smooth 0.18 / snappy 0.18.
- Toasts: enter spring 0.40 bounce 0.16 (enterScale 0.94, offset −12); exit
  timingCurve(0.23,1,0.32,1) 0.20; restack 0.34/0.10; expand 0.30/0; settle
  0.32/0.22; fling 0.16; RM: enter 0.16, exit 0.12, restack easeInOut 0.18.
- Pairing QR: one deterministic 16×16 tile-mask reveal over 0.48 s for a new
  invitation. Keep the code stationary, retain its white quiet zone, and finish
  with the exact unmasked QR pixels. Unrelated updates must not replay it;
  Reduce Motion and interruption show the complete code without animation.

## Reader tab strip

The reader tab strip MUST be Craft-like in finish and browser-like in
mechanics. In the side-by-side layout it MUST occupy one measured row in the
window's native unified titlebar/toolbar, over the reader column, with no
accessory row. In the list-above-reader layout that same tab strip and its
actions MUST move to the lower reader pane, not remain above the message list.
Its leading viewport edge, including the leading scroll fade,
MUST align with the subject card's measured outer left edge. The clear end of
the trailing fade MUST meet the native action capsule's measured leading edge;
standard image/menu items require their native accessibility geometry, not a
guessed cluster width or an assumed `NSToolbarItem.view`. There is no extra
outer trailing inset. Only an overflowing strip reserves a 28 pt scroll tail,
so its last tab can become fully visible before the fade.
The strip container MUST be clear so the native toolbar material shows through. It MUST
be present only when at least two tabs are open, and MUST be absent while global
search is presented. A lone tab stays active in the reader without a visible tab
strip; hiding the strip MUST NOT close that tab or clear its message.
The active tab MUST be revealed when the strip appears, its active identity
changes, or its viewport/intrinsic tab widths change. Ordinary wheel scrolling
MUST remain user-controlled; scroll offsets MUST NOT invalidate every tab body.
The titlebar's tab view MUST use Auto Layout with a compressible preferred
width and a required upper bound; do not pin legacy `NSToolbarItem.minSize`
and `maxSize` to a measured viewport. Allocation flows from pane/action
geometry to the strip; the strip's resulting frame may affect its fade but
MUST NOT feed back into its own width allocation. Native actions have priority
over the scrollable tab region. Keep system overflow only for genuine lack of
space, and retain window geometry when a hosted item is detached so shrinking
and returning to the same width restores the same controls.


`⌘W` closes the active tab only while focus is in the reader pane. Closing the
last tab leaves the window open with an empty reader. If there are no tabs, or
focus is in the sidebar or message list, `⌘W` closes the window instead. Explicit
tab-close controls close their target tab without closing the window.
Closing the active tab MUST preserve reader command focus even when the strip
disappears in the two-to-one transition.

### Tabs and actions

- In side-by-side layout, the tab viewport belongs to the toolbar's reader-tabs
  item. Three adjacent native items expose Archive, Trash, and More. In stacked
  layout, a pane-local row contains the same tabs and three native AppKit glass
  controls. Both presentations share the same command/menu policy and AppModel
  mutation paths. Flag, Raw Source, Email Reading mode, and the remaining reader
  actions live inside More. The sidebar toggle remains in the titlebar.
  The reader-tabs toolbar item has no label or tooltip; customization is disabled.
- Each tab MUST use its intrinsic width:
  `(leading slot + subject text width + inter-item spacing + title paddings)`,
  clamped to 72–220 pt. Subject title leading padding is 4 pt and trailing
  padding is 10 pt. Tabs MUST be separated by 8 pt and MUST NOT stretch to
  consume spare viewport width. Scrolling MUST occur beneath a fixed 28 pt
  right-edge fade at the end of the tab viewport, directly against the
  actions cluster with no extra gap. Once content scrolls beneath the leading
  edge, apply the same 28 pt alpha fade there instead of a hard vertical clip.
  Keep the leading edge fully opaque at the start of the scroll range.
- In the window toolbar, the trailing actions (Archive, Trash, More) are adjacent,
  individual native `NSToolbarItem` / `NSMenuToolbarItem` controls, not a custom
  item group or hand-drawn capsule. Leave `view` unset and enable native borders:
  AppKit owns standard toolbar symbol sizing, hit targets, spacing, focus,
  disabled state, and hover/pressed treatment. More uses plain `ellipsis`, not a
  circle baked into its symbol. Do not substitute custom buttons,
  symbol point sizes, image scaling, fixed icon dimensions, or painted tracking
  backgrounds. The target is compact, separate glyphs with native interaction
  chrome, as in the [Craft reference](https://img.kayg.org/u/ngKxVt.png).
  The active tab fill is `textBackgroundColor` (white / near-black); hover is
  `quaternarySystemFill`.
- Its title MUST contain only the subject, MUST use semantic `.subheadline`, and
  MUST use the trailing fade mask when compressed. The active tab MUST use
  semantic selection treatment and label color; inactive tabs MUST have no fill
  and MUST use secondary label color. The active treatment MUST remain legible
  in light, dark, and increased-contrast appearances.
- Transient and permanent titles share one style (no italics): the active
  fill alone marks state, and "Keep" in the tab menu reveals a transient. A
  tab title or accessory MUST NEVER show unread or flag indicators.
- Single-click activation MUST NOT wait for double-click recognition. A
  double-click may keep a transient tab, but must recognize simultaneously with
  ordinary activation rather than taking priority over the button.
- Tab backgrounds MUST use a continuous `AppShapeScale.row` (12 pt) corner
  radius. The right-edge fade MUST be a 28 pt transparent mask drawn above
  scrolling tabs and MUST NOT capture tab input. No strip-level fill may
  obscure the toolbar material.
- The leading mask MUST remain opaque at scroll origin and fade only after
  content moves off the leading edge. Continuous scroll offsets MUST NOT
  invalidate the SwiftUI tab strip; only the origin-crossing Boolean may do so.
- The More menu MUST contain Flag, Raw Source, Email Reading mode, and every
  other reader action not named Archive or Trash. Archive and Trash MUST
  remain directly reachable beside More in either pane arrangement.

### Tab display styles

The tab display style is persisted in Appearance Settings and defaults to
**Icon and Text**. It is available from **View > Tab Style**, from the empty
strip background context menu, and from each tab's context menu; the three
choices are mutually exclusive:

- **Icon** shows only the sender glyph. The glyph is the sender domain's
  favicon when available, with a sender-initial circle as the fallback.
- **Icon and Text** shows the sender glyph followed by the subject.
- **Text** shows only the subject. Its leading slot collapses while idle; on
  hover, the close (×) affordance appears in that slot and the subject shifts
  right. The shift uses `MailMotion.hover`.

### Hover preview card

- Hovering an inactive tab MUST immediately show a floating card beneath that
  tab with no dwell delay or entrance animation; the active tab never shows a
  card (its content is already on screen). Leaving the tab MUST dismiss it
  after a 150 ms grace period unless the pointer is over the card; moving
  directly to another tab transfers the card immediately.
- The card MUST be a system `NSPopover` (`.applicationDefined` behaviour,
  no animation) anchored below the hovered tab, exactly 220 pt wide by
  160 pt high, whose whole content scrolls as one piece without a scroll
  indicator. The popover supplies the chrome (the same as the QR-code
  popover); the card paints no background of its own. 14 pt horizontal and
  12 pt vertical padding.
- If sender and received time are already available locally, the card MUST
  include them in a compact metadata line; otherwise it MUST omit them and MUST
  NOT fetch them. It MUST NEVER fetch remote content, mark the message read,
  alter selection or either scroll position, or reflow the reader; it MUST
  overlay the reader content below the toolbar.
- HTML-to-text preview extraction MUST be deferred until a hover card is
  requested; tab measurement and ordinary scrolling MUST NOT parse HTML bodies.

References: [Craft Tab Management](https://support.craft.do/en/introduction/navigation/tabs)
(tab-layout image and tab-preview description); [Chrome keyboard shortcuts](https://support.google.com/chrome/answer/157179)
(browser tab-strip switching description); [W3C Content on Hover or Focus](https://www.w3.org/WAI/WCAG22/Understanding/content-on-hover-or-focus.html)
(hover-card interaction guidance).

## Polish checklist
- Keyboard: ⌘F in-message find, ⌘K global search, ⌘, settings, ⌘R reload/refresh;
  full focus scopes + `defaultFocus`; Escape dismisses transient surfaces.
- Hover states on rows/controls; context menus everywhere a right-click is natural.
- No haptics/sounds (Hermternal ships none).
- Every custom surface must be *approved and measured* — default to the system one.

## Mailternal-specific mappings
| Surface | Pattern |
|---|---|
| Folder sidebar | Hermternal sidebar List rows + unread badge + per-folder backfill progress |
| Message list | NSTableView-behind-SwiftUI virtualized list, row radius 12, keyset-paged |
| Message viewer | Reading-measure content column; WKWebView for HTML inside the same inset geometry |
| Global search | Command-K panel, verbatim geometry; carries the windowed-mode coverage line |
| Account setup | Settings-style grouped form in a floating utility window |
| Sync/auth errors | Toast stack |

### Message-list row anatomy

Each message-list row is an AppKit table row with continuous 12 pt corners and
the existing sender, subject/preview, date, unread, flag, attachment, and swipe
surfaces. When **Appearance ▸ Sender icons** is enabled, a leading icon column
is reserved:

| Visible row lines | Icon diameter | Leading inset | Text origin |
|---:|---:|---:|---:|
| 1 | 20 pt | 8 pt | 36 pt |
| 2 | 28 pt | 8 pt | 44 pt |
| 3–6 | 32 pt | 8 pt | 48 pt |

The icon is vertically centered with a 4 pt minimum top/bottom inset. It uses
the sender-domain favicon with aspect-fill scaling and a circular clip; until
the favicon is cached, the sender display-name monogram is shown in the
accent-tinted circle. With sender icons disabled, the icon column collapses and
the text origin remains the original 16 pt inset.

### Sidebar sync activity indicators

Folder rows use one compact trailing accessory for the current activity. While a
backfill window is downloading or its fetched rows are being indexed/committed,
show the standard small spinner. Hovering the spinner exposes the current local
progress when available, for example “Downloading messages — 42%” or
“Indexing messages — 42%”.
Disk-policy halts retain the existing `pause.circle` glyph. Idle folders and
quarantine stalls do not add an accessory, so a row never becomes visually noisy.
