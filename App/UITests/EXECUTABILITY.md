# Mailternal XCUITest executability (agents@mbp, ssh)

Date: 2026-09-01. Host: agents@mbp. No commits.

## What ran

| Command | Result |
|---|---|
| `xcodegen generate` (type `bundle.ui-testing`) | Created `App/Mailternal.xcodeproj` |
| `xcodebuild build-for-testing -project Mailternal.xcodeproj -scheme Mailternal -destination 'platform=macOS' -derivedDataPath build` | **TEST BUILD SUCCEEDED** |
| `xcodebuild test … -only-testing:MailternalAppTests` | **TEST SUCCEEDED** — 8/8 `UILogicTests` passed (date rules, prefetch window, search normalize + debounce). No WindowServer required. |
| `xcodebuild test … -only-testing:MailternalUITests` | **TEST FAILED** before any test case — runner never initialized. |
| `Mailternal.app/Contents/MacOS/Mailternal -mock` under ssh | Process exited 133 immediately. Did **not** reach a CGSession diagnostic; crashed first in `AppearanceSettings.init`. |
| `Scripts/qa/run-ui-tests.sh` | Ready for a GUI console session. Not executable over this ssh Background Aqua session. |

`launchctl managername` on the ssh session: `Background`. `DISPLAY` unset. `SSH_TTY` unset.

## What cannot run over ssh, and why

### XCUITest bundle

`MailternalUITests-Runner` cannot enable UI automation from this ssh session. Verbatim from `/tmp/mailternal-ui-test.log`:

```
2026-09-01 09:44:53.057651+0530 MailternalUITests-Runner[34928:5998030] [Default] Failed to initialize for UI testing: Error Domain=com.apple.dt.XCTest.XCTFuture Code=1000 "Timed out while enabling automation mode." UserInfo={NSLocalizedDescription=Timed out while enabling automation mode.}
	MailternalUITests-Runner (34928) encountered an error (The test runner failed to initialize for UI testing. (Underlying Error: Timed out while enabling automation mode.))
** TEST FAILED **
```

No WindowServer-denial string was emitted. The block is XCTest automation-mode enablement timing out in a Background launchd manager (no GUI console for this ssh job).

Result bundle: `/Users/agents/mailternal-build/UiTester/App/build/Logs/Test/Test-Mailternal-2026.09.01_09-43-45-+0530.xcresult`

Run the suite from a GUI login with `Scripts/qa/run-ui-tests.sh`.

### Headless app binary

Command:

```
~/mailternal-build/UiTester/App/build/Build/Products/Debug/Mailternal.app/Contents/MacOS/Mailternal -mock
```

Verbatim stderr (stdout empty). Exit 133 (`EXC_BREAKPOINT` / `SIGTRAP`):

```
Mailternal/AppearanceSettings.swift:152: Fatal error: Unexpectedly found nil while implicitly unwrapping an Optional value
```

Crash report `~/Library/Logs/DiagnosticReports/Mailternal-2026-09-01-094536.ips`:

```
exception type: EXC_BREAKPOINT signal: SIGTRAP
termination: SIGNAL / Trace/BPT trap: 5
faulting thread: com.apple.main-thread
  _assertionFailure
  AppearanceSettings.applyAppKitAppearance()
  AppearanceSettings.init(defaults:)
  MailternalApp.init()
  static App.main()
```

`NSApp` is still nil when `applyAppKitAppearance()` assigns `NSApp.appearance`. That is the first failure; a CGSession / WindowServer diagnostic was not reached.

## File list

New:

- `App/project.yml` — `MailternalAppTests` (`bundle.unit-test`) + `MailternalUITests` (`bundle.ui-testing`), scheme `-mock` on run/test
- `App/Sources/Support/UILogic.swift` — `UIIdentifier`, moved `MailDateFormat`, `MessageListPrefetch`, `SearchQueryPolicy`
- `App/AppTests/UILogicTests.swift`
- `App/UITests/MailternalUITests.swift`
- `App/UITests/EXECUTABILITY.md`
- `Scripts/qa/run-ui-tests.sh`

Touched (identifiers or behavior-preserving call sites only):

- `App/Sources/Sidebar/FolderSidebar.swift`
- `App/Sources/MessageList/MessageTableView.swift`
- `App/Sources/Viewer/MessageViewer.swift`
- `App/Sources/Search/SearchPanel.swift`
- `App/Sources/Account/SettingsWindow.swift`
- `App/Sources/Toasts/ToastStack.swift`
- `App/Sources/Shell/MainWindowController.swift`
- `App/Sources/Model/AppModel.swift` — prefetch uses `MessageListPrefetch` (pageSize 80, margin 24, same predicate)
- `App/Sources/Support/DesignTokens.swift` — `MailDateFormat` relocated, logic unchanged
