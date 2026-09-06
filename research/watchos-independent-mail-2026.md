# Independent watchOS mail feasibility

**Snapshot:** 2026-09-05. The target is a watch-only or independent watchOS 27 app. “Fact” means directly documented by Apple or by the named upstream source. “Inference” is an engineering conclusion from those facts. “Prototype” means a real-device validation is still required; the watchOS simulator is not evidence for low-level networking.

## Bottom line

| Capability | Phone-free watch-only result | Decision / boundary |
|---|---|---|
| Read mail | **No for the current direct-generic-IMAP design.** watchOS blocks low-level TCP connections for normal apps, and IMAP is a TCP/TLS protocol. **Conditional yes** only with a new HTTPS/JMAP/provider API or a mailbox relay that the watch can reach through high-level networking. | Do not claim direct IMAP viability from URLSession or media streaming. A relay/API is a product and trust-model change, not an adapter-only change. |
| Triage (read/unread, flag, archive, move) | **Local optimistic triage: yes. Server reconciliation: conditional** on a high-level HTTPS API/relay and bounded background/foreground requests. | Reuse the durable mutation model, but define an HTTPS command/delta protocol and conflict semantics. No phone-dependent fallback may be silently substituted. |
| Search | **Yes for locally retained text**, subject to a small, disclosed retention window. | GRDB/SQLite FTS5 is a plausible portable core; redesign storage and indexing budgets for Watch. |
| Account setup/authentication | **Yes in principle, phone-free.** Apple requires independent apps to let users create/sign in directly on Watch; custom forms, Sign in with Apple, and web authentication are documented options. | New Watch UI and credential adapter. A provider-specific OAuth/app-password flow still needs a prototype on the small screen. |
| Notifications | **Yes for direct APNs delivery to the Watch**, with user-facing authorization and/or silent delivery behavior. Notifications are wake/signals, not an IMAP transport. | Register the Watch token directly. Do not put mail content or a promise of immediate sync in a push; use a high-level fetch when permitted. |
| Attachments | **On-demand only, conditional.** A high-level HTTPS endpoint can return an attachment download; direct IMAP `BODY.PEEK` cannot run from an ordinary Watch app. | Keep attachment metadata local; add a resumable/bounded HTTP fetch path and a much smaller Watch cache cap. |
| Compose | Not currently desired. | No research or design investment required now. |

The meaningful feasibility split is therefore **direct IMAP versus phone-free HTTPS/API mail**. The former is blocked by an Apple platform restriction; the latter is feasible enough to prototype, but requires a server-side protocol and mailbox authority that are not present in the current app/spec.
### The gateway tradeoff against the existing daemon

The current push design deliberately keeps the daemon on an IDLE/metadata-only boundary: `mailternald` holds IMAP authorization but never `FETCH`es or stores message content; APNs carries only an opaque wake; and the iOS NSE fetches the delta directly from IMAP. ([Push Architecture Spec](../docs/spec/push.md), [iOS IMAP/relay/APNs evidence memo](ios-imap-relay-apns-2026.md))

That boundary cannot serve a phone-free Watch reader as written. TN3135 prevents the Watch from doing the direct IMAP fetch after the wake, so a Watch-readable HTTPS endpoint must have a content-capable fetcher somewhere:

| HTTPS mail source | What changes | Trust consequence |
|---|---|---|
| Provider API directly from Watch (JMAP/Gmail/Graph where supported) | Watch stores an OAuth/provider credential and speaks HTTPS; provider-specific delta, mutation, and attachment APIs are new adapters. Keep the existing no-mail-content APNs gateway. | No new generic-IMAP daemon authority, but coverage is provider-specific and provider tokens live on Watch. |
| User-owned `mailternald` HTTPS API | Daemon must `FETCH`/decode enough content to answer Watch reads and accept queued triage; it may stream without durable body storage, but it still sees plaintext. | Expands a compromised daemon from metadata/event access to mailbox-read authority. E2E encryption to Watch can keep an intermediary gateway blind, but cannot make the daemon blind to content it fetched. |
| Vendor-hosted generic-IMAP gateway | Service holds reusable mailbox authorization and performs content fetches, deltas, mutations, and attachment serving. | Directly conflicts with the current no-credentials/no-mail-content gateway posture and creates a materially larger central breach/revocation/privacy surface. |

