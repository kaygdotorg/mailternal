# Mailternal — Design Language (derived from Hermternal)

Mailternal matches Hermternal's aesthetics. **The values in this document are the
normative contract** — implementable with no other input. Hermternal source-file
pointers (`~/Developer/hermternal-apple`, e.g. `MainWindowController.swift`) are
non-normative provenance/examples only; absence of that checkout never blocks
implementation. Performance, aesthetics, polish are the product's top priorities.

## Governing rules (from Hermternal AGENTS.md/CLAUDE.md — adopted verbatim)
- **Native-first**: system components before custom ones; custom surfaces only when
  approved and measured. No stacked materials. Preserve clean AppKit⇄SwiftUI seams.
- Semantic colors and text styles everywhere; dynamic light/dark/contrast for free.
- Respect Reduce Motion and Reduce Transparency with explicit alternate paths.

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
- **Sidebar**: the top ramp starts at the *measured* titlebar safe area (documented
  fallback 52 pt) and is opaque 32 pt below it, so rows are gone before they reach
  the traffic lights and no ink lands behind them; the `List` carries a matching
  32 pt top scroll-content margin so the first section rests at the ramp's end.
  Bottom ramp 48 pt, ending above the fixed account inset.
- **Message list**: the pane ignores the top safe area, so its ramp is anchored at
  the physical window top and is opaque at 52 pt; the table's top scroll-content
  inset is that same depth. Bottom ramp 48 pt at the pane edge. The column carries
  **no top chrome** — windowed-mode coverage is disclosed in the ⌘K panel.

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

## Motion (exact values; all with Reduce Motion alternates)
- Sidebar toggle: `.snappy(duration: 0.24, extraBounce: 0)`.
- Disclosure/hover: easeOut 0.12.
- Search panel: spring response 0.36 damping 1 (RM: easeOut 0.18).
- Composer-class cards: smooth 0.18 / snappy 0.18.
- Toasts: enter spring 0.40 bounce 0.16 (enterScale 0.94, offset −12); exit
  timingCurve(0.23,1,0.32,1) 0.20; restack 0.34/0.10; expand 0.30/0; settle
  0.32/0.22; fling 0.16; RM: enter 0.16, exit 0.12, restack easeInOut 0.18.

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
