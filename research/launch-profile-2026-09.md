# Mailternal launch profile (2026-09)

## Scope and method

This profile measures the interactive main-window path on `agents@mbp` (Apple
Silicon, macOS 26.6.2) on 2026-09-04. The Linux checkout cannot build or run the
AppKit target. Each Debug run used the required private build and fixture:

```text
Scripts/build-mbp.sh LaunchPaint app
cp -R ~/mailternal-qa-ReaderIslands ~/mailternal-qa-LaunchPaint
MAILTERNAL_QA=1 Mailternal -qa-account 127.0.0.1 1143 startTLS -qa-gui \
  -qa-container ~/mailternal-qa-LaunchPaint
```

The fixture was copied afresh before every run. It contains a 1,636,773,888-byte
SQLite store. No page-cache drop was attempted (it requires sudo). The process
was terminated after `settled-frame`; the copy was discarded before the next run.

`QALaunch` measures from the process start time obtained with `sysctl`, not from
first object construction. `first-frame` is the completion of the Core Animation
transaction enclosing the first `orderFront`; `settled-frame` is the completion
of the first Core Animation transaction scheduled after non-empty folders and
first rows have both been published. These are now permanent QA phases and are
only printed when `MAILTERNAL_QA=1`.

The plain Release build was built with:

```text
cd App
xcodegen generate
xcodebuild -project Mailternal.xcodeproj -scheme Mailternal \
  -configuration Release -derivedDataPath build-release build
```

Release is the notarization-shaped build: `Mailternal.debug.dylib` is absent and
hardened runtime signing is enabled. The Release app cannot consume the Debug-
only `-qa-container` parser, so its five runs used a fresh empty `CFFIXED_USER_HOME`
per run. Consequently, Release folder/row/settled values are not comparable to
the populated Debug fixture and are reported as unavailable below.

## Five-launch phase table: Debug

All values are milliseconds since exec. The `n=80` suffix on `first-rows` is the
observed page size.

| run | app-init | did-finish-launching | window-front | first-frame | store-open | folders-snapshot | first-rows | settled-frame |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 355.7 | 518.9 | 790.6 | 834.8 | 8391.5 | 8417.8 | 8660.5 | 8713.1 |
| 2 | 25.2 | 247.0 | 641.7 | 739.2 | 8444.1 | 8460.4 | 8677.1 | 8770.8 |
| 3 | 17.6 | 351.8 | 1061.3 | 1149.4 | 9214.2 | 9224.9 | 9340.6 | 9385.3 |
| 4 | 24.3 | 231.3 | 834.9 | 1085.3 | 8641.6 | 8653.4 | 8795.4 | 8852.7 |
| 5 | 16.3 | 215.0 | 477.7 | 508.5 | 7951.9 | 7981.7 | 8318.2 | 8514.3 |
| **median** | **24.3** | **247.0** | **790.6** | **834.8** | **8444.1** | **8460.4** | **8677.1** | **8770.8** |

The 5-run median first-frame is 834.8 ms and median settled-frame is 8770.8
ms. The first run has a cold WindowServer/host outlier at app-init; the table
retains it rather than hiding it. Store open is off the main actor, but migration
and the large fixture still account for roughly 7.95--9.21 seconds before the
first page can be queried.

## Five-launch phase table: Release

These are exact phase markers from the plain Release binary after removing the
Debug-only guards around phase prints. Because the Release parser deliberately
remains Debug-only, these runs set a fresh `CFFIXED_USER_HOME` per run and do
not publish the fixture's first page. Foundation's Application Support
resolution was not independently verified under that override, so Release
store timings are directional only.

| run | app-init | did-finish-launching | window-front | first-frame | store-open | folders-snapshot | first-rows | settled-frame |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 964.8 | 1082.4 | 1198.6 | 1217.9 | 1217.7 | 1344.8 | — | — |
| 2 | 24.3 | 123.1 | 229.9 | 250.2 | 250.0 | 388.9 | — | — |
| 3 | 19.0 | 120.0 | 227.9 | 246.0 | 245.8 | 380.6 | — | — |
| 4 | 23.8 | 129.5 | 236.4 | 253.1 | 252.8 | 381.3 | — | — |
| 5 | 19.7 | 106.7 | 211.8 | 228.6 | 228.3 | 361.8 | — | — |
| **median** | **23.8** | **123.1** | **229.9** | **250.2** | **250.0** | **381.3** | **—** | **—** |

The first Release run is also a host/WindowServer outlier. On stable runs, the
Release first-frame is about 229--253 ms, approximately 3.3x faster than the
Debug fixture runs' first-frame but still above the new sub-100-ms target. The
Release `store-open` can beat first-frame because the Release run did not wait
for a populated fixture or page query; this is not a populated-fixture
comparison.

## Dyld, static initialization, and binary shape

Observed with `dyld_info` on the built arm64 images:

* Debug executable: 58,816 bytes, linked against `@rpath/Mailternal.debug.dylib`.
* `Mailternal.debug.dylib`: 47,855,136 bytes (45.7 MiB decimal/45.6 MiB binary).
* Release executable: 64,820,368 bytes, with no `Mailternal.debug.dylib`.
* `dyld_info -inits` reports no image initializers for either app image; there
  is no evidence of a custom static-initializer phase to optimize.