**Product decision:** “Phone-free Watch mail via HTTPS” is not a transport swap that preserves the current daemon trust model. Main must get explicit approval for the new content-fetch authority (and its retention, encryption, revocation, and deletion rules). If that approval is absent, retain the current no-content push design and limit Watch to locally cached data plus opportunistic phone/desktop synchronization; do not label that direct independent IMAP.


## Established Apple restrictions

### Independent installation and phone-free setup

Apple documents two independent forms: a Watch-only app with no related iPhone app, or a watchOS app that can be installed without its iOS companion. Users can purchase Watch apps directly from the Watch App Store. The independent-app guide says the system installs the watchOS app directly on the Watch and, for a watch-only app, the Xcode iOS wrapper is only a packaging/bundle-identity stub; no iOS executable is installed on the phone. ([Creating independent watchOS apps](https://developer.apple.com/documentation/watchos-apps/creating-independent-watchos-apps))

For a companion project, `WKRunsIndependentlyOfCompanionApp` is the Boolean plist key that lets users install the iOS app, watchOS app, or both; it has been available since watchOS 6. ([WKRunsIndependentlyOfCompanionApp](https://developer.apple.com/documentation/bundleresources/information-property-list/wkrunsindependentlyofcompanionapp))

Apple is explicit that independent apps must work without the phone: users must be able to create an account and sign in directly on Watch. The documented choices are no account/CloudKit, Sign in with Apple, or custom sign-in/sign-up forms. Text fields, secure fields, password autofill content types, and one-time-code autofill are available in the documented Watch authentication flow. `ASWebAuthenticationSession` is available on watchOS 6.2 and returns an authentication callback token, making provider OAuth a possible setup route, but the provider flow and callback UX still need a device prototype. ([Authenticating users on Apple Watch](https://developer.apple.com/documentation/watchos-apps/authenticating-users-on-apple-watch), [ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession))

### Keychain and credentials

Security keychain attributes needed for a private password item are available on watchOS: `kSecAttrAccessible` is watchOS 2+, and `kSecAttrSynchronizable` is watchOS 2+. A normal app always has a private default access group; sharing with another app requires a signed common keychain-access-group entitlement. Synchronizable passwords/certificates/keys synchronize on watchOS 7+, but synchronization is not a reason to make Watch setup phone-dependent, and `ThisDeviceOnly` accessibility values cannot synchronize. ([kSecAttrAccessible](https://developer.apple.com/documentation/security/ksecattraccessible), [kSecAttrSynchronizable](https://developer.apple.com/documentation/security/ksecattrsynchronizable), [Sharing access to keychain items](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps))

**Engineering inference:** store a Watch-entered provider credential or OAuth refresh credential in the Watch app’s own Keychain access group first. Treat iCloud Keychain or a paired-device handoff as an optional optimization, not the account’s only source. The existing `KeychainStore` is inside the macOS-only `MailternalLive` target, so a Watch target needs a new platform adapter and entitlement/configuration review.

### Direct network route: Wi-Fi/cellular is not permission to use IMAP

Apple documents that Watch URL-session requests may route through the paired iPhone, a known Wi-Fi network, or the Watch’s own cellular connection. A paired phone is therefore a possible transport route, not a required dependency. Independent apps must not rely on Watch Connectivity as their primary data source. ([Keeping your watchOS app’s content up to date](https://developer.apple.com/documentation/watchos-apps/keeping-your-watchos-app-s-content-up-to-date), [Creating independent watchOS apps](https://developer.apple.com/documentation/watchos-apps/creating-independent-watchos-apps))

The decisive current restriction is [TN3135: Low-level networking on watchOS](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos):

* High-level networking is HTTP/HTTPS through `URLSession`.
* Low-level networking includes Network framework, Foundation streams, any API that directly runs TCP/UDP, and URLSession stream/WebSocket tasks.
* Low-level networking is allowed only while an audio-streaming app is actively streaming audio, while a VoIP app is running a CallKit call, or for the documented DeviceDiscoveryUI listener case.
* A normal app starting `NWConnection` remains in `.waiting` with `ENETDOWN`; `NWPathMonitor` remains unsatisfied.
* **BSD sockets do not work on watchOS under any circumstances.**
* watchOS 6–8 had a bug where low-level networking might work outside the allowed cases; Apple says watchOS 9 fixed enforcement. Current watchOS 27 devices are well past that historical bug.
* The simulator always allows low-level networking, so only a real Watch test is meaningful.

The Network framework itself is available on watchOS 6 and exposes TCP/TLS protocol objects (`NWProtocolTCP`, `NWProtocolTLS`) and `NWConnection`. Apple’s availability and API surface do not override TN3135’s runtime policy. ([Network](https://developer.apple.com/documentation/network), [NWConnection](https://developer.apple.com/documentation/network/nwconnection), [NWProtocolTCP](https://developer.apple.com/documentation/network/nwprotocoltcp), [NWProtocolTLS](https://developer.apple.com/documentation/network/nwprotocoltls))

IMAP IDLE is specifically a server-to-client command that keeps a selected-mailbox connection open for unsolicited updates; it needs the very low-level TCP/TLS connection that TN3135 denies to an ordinary app. ([RFC 9051 §6.3.13](https://www.rfc-editor.org/rfc/rfc9051.html#section-6.3.13)) `URLSession` is not an IMAP escape hatch: its native URL schemes are data/file/ftp/http/https and its WebSocket tasks are themselves classified as low-level by TN3135. ([URLSession](https://developer.apple.com/documentation/foundation/urlsession), [TN3135](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos))

**Conclusion:** neither `NWConnection` nor SwiftNIO’s BSD-socket transport can make direct generic IMAP legal on a normal Watch app. There is no documented “mail” exception, and the audio exception must not be generalized.

### Foreground, background, push, and IDLE

watchOS has active/inactive/background/suspended/not-running states. The system gives ordinary background tasks only a few seconds; it can defer, throttle, or terminate them. `WKApplicationRefreshBackgroundTask` is budgeted (Apple’s current reference says approximately four tasks per hour for an app with a complication on the active face, with system delays after the budget is exhausted), and scheduling is not a guarantee. ([Life cycles](https://developer.apple.com/documentation/watchkit/life-cycles), [Background execution](https://developer.apple.com/documentation/watchkit/background-execution), [WKApplicationRefreshBackgroundTask](https://developer.apple.com/documentation/watchkit/wkapplicationrefreshbackgroundtask), [Using background tasks](https://developer.apple.com/documentation/watchkit/using-background-tasks))

For foreground, default/ephemeral URL sessions are intended for the short interactive period and must be canceled/replaced when the app backgrounds. Background URL sessions persist across app closure/termination and eventually deliver download responses, but delivery may be deferred based on system state, connectivity, and resources; smaller transfers are better. ([Making default and ephemeral requests](https://developer.apple.com/documentation/watchos-apps/making-default-and-ephemeral-requests), [Making background requests](https://developer.apple.com/documentation/watchos-apps/making-background-requests))

An independent Watch app can register directly with APNs; Apple says device tokens may change and the app should register on every launch. Without notification authorization, remote notifications are delivered silently; authorization is required for alerts/sounds/user-facing actions. ([Register for remote notifications](https://developer.apple.com/documentation/watchkit/wkextension/registerforremotenotifications()), [WatchOS notifications](https://developer.apple.com/documentation/watchos-apps/notifications))

**Inference for mail:** APNs can wake/signal a Watch app, and a short high-level HTTPS request can update a small local view, but APNs cannot provide an always-on mailbox stream. Continuous IMAP IDLE is unavailable; refresh is best-effort and must have a foreground/open fallback. A push payload should remain an opaque hint or generic alert, consistent with the existing push spec’s no-mail-content posture. The current iOS Notification Service Extension design fetches IMAP directly and therefore cannot be copied to Watch.

### Storage, SQLite/FTS, rendering, and attachments

GRDB’s current SwiftPM manifest declares watchOS 7 as a supported platform and enables SQLite FTS5 in its package settings. SwiftSoup’s package manifest declares watchOS 6. ([GRDB Package.swift](https://raw.githubusercontent.com/groue/GRDB.swift/master/Package.swift), [SwiftSoup Package.swift](https://raw.githubusercontent.com/scinfu/SwiftSoup/master/Package.swift)) The repository’s core MIME parser is Foundation-only and the store is GRDB/SQLite with WAL, bounded write transactions, and FTS5. That is a strong reuse candidate, subject to a Watch build and memory/latency prototype.

There is no Apple-published Watch-specific SQLite file-size quota in the sources reviewed. SQLite itself documents large implementation limits rather than a small Watch cap. The real constraints are shared device storage and app policy: Apple says caches are automatically purgeable under storage pressure, while other app data remains the app’s responsibility; Apple App Store Connect limits the uncompressed watchOS app bundle to 75 MB. ([Monitoring your app’s storage metrics](https://developer.apple.com/documentation/xcode/monitoring-your-app-s-storage-metrics), [Maximum build file sizes](https://developer.apple.com/help/app-store-connect/reference/app-uploads/maximum-build-file-sizes/), [SQLite limits](https://sqlite.org/limits.html))

The current repository default attachment-cache cap is **2 GiB**, with hashed files under a cache directory; current sync policy fetches attachments only on demand and stores text/HTML history locally. Those policies are reasonable for macOS but not a Watch budget. A Watch design needs an explicit small cap, page/message retention policy, cancellation-safe downloads, and behavior when the system purges cache files. Do not infer that a 2 GiB cap is usable merely because SQLite has a large theoretical limit.

`WKWebView`’s Apple availability list includes iOS, iPadOS, Mac Catalyst, macOS, and visionOS, **not watchOS**. The current repository’s HTML surface is explicitly `#if os(macOS)` and imports AppKit/WebKit; its sanitizer can be shared, but its WebKit isolation fence, custom scheme handler, HTML layout, remote-image reveal, and attachment rendering cannot be reused on Watch. ([WKWebView](https://developer.apple.com/documentation/webkit/wkwebview), [MessageWebView.swift](../App/Sources/MessageWeb/MessageWebView.swift), [MessageHTMLView.swift](../App/Sources/Viewer/MessageHTMLView.swift))

**Inference:** ship plain text/envelope/attachment indicators first, or build a native constrained HTML-to-text/markup renderer. A full `WKWebView` mail reader is not a portability option. Inline and explicit attachments can be fetched on demand only through whichever high-level mail API is chosen.

## Standalone media playback is a comparison, not evidence for mail

Apple’s WWDC19 session states that watchOS 6 introduced independent audio streaming without an iPhone. It supports HLS through `AVQueuePlayer` and custom audio protocols using URLSession/Network, then AVFoundation playback. Crucially, the session says the networking APIs are unavailable until an audio session is active, and the project must enable the Audio background mode for continued playback. ([WWDC19 Session 716: Streaming Audio on watchOS 6](https://developer.apple.com/videos/play/wwdc2019/716/))

Apple’s current background-audio guide requires the Audio background mode, an activated `.longFormAudio` playback session, and a Bluetooth audio route; failure to obtain a route fails activation. ([Playing Background Audio](https://developer.apple.com/documentation/watchkit/playing-background-audio)) WWDC20 adds watchOS 7 FairPlay Streaming support and recommends larger HLS target durations for Watch mobility/battery conditions. ([WWDC20 Session 10636](https://developer.apple.com/videos/play/wwdc2020/10636/))

That is a narrowly granted, media-specific execution/networking exception. TN3135 explicitly lists active audio streaming as one of the allowed low-level cases and explicitly denies low-level networking to ordinary apps. Downloading or playing music phone-free therefore demonstrates that Apple supports that audio product shape; it does **not** demonstrate that arbitrary mail sockets, IMAP IDLE, SwiftNIO BSD sockets, or a background mail worker are permitted.
## Feasibility that still needs a real-device prototype

The following are not Apple guarantees and were not claimed as runtime proof here:

1. Build the shared core and a minimal Watch SwiftUI target with `.watchOS(.v27)` (or the chosen deployment floor), then measure GRDB WAL/FTS memory, migration time, query latency, and database growth on representative watches.
2. Exercise only a high-level HTTPS test endpoint across all three documented routes: paired-iPhone proxy, known Wi-Fi, and Watch cellular. Exercise foreground fetches, push-triggered short refresh, background URLSession downloads/uploads, cancellation, deferral, and relaunch delivery.
3. Validate APNs token registration and alert/silent behavior on an independent Watch app, including push arrival while the app is suspended or terminated. Treat timing as best-effort, not a mail freshness guarantee.
4. Exercise custom app-password entry and at least one provider OAuth flow through Watch UI, including Keychain save/load after relaunch, token expiry, revocation, and no-phone setup.
5. Measure the chosen local-retention policy, cache purge recovery, attachment cancellation/resume, FTS rebuild, and offline queued triage under low battery/storage conditions.
6. Prototype plain-text/native-markup rendering against hostile MIME/HTML fixtures. No simulator or macOS WebKit result can establish Watch rendering or low-level-network behavior.

These prototypes can establish whether a constrained HTTPS-backed Watch client is pleasant and resource-safe. They cannot turn the TN3135-prohibited direct IMAP path into a supported design.


## Reuse versus new Watch work

| Existing piece | Reuse assessment | Required change |
|---|---|---|
| `MailternalInterfaces` models and durable mutation semantics | Reuse conceptually | Add/confirm a transport-independent change-token contract for the selected HTTPS/API provider; do not expose IMAP-only assumptions to Watch. |
| `MailternalMIME` | Likely reuse | Keep hard parser limits; prototype memory and cancellation on Watch. |
| `MailternalStore` + GRDB/SQLite/FTS5 | Likely reuse after package/platform work | Add `.watchOS(...)` to the root package platform declaration; choose Watch database location, WAL behavior, retention, and much smaller cache/data budgets. |
| `MailternalSanitizer` / SwiftSoup | Reuse sanitization logic only | New native Watch presentation (plain text or constrained markup); no WebKit renderer. |
| `MailternalIMAP` / NIOIMAP / NIOSSL | **Do not use for Watch direct mail** | NIOIMAP’s branch declares watchOS 11 and SwiftNIO can compile portable pieces, but TN3135 forbids the BSD-socket runtime. The package’s current Network/NIO transport is not a legal workaround. |
| `MailternalSync` | Reuse policy ideas, not transport implementation | Add a high-level API/relay adapter with delta, command acknowledgment, attachment download, auth refresh, and retry semantics. Remove assumptions that `connect()` means a persistent IMAP session/IDLE channel. |
| `KeychainStore` | New Watch adapter | The current implementation lives in the macOS-only `MailternalLive` target. Add Watch-specific signing/Keychain configuration and phone-free setup flow. |
| APNs/push spec | Reuse no-content wake/security posture | Watch registers its own token and receives direct pushes; replace the iOS NSE/IMAP-fetch step with a short, high-level Watch refresh, or show a generic notification. |
| macOS `WKWebView`/AppKit UI | No | New watchOS SwiftUI target and glanceable interaction model. |

The root `Package.swift` currently declares only `.macOS(.v15)` even though the selected upstream dependencies advertise Watch support (GRDB watchOS 7, SwiftSoup watchOS 6, and the pinned `swift-nio-imap` branch watchOS 11). SwiftPM documents `Package.platforms` as the minimum versions for platforms supported by the package. This is a concrete build-portability issue separate from Apple’s runtime networking block. ([Package.swift](../Package.swift), [Package platforms](https://developer.apple.com/documentation/packagedescription/package/platforms), [pinned NIOIMAP Package.swift](https://raw.githubusercontent.com/kaygdotorg/swift-nio-imap/mailternal/line-buffer/Package.swift), [SwiftNIO Package.swift](https://raw.githubusercontent.com/apple/swift-nio/main/Package.swift))

## Smallest outstanding product decisions for the grilling frontier

1. **Transport/trust boundary:** Is phone-free Watch mail allowed to use a new HTTPS/JMAP/provider API or a self-hosted/vendor relay that holds mailbox authorization? If no, the honest scope is local cached mail plus phone/desktop synchronization when available; direct Watch IMAP is closed by TN3135.
2. **Provider scope:** Generic IMAP cannot be implemented directly on Watch. Choose provider APIs (JMAP/Gmail/Graph where available), or define the relay’s delta/command/attachment API and mailbox-credential liability.
3. **Freshness promise:** Choose “refresh while open / best-effort push” versus a stronger SLA. Apple’s Watch background budgets and deferred URL sessions rule out a continuous or guaranteed instant mail stream.
4. **Local-retention budget:** Set a Watch-specific message/text/FTS/database and attachment cap, and decide whether old history is evicted or merely disclosed as unavailable. The macOS 2 GiB attachment default is not a Watch decision.
5. **Body UX/security:** Choose plain text first versus a bounded native markup renderer. `WKWebView` is unavailable; arbitrary HTML, scripts, remote images, and interactive links cannot inherit the macOS viewer.
6. **Credential UX:** Choose custom app-password entry versus provider OAuth/Sign in with Apple, and decide whether iCloud Keychain/pairing is only an optional accelerator. Phone-free setup must remain complete without it.
7. **Triage conflict policy:** Keep the existing durable local queues, but specify command idempotency, server acknowledgments, stale-generation handling, and behavior when the Watch has been offline since the last delta.

These choices determine whether the Watch is a genuinely independent, constrained mail client backed by high-level APIs, rather than a phone-dependent IMAP viewer with an independence label.

## Primary sources

- Apple: [Creating independent watchOS apps](https://developer.apple.com/documentation/watchos-apps/creating-independent-watchos-apps), [WKRunsIndependentlyOfCompanionApp](https://developer.apple.com/documentation/bundleresources/information-property-list/wkrunsindependentlyofcompanionapp), [Authenticating users on Apple Watch](https://developer.apple.com/documentation/watchos-apps/authenticating-users-on-apple-watch)
- Apple: [Keeping your watchOS app’s content up to date](https://developer.apple.com/documentation/watchos-apps/keeping-your-watchos-app-s-content-up-to-date), [Making default and ephemeral requests](https://developer.apple.com/documentation/watchos-apps/making-default-and-ephemeral-requests), [Making background requests](https://developer.apple.com/documentation/watchos-apps/making-background-requests), [Background execution](https://developer.apple.com/documentation/watchkit/background-execution), [Life cycles](https://developer.apple.com/documentation/watchkit/life-cycles), [Using background tasks](https://developer.apple.com/documentation/watchkit/using-background-tasks)
- Apple: [TN3135: Low-level networking on watchOS](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos), [Network](https://developer.apple.com/documentation/network), [URLSession](https://developer.apple.com/documentation/foundation/urlsession), [NWConnection](https://developer.apple.com/documentation/network/nwconnection)
- Apple: [WatchOS notifications](https://developer.apple.com/documentation/watchos-apps/notifications), [Register for remote notifications](https://developer.apple.com/documentation/watchkit/wkextension/registerforremotenotifications()), [Playing Background Audio](https://developer.apple.com/documentation/watchkit/playing-background-audio), [WWDC19 Session 716](https://developer.apple.com/videos/play/wwdc2019/716/), [WWDC20 Session 10636](https://developer.apple.com/videos/play/wwdc2020/10636/)
- Apple: [Keychain services](https://developer.apple.com/documentation/security/keychain-services), [kSecAttrAccessible](https://developer.apple.com/documentation/security/ksecattraccessible), [kSecAttrSynchronizable](https://developer.apple.com/documentation/security/ksecattrsynchronizable), [Sharing access to keychain items](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps), [ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)
- Apple: [WKWebView](https://developer.apple.com/documentation/webkit/wkwebview), [Monitoring your app’s storage metrics](https://developer.apple.com/documentation/xcode/monitoring-your-app-s-storage-metrics), [Maximum build file sizes](https://developer.apple.com/help/app-store-connect/reference/app-uploads/maximum-build-file-sizes/)
- Upstream: [GRDB Package.swift](https://raw.githubusercontent.com/groue/GRDB.swift/master/Package.swift), [SwiftSoup Package.swift](https://raw.githubusercontent.com/scinfu/SwiftSoup/master/Package.swift), [pinned NIOIMAP Package.swift](https://raw.githubusercontent.com/kaygdotorg/swift-nio-imap/mailternal/line-buffer/Package.swift)
- Repository context: [push spec](../docs/spec/push.md), [pairing spec](../docs/spec/pairing.md), [iOS IMAP/relay/APNs evidence memo](ios-imap-relay-apns-2026.md), [Package.swift](../Package.swift), [MailStore.swift](../Sources/MailternalStore/MailStore.swift), [AttachmentCache.swift](../Sources/MailternalStore/AttachmentCache.swift)