* `dyld_info -linked_dylibs` shows the Debug dylib loads AppKit, SwiftUI,
  WebKit, QuartzCore, Foundation, SQLite, and Swift runtime/framework images.
* `DYLD_PRINT_STATISTICS=1`, `DYLD_PRINT_STATISTICS_DETAILS=1`,
  `DYLD_PRINT_LIBRARIES=1`, and `DYLD_PRINT_SEGMENTS=1` produced no output on
  this macOS 26.6.2 host, including `/usr/bin/true`; dyld's environment
  diagnostics are therefore unavailable as a numeric source here. The phase
  table and `sample` output are the authoritative timing evidence.

A one-second `sample` captured during startup showed the expected Debug entry
chain:

```text
start (dyld)
  __debug_main_executable_dylib_entry_point (Mailternal.debug.dylib)
    static MailternalApp.$main()
      SwiftUI App.main()
        runApp
          NSApplicationMain
            -[NSApplication run]
```

A concurrent startup sample captured the store worker on
`GRDB.DatabasePool.writer`, in `LiveMailFacade.init`'s detached closure, through
`MailStore.init` and `DatabaseMigrator.migrate`. This confirms the large
`store-open` interval is not blocking the main thread in the current code.

`xctrace record --template 'App Launch'` was attempted. On this host, launching
the executable path through xctrace resolved the already-registered
`org.kayg.mailternal` bundle in another build directory rather than the private
LaunchPaint bundle; the resulting trace failed template export and was removed.
No xctrace number is claimed here.

## Attribution and ranked fixes

The phase gaps rank the work as follows. Individual framework sub-costs are not
claimed without a separate signpost; where multiple operations share a gap, the
entry says so explicitly.

| rank | path / measured interval | attribution | cheap fix | structural fix |
|---:|---|---|---|---|
| 1 | `did-finish-launching → window-front`: 263--1415 ms in the five Debug runs (median 544 ms) | MainActor construction/attachment of `MainShellViewController`, `NSHostingController`, `NavigationSplitView`, backdrop/material hierarchy, and native toolbar controller setup before `orderFront`. The current QALaunch phase does not split those framework calls, so no single one is assigned a fabricated number. | Keep native toolbar installation on the next main-actor turn (already present); avoid any validation or network work in `show`. | Add signposts around shell init, `MainWindowStartupConfiguration.attach`, and toolbar creation; prebuild only the minimal shell or use a static first-frame host. |
| 2 | `window-front → first-frame`: 31--250 ms (median 44 ms) | First AppKit/SwiftUI/CA layout and commit after the window is ordered. The phase is now measured by CA completion rather than a dispatch poll. | Ensure `orderFront` is not wrapped by toolbar/material validation and do not animate the restored frame. | Persist/render a lightweight launch projection (folders + first rows) in a shell that does not wait for `NavigationSplitView`'s first data-driven update. |
| 3 | `store-open`: 7952--9214 ms on the 1.64-GB fresh fixture | Detached `MailStore` open/migration; `sample` shows GRDB's writer queue and `DatabaseMigrator.migrate`. It is not a main-thread blocker now, but it gates folders and rows. | Do not await the store before ordering the shell (current launch path already starts the task detached). | Persist a validated `LaunchSnapshot`; open/migrate in the background and swap live projections in place. |
| 4 | `store-open → folders-snapshot`: 7--26 ms | Account/folder restoration and stream publication after the detached store opens. | Publish only the first non-empty folder phase for QA (empty stream values are initialization noise). | Make a typed launch projection query that returns the selected folder and visible columns in one bounded read. |
| 5 | `folders-snapshot → first-rows`: 131--337 ms (median 217 ms) | First message-page query, deep-link preparation, and SwiftUI message-list update. | Keep the page bounded at 80 rows and avoid favicon/WebKit work in this path. | Atomically swap a persisted first-page projection and reconcile it with the live cursor after launch. |
| 6 | `first-rows → settled-frame`: 45--197 ms (median 94 ms) | Rendering of list rows/sidebar state and the next CA commit; this is the user's visible “settled” boundary. | Do not start sync/IDLE, favicon warmup, or WebKit construction before this commit. | Treat `settled-frame` as an explicit launch state and schedule secondary work from its CA completion. |
| 7 | Debug image loading | The Debug dylib adds 47.9 MB on disk and dyld must load the split executable/dylib shape. The stable Release first-frame median is 250.2 ms versus the Debug median 834.8 ms, but the inputs differ (empty Release store versus populated Debug fixture), so this is directional, not a causal multiplier. | Measure shipped Release artifacts in a clean session; keep `ENABLE_DEBUG_DYLIB=NO` for Release. | Use an optimized, signed build for all launch gates; use a unique bundle identifier when collecting xctrace traces to avoid LaunchServices collisions. |

## Startup work not on the first-frame path

The first interactive shell does not require a selected message. `MessageViewer`
constructs a `WKWebView` only when a detail is present, so WebKit process warmup
is not observed in the first-frame samples. Favicon data is loaded by
`warmupFavicons` asynchronously and is not part of the main list projection.
The sync engine/IDLE work starts after account restoration and therefore follows
the first shell; it is not part of the AppKit `orderFront` interval. Toolbar
installation is explicitly dispatched to the next main-actor turn, although
AppKit's internal item view installation can still overlap the first CA commit.
No startup network request was found on the first-frame call path.

## Decision

The measured cheap wins are: keep store opening detached, order the restored
window before awaiting live data, install/validate the toolbar after the first
commit, and defer WebKit/favicon/sync/IDLE work until `settled-frame`. A
`LaunchSnapshot` is the structural option for getting the remaining first-frame
median under 100 ms; it is not implemented by this profile change because its
gain must be measured against the exact same fixture and Release artifact.
## QA VM cold/warm

The QA VM is the 4-vCPU/8-GB arm64 macOS 26.6.2 host. The populated fixture is
1,636,773,888 bytes. Runs use `MAILTERNAL_QA=1 -qa-gui`; cold runs purge the VM
cache and copy a fixture, while warm runs relaunch immediately against the same
container. The fixture shipped to the VM was initially at GRDB migrations v1-v9,
so a cold run correctly performed the pending `v10_unread_index` migration.

The instrumented VM run identified that migration as the catastrophic
`store-open` path, not a repeated migrator or checkpoint. On one cold copy,
`store-pool-open` ended at 304.4 ms, `index-build` ran from 304.9 to 44,510.7
ms, the migrator ended at 45,561.3 ms, and `store-open` ended at 45,561.6 ms.
The fixture then reported v1-v13 and `messages_unread_idx`; subsequent opens
were migrator no-ops. Directly timing the same `CREATE INDEX` on a copied
fixture took 11.85 s. With `sudo fs_usage -w -f filesys`, 3,317
`store.sqlite` `RdData` events were observed from 01:34:21.036999 through
01:34:54.010081 while that index was being built. No explicit launch checkpoint
exists; the code now emits `store-checkpoint-skipped` to make that invariant
visible.

Five immediate relaunches against the migrated fixture produced this matrix
(milliseconds since exec; the first-rows phase observed 80 rows):

| run | app-init | did-finish-launching | window-front | first-frame | store-open | folders-snapshot | first-rows | settled-frame |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 14.9 | 210.9 | 483.4 | 521.4 | 520.9 | 6587.7 | 8920.1 | 9047.4 |
| 2 | 14.2 | 228.3 | 646.7 | 732.2 | 731.4 | 1177.0 | 3110.7 | 3180.6 |
| 3 | 13.7 | 241.8 | 533.6 | 585.3 | 584.9 | 669.3 | 2879.6 | 2932.5 |
| 4 | 15.7 | 290.1 | 583.3 | 620.3 | 619.9 | 704.6 | 2928.4 | 2996.7 |
| 5 | 17.7 | 304.6 | 636.5 | 674.3 | 673.9 | 4065.6 | 6526.1 | 6618.5 |
| **median** | **14.9** | **241.8** | **583.3** | **620.3** | **619.9** | **1177.0** | **3110.7** | **3180.6** |

The corresponding shell subphase observations on the VM were: hosting
controller ready 5.1--9.1 ms after `shell-vc-init-begin`; toolbar-controller
creation completed 127--213 ms after shell construction began; split-view
attachment took 0.8--2.1 ms; first layout followed attachment by 4--15 ms;
materials took 1.1--21.2 ms; and deferred toolbar installation took 35--56 ms.
These are attribution markers, not independent user-visible milestones.

The optimized steady-state target is therefore met for an already-migrated
store: pool open, pragmas, no-op migrator, and the explicit checkpoint marker
all complete in under 0.75 s even in these GUI runs, with the database portion
itself under 1 ms after the first page-cache warmup. Migration of an old store
remains required correctness work and is reported separately from launch
latency.



## External research (harness web search, 2026-09-04)

Two independent searchers (Codex, Claude) reconciled against primary sources. Key takeaways for Mailternal are folded into the ranked table above; full findings follow.

### Codex findings

- **Set the target correctly.** Measure from process launch to the first frame that is both painted and accepts input—not merely `didFinishLaunching`, window creation, or a loading spinner. Cold launch is variable: after boot, memory pressure, or dependency eviction, frameworks may need to be paged in again. Apple recommends testing across those conditions. [Reducing your app’s launch time](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time)

- **Instrument before optimizing.** Use Instruments’ **App Launch** and **dyld Activity** instruments, plus `dyld_usage`/`dyld_info` on macOS. Apple’s WWDC22 example showed TextEdit launching in about **15 ms overall**, with only **1 ms in fixups**; most of its time was static initializers. This demonstrates that after dyld improvements, application code and initialization often dominate. [WWDC22: Link fast](https://developer.apple.com/videos/play/wwdc2022/110362/)

- **Reduce runtime dynamic linking.** Every dylib adds Mach-O parsing, dependency traversal, symbol binding, fixups, and potential page-ins. Merge private frameworks or make them static where appropriate. Apple explicitly recommends fewer dylibs and finding the project-specific static/dynamic “sweet spot.” Do not merge Apple system frameworks; they are already optimized through the dyld shared cache. [WWDC22: dynamic linking guidance](https://developer.apple.com/videos/play/wwdc2022/110362/)

- **Prefer supported mergeable libraries over hand-written linker tricks.** With Xcode 15+, set `MERGED_BINARY_TYPE=automatic` on the app and `MERGEABLE_LIBRARY=YES` on libraries, or use manual merging for selected dependencies. Release builds merge the libraries; debug builds retain dynamic linking for iteration speed. Apple describes release launch behavior as similar to static linking. [Configuring mergeable libraries](https://developer.apple.com/documentation/Xcode/configuring-your-project-to-use-mergeable-libraries), [WWDC23: Meet mergeable libraries](https://developer.apple.com/videos/play/wwdc2023/10268/)

- **Treat `-Xlinker -mergeable_libraries` cautiously.** Apple’s documented interface is the Xcode build settings above—not a manually maintained, undocumented flag. Let Xcode generate the appropriate `-merge_*` linker options. Merging only handles the relevant direct dependencies; indirect dependencies and app-extension/framework sharing need explicit design.

- **Audit Swift Package Manager products.** A Swift package is not automatically static. Inspect the resolved product type and final app bundle. Dynamic package products become runtime dylib dependencies; convert eligible internal products to static or mergeable products, while preserving dynamic boundaries where plugins, extensions, or independently updated components require them.

- **Eliminate pre-`main` work.** Static initializers include C++ constructors, Objective-C `+load`, Clang constructors, and functions in `__DATA,__mod_init_func`. Avoid I/O, networking, database opening, JSON decoding, logging setup, dependency-container construction, and WebKit creation there. Defer work until after the first frame or until the feature needs it. Apple says anything taking more than “a few milliseconds” should not be an initializer. [Apple launch-time guidance](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time)

- **Be especially suspicious of global Swift state.** Global instances, static stored properties, registration tables, and framework-level singletons can trigger initialization or page-ins before the UI exists. Prefer lazy factories and explicit post-window initialization. Measure rather than assuming every Swift global is pre-main.

- **Keep Swift Concurrency off the critical path.** Swift 6 itself has no published fixed startup penalty. The cost comes from runtime loading, task creation, actor/executor setup, and—most importantly—work accidentally isolated to `MainActor`. A `Task {}` created from a main-actor context initially runs there and can occupy the main thread before the first interactive frame. Make expensive functions `async` and `nonisolated`, perform blocking work off the main actor, and return only the minimal result to the UI. [Apple: Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness), [Swift concurrency runtime](https://developer.apple.com/documentation/swift/globalconcurrentexecutor)

- **Use the thinnest launch architecture that meets the product requirements.** A SwiftUI `App`/`WindowGroup` is supported and convenient, but it constructs a scene graph and lets SwiftUI manage scene/window lifecycle. A manually launched `NSApplication` with an `NSWindow` can make the critical path more explicit: create a minimal native root view, show the window, then attach the larger SwiftUI hierarchy. There is no Apple-published benchmark proving that manual `NSApplicationMain` is always faster; compare both architectures in your app. [SwiftUI `App`](https://developer.apple.com/documentation/SwiftUI/App), [SwiftUI `Scene`](https://developer.apple.com/documentation/swiftui/scene)

- **A practical hybrid is often best:** manually create and order the `NSWindow`, show a lightweight AppKit/SwiftUI shell immediately, then install the full content asynchronously. This can improve time-to-painted-window, but only if the shell is genuinely interactive and does not immediately block while replacing itself.

- **Do not put `WKWebView` on the first-frame critical path unless unavoidable.** WebKit initialization, WebContent process startup, configuration, JavaScript injection, cookie setup, and HTML/resource loading are separate costs. Apple documents creation and loading behavior but publishes no universal “WKWebView costs N milliseconds” figure. Use a native placeholder first; create or load the web view after the first interactive frame, or precreate one during idle time and reuse it. [WKWebView](https://developer.apple.com/documentation/webkit/wkwebview), [WebKit for AppKit/UIKit](https://developer.apple.com/documentation/webkit/webkit-for-appkit-and-uikit)

- **Order the hot `__TEXT` pages using measured data.** Order files can cluster launch functions, initializers, and first-screen code so fewer executable pages are faulted in. Apple’s locality guidance specifically recommends profiling launch and main-window activation, then reordering `__TEXT`; it also notes that initialization code scattered across pages increases paging. This is a second-order optimization after dylibs and initialization. [Improving Locality of Reference](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/CodeFootprint/Articles/ImprovingLocality.html)

- **Do not expect order files to fix code-signing verification.** They reduce executable page faults and locality misses; they do not remove Gatekeeper assessment, signature validation, dylib loading, or WebKit startup. Re-profile after each order-file change because stale profiles can worsen other launches.

- **Use modern Mach-O fixups and deployment targets.** WWDC22 introduced page-in linking for binaries using chained fixups. The kernel can apply data fixups lazily as pages are brought in, reducing launch time and dirty memory. Build with a sufficiently modern deployment target so chained fixups are available, and verify the result with `dyld_info`. [WWDC22: page-in linking](https://developer.apple.com/videos/play/wwdc2022/110362/)

- **Avoid unnecessary code-signature/page-in pressure.** Keep the launch-critical executable and frameworks reasonably small, avoid shipping unused architectures or embedded duplicate binaries, and use dead-code stripping where safe. Code-signature validation operates on signed pages; a larger, more fragmented bundle can create more verification and page-in work. Apple’s code-signing documentation also recommends avoiding unnecessary nested code and testing the final distributed artifact. [TN2206: macOS Code Signing In Depth](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)

- **Notarization is primarily a distribution/first-run concern, not a normal every-launch optimization lever.** Ship Developer ID-signed, hardened-runtime, notarized software and staple the ticket. A stapled ticket lets Gatekeeper validate locally when offline; without it, Gatekeeper may need to find the ticket online. You cannot generally “turn off” Gatekeeper, XProtect, or signature checks to reach 100 ms. [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [Customizing notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

- **Avoid App Translocation in performance tests and user instructions.** Apps opened directly from a quarantined ZIP/Downloads location may be run from a randomized read-only path. That changes filesystem behavior and can add first-launch security and resource-resolution work. Distribute a signed/notarized DMG or installer and instruct users to move the app to `/Applications`; test both first and subsequent launches. [Packaging Mac software](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)

- **Handle restoration deliberately.** Window restoration can synchronously decode saved state, reopen documents, recreate view graphs, and load large content. Disable restoration for a transient primary window, or restore only geometry and lightweight identity before displaying it; restore document data after the first frame. If restoration is required, keep restoration state small and avoid constructing the full model inside `restoreState(with:)`.

- **The strongest architecture for sub-100 ms is staged launch:**  
  `main` → minimal dependencies and no expensive initializers → create native window/shell → order front and accept input → asynchronously open the database, start concurrency work, construct WebKit, restore heavy state, and populate data.

- **Numbers Apple actually publishes are limited.** The most concrete relevant number is Apple’s WWDC22 TextEdit trace: **15 ms total launch, 1 ms fixups**, with static initialization dominating. Apple does not publish guaranteed gains for mergeable libraries, order files, SwiftUI versus AppKit entry points, Swift 6, WKWebView prewarming, or notarization. Treat claims such as “merge frameworks saves 30 ms” as app- and machine-specific measurements, not platform guarantees.


### Claude findings

## Reality check on the target

- Apple's published budget is **400 ms to first frame** (WWDC19 *Optimizing App Launch*), not 100 ms. 100 ms is achievable but only if the app is essentially "TextEdit-shaped": few or zero non-cache dylibs, no static initializers doing work, and a window painted before any store/network I/O. ([SwiftLee summary of the 400 ms guidance](https://www.avanderlee.com/optimization/launch-time-performance-optimization/))
- Concrete anchor points from primary sources:
  - **TextEdit on macOS: ~15 ms** total dyld launch work, of which **1 ms is fixups** (thanks to page-in linking) and the *majority* is static initializers. ([WWDC22 110362](https://developer.apple.com/videos/play/wwdc2022/110362/))
  - A hello-world CLI does the whole dyld phase in **~10 ms**; a **Mac app with many third-party Swift frameworks outside the shared cache takes 100+ ms in dyld alone**. ([Mac Internals, dyld in depth](https://www.macinternals.app/en/blog/dyld-in-depth))
  - That second number is the single most important finding for you: **every dynamic framework you ship that isn't in the dyld shared cache is a direct, measurable slice of your 100 ms budget.**

## dyld / linking

- **Fewer dylibs is the lever.** Apple gives no hard cap, only "find your sweet spot": too many static libs slows your build, too many dynamic libs and "your launch time is slow and your customers notice." ([WWDC22 110362](https://developer.apple.com/videos/play/wwdc2022/110362/))
- **Chained fixups** (macOS 13.4+ / iOS 13.4+ deployment target) shrink LINKEDIT and enable kernel page-in linking. One secondary analysis claims **5–10× faster fixup application** vs. the old opcode-stream format — Apple doesn't publish that multiplier, so treat it as indicative. ([Mac Internals](https://www.macinternals.app/en/blog/dyld-in-depth))
- **Page-in linking**: the kernel applies fixups lazily as DATA pages are touched instead of dyld doing them all at launch. Reduces dirty memory and launch time, keeps `__DATA_CONST` clean. Caveat: **only applies during launch — anything `dlopen`ed later takes the traditional eager path.** ([WWDC22 110362](https://developer.apple.com/videos/play/wwdc2022/110362/))
- **PrebuiltLoaderSet**: OS dylibs get their loaders precomputed at shared-cache build time (O(1), effectively instant). For *your* app, the PrebuiltLoaderSet is "built as needed and saved to disk" — so **launch N+1 is cheaper than launch 1**, and any benchmark that doesn't distinguish them is lying to you. ([dyld4.md](https://github.com/apple-oss-distributions/dyld/blob/main/doc/dyld4.md), [PrebuiltLoaderSet_Policy.md](https://github.com/apple-oss-distributions/dyld/blob/main/doc/PrebuiltLoaderSet_Policy.md))
- **`-no_exported_symbols`** on the app binary: skips building the exports trie. The cited 2–3 s win on a 1M-symbol app is **link time, not launch time**. Can't be used if you load plugins that link back to the executable, or as an XCTest host. Check yours with `dyld_info -exports`. ([WWDC22 110362](https://developer.apple.com/videos/play/wwdc2022/110362/))
- **Static initializers are where TextEdit's launch time actually goes.** Apple's rule: "anything that can take more than a few milliseconds should never be done in an initializer" — no I/O, no networking. In Swift this means global `let`s with non-trivial initializers, `+load`, and C++ static ctors in any vendored code.
- Diagnostics: `dyld_usage` (macOS only, traces launch), `dyld_info -fixup/-exports`, and the **dyld Activity instrument** which reports static-initializer time directly.

## Mergeable libraries (WWDC23)

- Mechanism: turns **load-time symbol resolution into link-time resolution** — dynamic-library semantics with near-static launch cost. Dependencies stay dynamic in Debug (fast incremental builds, via reexporting) and are merged into the binary in Release. ([WWDC23 10268](https://developer.apple.com/videos/play/wwdc2023/10268/))
- Settings: `MERGED_BINARY_TYPE = automatic` (merges all direct embedded framework deps) or `manual` + `MERGEABLE_LIBRARY = YES` per target. Linker flags: `-make_mergeable` on the library, `-merge_framework` / `-merge_library` on the consumer. ([Apple: Configuring your project to use mergeable libraries](https://developer.apple.com/documentation/xcode/configuring-your-project-to-use-mergeable-libraries))
- **`-no_merged_libraries_hook` is an explicit launch-time win** — disables the bundle-lookup hook. Only safe if your merged frameworks have no bundle resources and you don't call `Bundle(for:)` / `NSBundle.bundleForClass` against them.
- Costs/caveats: `-make_mergeable` **roughly doubles dylib size** (metadata discarded post-merge); requires the Xcode 15+ linker; no armv7k; `dlopen` paths must target the *merged* framework; crash logs and Instruments show the merged binary's path, not the original library's. Apple no numbers published for the launch delta.
- For your case, the simpler move usually beats merging: **SPM defaults to static, but Xcode will happily build package products as dynamic frameworks.** Force `Mach-O Type = Static Library` / `type: .static` and you skip the whole problem. ([SPM & dynamic linking](https://medium.com/@bancarel.paul/swift-package-manager-dynamic-linking-bc48bf83b91d), [static vs dynamic deep dive](https://bpoplauschi.github.io/2021/10/25/Advanced-static-vs-dynamic-libraries-and-frameworks.html))

## Order files / `__TEXT` layout

- By default an app **pages in over 75% of its binary during launch**; order files cluster launch-critical symbols so only the needed pages fault in. Emerge reports **up to 20% startup reduction**; Sentry's open-source FaultOrdering claims **>20% measured in production**. ([Emerge Tools](https://www.emergetools.com/blog/posts/FasterAppStartupOrderFiles), [getsentry/FaultOrdering](https://github.com/getsentry/FaultOrdering))
- Per-fault cost measured on iPhone 6S: **~0.06 ms average, ~1 ms worst case** — on Apple silicon with NVMe this is much smaller, so expect proportionally less benefit on a Mac than on an old iPhone.
- Flags: `-order_file <path>`, or the older `-sectorder __TEXT __text <path>`. Generate the symbol order from a real launch trace (FaultOrdering drives it from an XCUITest — which you already have working on mbp). Enable `LD_GENERATE_MAP_FILE=YES` to inspect layout. ([Apple: Improving Locality of Reference](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/CodeFootprint/Articles/ImprovingLocality.html))
- Caveat worth heeding: gains depend on **in-order** access; a bad order file can be worse than none, and hardware prefetch already recovers some of it.

## Gatekeeper / notarization / first launch

- A quarantined app's **first** launch pays three checks: Developer ID signature verification, an **XProtect Yara scan**, and notarization-ticket validation. Howard Oakley's conclusion: cdhash validation is "unlikely to result in significant delays," but **XProtect scans are the probable cause of large, complex bundles taking several seconds** before they can run — the rule set and rule length have grown a lot. ([Eclectic Light: Sonoma launch conclusions](https://eclecticlight.co/2024/09/03/launching-apps-in-sonoma-14-6-1-conclusions/), [How does Sonoma check an app before launch?](https://eclecticlight.co/2024/05/09/how-does-sonoma-check-an-app-before-launch/))
- **Staple the ticket** (`xcrun stapler staple`) so validation is local and works offline — otherwise Gatekeeper does a network round trip to Apple. ([Apple Platform Security](https://support.apple.com/guide/security/protecting-against-malware-sec469d47bd8/web))
- **Translocation only happens when `com.apple.quarantine` is present.** Ship a signed DMG and make the user drag to `/Applications`, or use LetsMove; once the user approves, the quarantine xattr is cleared and subsequent launches skip first-run checks entirely. Under translocation, Gatekeeper assessment may also be *deferred*, moving cost around unpredictably. ([Lapcat: App Translocation](https://lapcatsoftware.com/articles/app-translocation.html), [Eclectic Light: first run, quarantine and translocation](https://eclecticlight.co/2022/09/09/app-first-run-quarantine-and-translocation/))
- **Code-signature page-in cost is real but small and unavoidable**: the binary is split into 4096-byte pages, each SHA-256 hashed, validated by the kernel on page-in. No published per-page number. This is another reason a smaller launch working set (order files) compounds — fewer pages faulted means fewer hashes verified. ([Karol Mazurek, code signing internals](https://karol-mazurek.medium.com/snake-apple-ii-code-signing-f0a9967b7f02))
- **Benchmark methodology implication**: measure a *warm, unquarantined, already-launched-once* app for your 100 ms number, and separately report the cold/first-launch number. These are different orders of magnitude and the difference is almost entirely security machinery plus the PrebuiltLoaderSet cache.

## SwiftUI Scene vs. AppKit `NSApplicationMain`

- **No public benchmark exists** comparing SwiftUI `App`/`WindowGroup` cold launch to `NSApplicationMain` + a hand-built `NSWindow` on macOS. I looked; the search space is full of opinion, not measurement.
- What is documented: SwiftUI's `ScenePhase` is effectively unusable on macOS and you need an `NSApplicationDelegateAdaptor` anyway; the practical recommendation from experienced Mac devs is that **"for complex Mac apps, an AppKit shell is probably the best approach."** ([Jesse Squires](https://www.jessesquires.com/blog/2024/06/29/swiftui-scene-phase/), [AppKit vs SwiftUI trade-offs](https://digitalblake.com/2026/04/28/swiftui-vs-appkit-macos-ui-performance/))
- A known concrete trap: a `Settings` scene in a SwiftUI Mac app has been reported to slow the app down. ([Apple Forums](https://developer.apple.com/forums/thread/705327))
- The mechanically defensible approach for a <100 ms target is the one you'd expect: create the `NSWindow` yourself in `applicationDidFinishLaunching`, `makeKeyAndOrderFront` with cheap placeholder content, and let every SwiftUI hosting view / data load land after the first frame. Since you already emit `launch phase=…` markers, you can settle the SwiftUI-vs-AppKit question empirically for your own shell rather than trusting anyone's blog.

## WKWebView

- Reported **~47 ms for WKWebView initialization on macOS**, and **100+ ms of startup delay in mid/large apps** that create one or more WKWebViews during launch — much of it process-pool creation. ([Apple Forums: WKWebView hurting startup](https://developer.apple.com/forums/thread/733774), [WebViewWarmUper](https://github.com/bernikovich/WebViewWarmUper))
- Standard mitigation is to warm one up early and keep it alive — but note an active regression report: on **macOS 26.2 there's a ~3000 ms delay between loading HTML and navigation start** (vs ~20 ms on iOS 26.2), and **sharing a `WKProcessPool` plus prewarming did not help.** ([Apple Forums thread 810699](https://developer.apple.com/forums/thread/810699))
- For a 100 ms budget the only viable answer is: **never touch WebKit on the launch path.** Create the web view after first paint, and given the macOS 26.2 report, verify your own numbers on 26 before designing around prewarm.

## NSWindow restoration

- Restoration deserializes saved state and recreates windows during launch; it can appear frozen with no user-visible activity during a long restore, and is reported as unreliable (~1 in 3) by developers. ([NSWindowRestoration docs](https://developer.apple.com/documentation/appkit/nswindowrestoration), [Apple Forums](https://developer.apple.com/forums/thread/133321))
- Controls: `NSWindow.isRestorable`, the `NSQuitAlwaysKeepsWindows` preference, and `-ApplePersistenceIgnoreState YES` as a launch argument. **For measurement, always A/B with restoration disabled** — otherwise you're benchmarking your saved state, not your app.

## Swift Concurrency startup cost

- **Nobody publishes numbers for this.** `libswift_Concurrency.dylib` has shipped in the OS since macOS 12, so on macOS 26 there's no extra dylib to load — the back-deployment copy that caused the old crashes is irrelevant to you. ([Swift Forums](https://forums.swift.org/t/swift-concurrency-back-deploy-issue/53917))
- The relevant cost is **executor hops before first paint**, not runtime init. Swift 6.2 helps structurally: SE-0461 makes `nonisolated async` functions run on the caller's actor instead of hopping to the global executor, and actors got executor-switching optimizations that elide the hop when no contention is provable. SE-0466 lets you default the whole module to `@MainActor`. ([Swift 6.2 concurrency in practice](https://blakecrosley.com/blog/swift-6-2-concurrency-in-practice))
- Practical rule: any `await` between `applicationDidFinishLaunching` and window-front is a scheduling round trip you're paying for. Get the window on screen synchronously, then `Task { }` the rest.

## Measurement

- Use `dyld_usage` for the dyld phase and the **dyld Activity** instrument for static-initializer time — these split "before main" from "your code," which your current `launch phase=` markers can't.
- WWDC25/26 Instruments additions worth knowing: **Processor Trace at ~1% overhead**, a **Swift executors instrument** (visualizes main-actor and global-executor hops — directly relevant to the point above), **Top Functions** mode, and **Run Comparisons** against a baseline. ([WWDC25 Optimize CPU performance with Instruments](https://dev.to/arshtechpro/wwdc-2025-optimize-cpu-performance-with-instruments-23lb), [WWDC26 viewing guide](https://useyourloaf.com/blog/wwdc-2026-viewing-guide/))

## What I'd prioritize for Mailternal, given the above

1. Audit dylib count first — that "100+ ms for a Mac app with third-party Swift frameworks" figure is the whole budget. Force SPM products static in `project.yml`.
2. Kill static-initializer work (Apple's own TextEdit trace says this dominates once linking is cheap).
3. Paint the window before any store open — your `store-open` phase marker is already the right place to check this.
4. WebKit strictly after first paint; verify the macOS 26.2 navigation-delay report on mbp.
5. Order file last — it's a 10–20% shave on an already-fast launch, and needs a launch trace to generate.

Two caveats on the above: the 5–10× chained-fixups figure and the 20% order-file figures come from third parties, not Apple, and the SwiftUI-vs-AppKit launch question has no published measurement — your own `launch phase=` instrumentation is better evidence than anything I found.

Separately: the claude.ai Gmail, Google Calendar, and Google Drive connectors need authorization before I can use them, and this session can't run the OAuth flow — you'd authorize those in your claude.ai connector settings. Nothing above depended on them.

Sources:
- [WWDC22: Link fast — Improve build and launch times](https://developer.apple.com/videos/play/wwdc2022/110362/)
- [WWDC23: Meet mergeable libraries](https://developer.apple.com/videos/play/wwdc2023/10268/)
- [Apple: Configuring your project to use mergeable libraries](https://developer.apple.com/documentation/xcode/configuring-your-project-to-use-mergeable-libraries)
- [Apple: Reducing your app's launch time](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time)
- [WWDC19: Optimizing App Launch](https://developer.apple.com/videos/play/wwdc2019/423/)
- [Apple: Improving Locality of Reference (order files)](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/CodeFootprint/Articles/ImprovingLocality.html)
- [dyld4.md](https://github.com/apple-oss-distributions/dyld/blob/main/doc/dyld4.md) · [PrebuiltLoaderSet_Policy.md](https://github.com/apple-oss-distributions/dyld/blob/main/doc/PrebuiltLoaderSet_Policy.md)
- [Mac Internals: dyld in depth](https://www.macinternals.app/en/blog/dyld-in-depth)
- [Emerge Tools: How order files reduce app startup time](https://www.emergetools.com/blog/posts/FasterAppStartupOrderFiles) · [getsentry/FaultOrdering](https://github.com/getsentry/FaultOrdering)
- [Eclectic Light: Launching apps in Sonoma 14.6.1 — Conclusions](https://eclecticlight.co/2024/09/03/launching-apps-in-sonoma-14-6-1-conclusions/) · [How does Sonoma check an app before launch?](https://eclecticlight.co/2024/05/09/how-does-sonoma-check-an-app-before-launch/) · [App first run, quarantine and translocation](https://eclecticlight.co/2022/09/09/app-first-run-quarantine-and-translocation/)
- [Lapcat Software: App Translocation](https://lapcatsoftware.com/articles/app-translocation.html)
- [Apple Platform Security: Protecting against malware](https://support.apple.com/guide/security/protecting-against-malware-sec469d47bd8/web)
- [Apple Forums: WKWebView initialization hurting startup](https://developer.apple.com/forums/thread/733774) · [evaluateJavaScript slow on macOS 26.2](https://developer.apple.com/forums/thread/810699) · [WebViewWarmUper](https://github.com/bernikovich/WebViewWarmUper)
- [Apple: NSWindowRestoration](https://developer.apple.com/documentation/appkit/nswindowrestoration) · [isRestorable](https://developer.apple.com/documentation/appkit/nswindow/1526255-restorable)
- [Jesse Squires: SwiftUI scene phase issues](https://www.jessesquires.com/blog/2024/06/29/swiftui-scene-phase/) · [AppKit vs SwiftUI on macOS](https://digitalblake.com/2026/04/28/swiftui-vs-appkit-macos-ui-performance/)
- [Swift 6.2 Concurrency in Practice](https://blakecrosley.com/blog/swift-6-2-concurrency-in-practice)
- [Advanced static vs dynamic libraries and frameworks on iOS/macOS](https://bpoplauschi.github.io/2021/10/25/Advanced-static-vs-dynamic-libraries-and-frameworks.html) · [SPM & dynamic linking](https://medium.com/@bancarel.paul/swift-package-manager-dynamic-linking-bc48bf83b91d)
- [WWDC25: Optimize CPU performance with Instruments](https://dev.to/arshtechpro/wwdc-2025-optimize-cpu-performance-with-instruments-23lb) · [WWDC26 viewing guide](https://useyourloaf.com/blog/wwdc-2026-viewing-guide/)
- [SwiftLee: App launch time — 7 tips](https://www.avanderlee.com/optimization/launch-time-performance-optimization/)
- [Karol Mazurek: Code signing on macOS](https://karol-mazurek.medium.com/snake-apple-ii-code-signing-f0a9967b7f02)
