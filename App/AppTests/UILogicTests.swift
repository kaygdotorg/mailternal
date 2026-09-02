import XCTest
import AppKit
import SwiftUI
import MailternalInterfaces
final class UILogicTests: XCTestCase {
    func testSidebarVisibilityToggleHidesOnlyTheSidebar() {
        // Hiding collapses the first column only; the message list stays.
        XCTAssertEqual(
            SidebarVisibilityPolicy.toggled(current: .all, lastVisible: .all),
            .doubleColumn
        )
        // Showing again restores the last visible arrangement.
        XCTAssertEqual(
            SidebarVisibilityPolicy.toggled(current: .doubleColumn, lastVisible: .all),
            .all
        )
        // A restored detail-only state still counts as hidden.
        XCTAssertEqual(
            SidebarVisibilityPolicy.toggled(current: .detailOnly, lastVisible: .detailOnly),
            .all
        )
        XCTAssertEqual(
            SidebarVisibilityPolicy.remembered(.doubleColumn, lastVisible: .all),
            .all
        )
        XCTAssertEqual(
            SidebarVisibilityPolicy.remembered(.all, lastVisible: .doubleColumn),
            .all
        )
        XCTAssertTrue(SidebarVisibilityPolicy.isHidden(.doubleColumn))
        XCTAssertFalse(SidebarVisibilityPolicy.isHidden(.all))
    }

    func testSettingsSectionTitleIdentifierIsStable() {
        XCTAssertEqual(UIIdentifier.settingsSectionTitle, "settings-section-title")
    }
    func testListRowTodayUsesRelativeNamedNarrowFormat() {
        let now = Date()
        let calendar = Calendar.current
        let expected = now.formatted(.relative(presentation: .named, unitsStyle: .narrow))
        XCTAssertEqual(MailDateFormat.listRow(now, now: now, calendar: calendar), expected)
    }

    func testListRowYesterdayIsLiteralYesterday() {
        let now = Date()
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(MailDateFormat.listRow(yesterday, now: now, calendar: calendar), "Yesterday")
    }

    func testListRowWithinWeekUsesWeekdayName() {
        let now = Date()
        let calendar = Calendar.current
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: now)!
        XCTAssertEqual(
            MailDateFormat.listRow(threeDaysAgo, now: now, calendar: calendar),
            threeDaysAgo.formatted(.dateTime.weekday(.wide))
        )
    }

    func testListRowOlderThanAWeekUsesAbsoluteDate() {
        let now = Date()
        let calendar = Calendar.current
        let older = calendar.date(byAdding: .day, value: -30, to: now)!
        XCTAssertEqual(
            MailDateFormat.listRow(older, now: now, calendar: calendar),
            older.formatted(.dateTime.month(.abbreviated).day().year())
        )
    }

    func testEnvelopeAndSyncedThroughFormats() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            MailDateFormat.envelope(date),
            date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year().hour().minute())
        )
        XCTAssertEqual(
            MailDateFormat.syncedThrough(date),
            date.formatted(.dateTime.month(.abbreviated).day().year())
        )
    }

    func testPrefetchWindowTriggersNearEndOfLoadedPage() {
        XCTAssertEqual(MessageListPrefetch.pageSize, 80)
        XCTAssertEqual(MessageListPrefetch.margin, 24)
        XCTAssertFalse(MessageListPrefetch.shouldLoadMore(near: 10, loadedCount: 80, hasMore: true, isPaging: false))
        XCTAssertFalse(MessageListPrefetch.shouldLoadMore(near: 55, loadedCount: 80, hasMore: true, isPaging: false))
        XCTAssertTrue(MessageListPrefetch.shouldLoadMore(near: 56, loadedCount: 80, hasMore: true, isPaging: false))
        XCTAssertTrue(MessageListPrefetch.shouldLoadMore(near: 79, loadedCount: 80, hasMore: true, isPaging: false))
        XCTAssertFalse(MessageListPrefetch.shouldLoadMore(near: 79, loadedCount: 80, hasMore: true, isPaging: true))
        XCTAssertFalse(MessageListPrefetch.shouldLoadMore(near: 79, loadedCount: 80, hasMore: false, isPaging: false))
    }

    @MainActor
    func testAppearanceMessageListLinesDefaultsAndClamps() {
        let suiteName = "Mailternal.AppearanceSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let defaultSettings = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(defaultSettings.messageListLines, 3)

        defaults.set(0, forKey: "mailternal.appearance.message-list-lines")
        XCTAssertEqual(AppearanceSettings(defaults: defaults).messageListLines, 1)
        defaults.set(9, forKey: "mailternal.appearance.message-list-lines")
        XCTAssertEqual(AppearanceSettings(defaults: defaults).messageListLines, 6)

        defaultSettings.messageListLines = -10
        XCTAssertEqual(defaultSettings.messageListLines, 1)
        XCTAssertEqual(defaults.integer(forKey: "mailternal.appearance.message-list-lines"), 1)
        defaultSettings.messageListLines = 20
        XCTAssertEqual(defaultSettings.messageListLines, 6)
        XCTAssertEqual(defaults.integer(forKey: "mailternal.appearance.message-list-lines"), 6)
    }

    @MainActor
    func testEmailReadingModeDefaultsPersistsAndRejectsInvalidValues() {
        let suiteName = "Mailternal.EmailReadingModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(settings.emailReadingMode, .original)

        settings.emailReadingMode = .dark
        XCTAssertEqual(defaults.string(forKey: "mailternal.appearance.email-reading"), "dark")
        XCTAssertEqual(AppearanceSettings(defaults: defaults).emailReadingMode, .dark)

        defaults.set("sepia", forKey: "mailternal.appearance.email-reading")
        XCTAssertEqual(AppearanceSettings(defaults: defaults).emailReadingMode, .original)
    }

    @MainActor
    func testAccentSourceResolvesOneCustomColorForSwiftUIAndAppKit() {
        let suiteName = "Mailternal.AccentSourceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let source = AppearanceSettings(defaults: defaults).accent
        let custom = AccentColorValue(red: 0.17, green: 0.42, blue: 0.81)
        source.accentOverride = custom

        let appKitValue = AccentColorValue(nsColor: source.nsColor)
        let swiftUIValue = AccentColorValue(nsColor: NSColor(source.color))
        XCTAssertEqual(appKitValue.red, swiftUIValue.red, accuracy: 0.0001)
        XCTAssertEqual(appKitValue.green, swiftUIValue.green, accuracy: 0.0001)
        XCTAssertEqual(appKitValue.blue, swiftUIValue.blue, accuracy: 0.0001)
        XCTAssertEqual(appKitValue.alpha, swiftUIValue.alpha, accuracy: 0.0001)
        XCTAssertEqual(defaults.array(forKey: "mailternal.appearance.accent") as? [Double], [
            custom.red,
            custom.green,
            custom.blue,
            custom.alpha,
        ])
    }

    @MainActor
    func testAccentSourceResetReturnsToSystemResolution() {
        let suiteName = "Mailternal.AccentResetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let source = AppearanceSettings(defaults: defaults).accent
        let custom = AccentColorValue(red: 0.91, green: 0.23, blue: 0.14)
        source.accentOverride = custom
        XCTAssertEqual(AccentColorValue(nsColor: source.nsColor), custom)

        source.accentOverride = nil

        XCTAssertNil(source.accentOverride)
        XCTAssertNil(defaults.object(forKey: "mailternal.appearance.accent"))
        let systemValue = AccentColorValue(nsColor: source.nsColor)
        let swiftUIValue = AccentColorValue(nsColor: NSColor(source.color))
        XCTAssertEqual(systemValue.red, swiftUIValue.red, accuracy: 0.0001)
        XCTAssertEqual(systemValue.green, swiftUIValue.green, accuracy: 0.0001)
        XCTAssertEqual(systemValue.blue, swiftUIValue.blue, accuracy: 0.0001)
        XCTAssertEqual(systemValue.alpha, swiftUIValue.alpha, accuracy: 0.0001)
    }

    @MainActor
    func testAppearanceDefaultsToBlurAtFullOpacity() {
        let suiteName = "Mailternal.AppearanceDefaultsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppearanceSettings(defaults: defaults)

        XCTAssertEqual(settings.backdropKind, .blur)
        XCTAssertFalse(settings.usesLiquidGlass)
        XCTAssertEqual(settings.backgroundOpacity, 1)
        XCTAssertEqual(
            WindowBackdropPlan(
                kind: settings.backdropKind,
                opacity: settings.backgroundOpacity,
                reduceTransparency: false,
                isFullScreen: false
            ).treatment,
            .opaque
        )
    }

    @MainActor
    func testAppearanceMigratesLegacyOpaqueToBlurAtFullOpacity() {
        let suiteName = "Mailternal.AppearanceLegacyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("opaque", forKey: "mailternal.appearance.backdrop")
        defaults.set(0.62, forKey: "mailternal.appearance.opacity")

        let settings = AppearanceSettings(defaults: defaults)

        XCTAssertEqual(settings.backdropKind, .blur)
        XCTAssertFalse(settings.usesLiquidGlass)
        XCTAssertFalse(
            defaults.bool(forKey: "mailternal.appearance.usesLiquidGlass")
        )
        XCTAssertEqual(settings.backgroundOpacity, 1)
        XCTAssertNil(defaults.string(forKey: "mailternal.appearance.backdrop"))
        XCTAssertEqual(
            defaults.double(forKey: "mailternal.appearance.opacity"),
            1
        )
    }

    @MainActor
    func testAppearancePreservesExplicitGlassAndOpacity() {
        let suiteName = "Mailternal.AppearanceGlassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("glass", forKey: "mailternal.appearance.backdrop")
        defaults.set(0.62, forKey: "mailternal.appearance.opacity")

        let settings = AppearanceSettings(defaults: defaults)
        let plan = WindowBackdropPlan(
            kind: settings.backdropKind,
            opacity: settings.backgroundOpacity,
            reduceTransparency: false,
            isFullScreen: false
        )

        XCTAssertEqual(settings.backdropKind, .glass)
        XCTAssertTrue(settings.usesLiquidGlass)
        XCTAssertEqual(settings.backgroundOpacity, 0.62)
        XCTAssertEqual(plan.treatment, .glass)
    }

    @MainActor
    func testAppearancePreservesExplicitBlurAndOpacity() {
        let suiteName = "Mailternal.AppearanceBlurTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("blur", forKey: "mailternal.appearance.backdrop")
        defaults.set(0.62, forKey: "mailternal.appearance.opacity")

        let settings = AppearanceSettings(defaults: defaults)
        let plan = WindowBackdropPlan(
            kind: settings.backdropKind,
            opacity: settings.backgroundOpacity,
            reduceTransparency: false,
            isFullScreen: false
        )

        XCTAssertEqual(settings.backdropKind, .blur)
        XCTAssertFalse(settings.usesLiquidGlass)
        XCTAssertEqual(settings.backgroundOpacity, 0.62)
        XCTAssertEqual(plan.treatment, .blur)
    }

    func testWindowBackdropPlanUsesOpaqueFallbacks() {
        let fallbackInputs: [(Bool, Bool)] = [(true, false), (false, true)]
        for (reduceTransparency, isFullScreen) in fallbackInputs {
            let plan = WindowBackdropPlan(
                kind: .glass,
                opacity: 0.62,
                reduceTransparency: reduceTransparency,
                isFullScreen: isFullScreen
            )
            XCTAssertEqual(plan.opacity, 1)
            XCTAssertEqual(plan.treatment, .opaque)
        }
    }

    func testAppearanceHasNoUserFacingOpaqueBackdropCase() {
        XCTAssertEqual(
            WindowBackdropKind.allCases.map(\.rawValue),
            ["blur", "glass"]
        )
        XCTAssertEqual(
            WindowBackdropKind.allCases.map(\.label),
            ["Blur", "Liquid Glass"]
        )
    }

    @MainActor
    func testAppearanceFormatsLiveOpacityPercentage() {
        XCTAssertEqual(AppearanceSettings.formattedOpacityPercentage(0), "0%")
        XCTAssertEqual(AppearanceSettings.formattedOpacityPercentage(0.73), "73%")
        XCTAssertEqual(AppearanceSettings.formattedOpacityPercentage(1), "100%")
    }

    @MainActor
    func testAppearanceOpacityDialReachesZeroAndPersists() {
        let suiteName = "Mailternal.AppearanceOpacityRangeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AppearanceSettings.backgroundOpacityRange.lowerBound, 0)
        XCTAssertEqual(AppearanceSettings.backgroundOpacityRange.upperBound, 1)
        XCTAssertEqual(AppearanceSettings.clampBackgroundOpacity(-0.5), 0)
        XCTAssertEqual(AppearanceSettings.clampBackgroundOpacity(1.5), 1)

        let settings = AppearanceSettings(defaults: defaults)
        settings.backgroundOpacity = AppearanceSettings.backgroundOpacityRange.lowerBound
        settings.persistOpacity()

        XCTAssertEqual(settings.backgroundOpacity, 0)
        XCTAssertEqual(defaults.double(forKey: "mailternal.appearance.opacity"), 0)
        XCTAssertEqual(AppearanceSettings(defaults: defaults).backgroundOpacity, 0)
    }

    func testWindowBackdropKeepsTreatmentDownToZeroOpacity() {
        for opacity in [0.0, 0.5, 0.99] {
            XCTAssertEqual(
                WindowBackdropPlan(
                    kind: .blur,
                    opacity: opacity,
                    reduceTransparency: false,
                    isFullScreen: false
                ).treatment,
                .blur
            )
            XCTAssertEqual(
                WindowBackdropPlan(
                    kind: .glass,
                    opacity: opacity,
                    reduceTransparency: false,
                    isFullScreen: false
                ).treatment,
                .glass
            )
        }
        XCTAssertEqual(
            WindowBackdropPlan(
                kind: .glass,
                opacity: 1,
                reduceTransparency: false,
                isFullScreen: false
            ).treatment,
            .opaque
        )
    }

    func testMessageListFieldVisibilityMatchesLineCount() {
        XCTAssertEqual(
            MessageListLayout.fieldVisibility(for: 1),
            MessageListFieldVisibility(sender: false, date: false, preview: false)
        )
        XCTAssertEqual(
            MessageListLayout.fieldVisibility(for: 2),
            MessageListFieldVisibility(sender: true, date: true, preview: false)
        )
        XCTAssertEqual(
            MessageListLayout.fieldVisibility(for: 3),
            MessageListFieldVisibility(sender: true, date: true, preview: true)
        )
        XCTAssertEqual(MessageListLayout.previewLineCount(for: 6), 4)
    }

    func testMessageListRowHeightsAreMonotonic() {
        let heights = MessageListLayout.lineRange.map { MessageListLayout.rowHeight(for: $0) }
        XCTAssertEqual(heights[2], 72)
        XCTAssertEqual(heights, heights.sorted())
        XCTAssertTrue(zip(heights, heights.dropFirst()).allSatisfy { $0.0 < $0.1 })
    }

    func testSearchNormalizesQueryAndTreatsWhitespaceAsEmpty() {
        XCTAssertNil(SearchQueryPolicy.normalizedQuery(""))
        XCTAssertNil(SearchQueryPolicy.normalizedQuery("   \t"))
        XCTAssertEqual(SearchQueryPolicy.normalizedQuery("  Lunch  "), "Lunch")
        XCTAssertEqual(SearchQueryPolicy.debounce, .milliseconds(120))
    }

    func testSearchDebounceCancelsSupersededQueries() async {
        actor Collector {
            var values: [String] = []
            func add(_ value: String) { values.append(value) }
            func snapshot() -> [String] { values }
        }
        let collector = Collector()
        var task: Task<Void, Never>?
        func schedule(_ text: String) {
            task?.cancel()
            guard let query = SearchQueryPolicy.normalizedQuery(text) else { return }
            task = Task {
                try? await Task.sleep(for: SearchQueryPolicy.debounce)
                guard !Task.isCancelled else { return }
                await collector.add(query)
            }
        }
        schedule("L")
        schedule("   ")
        schedule("Lu")
        schedule("Lunch")
        await task?.value
        let values = await collector.snapshot()
        XCTAssertEqual(values, ["Lunch"])
    }

    func testFindRangesAreCaseInsensitiveAndNonOverlapping() {
        let text = "Aaa aa A"
        let ranges = MessageFind.ranges(in: text, query: "aa")
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(String(text[ranges[0]]), "Aa")
        XCTAssertEqual(String(text[ranges[1]]), "aa")
        XCTAssertTrue(MessageFind.ranges(in: text, query: "").isEmpty)
        XCTAssertTrue(MessageFind.ranges(in: "hello", query: "z").isEmpty)
    }

    func testFindAdvanceWrapsForwardAndBackward() {
        XCTAssertEqual(MessageFind.advance(index: 0, count: 3, step: .next), 1)
        XCTAssertEqual(MessageFind.advance(index: 1, count: 3, step: .next), 2)
        XCTAssertEqual(MessageFind.advance(index: 2, count: 3, step: .next), 0)
        XCTAssertEqual(MessageFind.advance(index: 0, count: 3, step: .previous), 2)
        XCTAssertEqual(MessageFind.advance(index: 2, count: 3, step: .previous), 1)
        XCTAssertEqual(MessageFind.advance(index: 0, count: 1, step: .next), 0)
        XCTAssertEqual(MessageFind.advance(index: 0, count: 1, step: .previous), 0)
    }

    func testFindAdvanceNilIndexStartsAtEndForPrevious() {
        XCTAssertEqual(MessageFind.advance(index: nil, count: 4, step: .next), 0)
        XCTAssertEqual(MessageFind.advance(index: nil, count: 4, step: .previous), 3)
        XCTAssertNil(MessageFind.advance(index: 0, count: 0, step: .next))
        XCTAssertNil(MessageFind.advance(index: nil, count: 0, step: .previous))
    }

    func testFindRestartAndClampAndSelectedMatchNumber() {
        XCTAssertEqual(MessageFind.restartIndex(count: 5), 0)
        XCTAssertNil(MessageFind.restartIndex(count: 0))
        XCTAssertEqual(MessageFind.clamp(4, count: 2), 1)
        XCTAssertEqual(MessageFind.clamp(-1, count: 2), 0)
        XCTAssertNil(MessageFind.clamp(0, count: 0))

        let text = "one two one"
        let snapshot = MessageFind.make(text: text, query: "one", index: 7)
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot.index, 1)
        XCTAssertEqual(snapshot.selectedMatchNumber, 2)
        XCTAssertEqual(snapshot.selectedRange.map { String(text[$0]) }, "one")

        let empty = MessageFind.make(text: text, query: "zzz", index: 0)
        XCTAssertEqual(empty.count, 0)
        XCTAssertNil(empty.index)
        XCTAssertNil(empty.selectedMatchNumber)
    }

    func testFindHaystackPrefersRawThenVisibleHTMLThenPlain() {
        XCTAssertEqual(
            MessageFind.haystack(
                bodyText: "plain",
                html: "<p>html</p>",
                raw: "RAW",
                showingRaw: true
            ),
            "RAW"
        )
        XCTAssertEqual(
            MessageFind.haystack(
                bodyText: "plain",
                html: "<p>html</p>",
                raw: "RAW",
                showingRaw: false
            ),
            "html"
        )
        XCTAssertEqual(
            MessageFind.haystack(
                bodyText: "plain",
                html: nil,
                raw: nil,
                showingRaw: false
            ),
            "plain"
        )
        XCTAssertEqual(
            MessageFind.haystack(
                bodyText: nil,
                html: "<p>Hello <b>world</b></p>",
                raw: nil,
                showingRaw: false
            ),
            "Hello world"
        )
        XCTAssertEqual(MessageFind.visibleText(fromHTML: "<div>A</div><div>B</div>"), "AB")
    }

    func testMailWindowTopDissolveShapeStartsClearAndEndsOpaque() {
        let stops = MailWindowTopDissolvePolicy.stops
        XCTAssertEqual(stops.filter { $0.alpha == 0 }.count, 1)
        XCTAssertEqual(stops.first?.location, 0)
        XCTAssertEqual(stops.last?.location, 1)
        XCTAssertEqual(stops.last?.alpha, 1)
        XCTAssertEqual(MailWindowTopDissolvePolicy.alpha(atFraction: 0), 0)
        XCTAssertEqual(MailWindowTopDissolvePolicy.alpha(atFraction: 1), 1)
        XCTAssertEqual(
            MailWindowTopDissolvePolicy.alpha(atFraction: 0.5),
            0.52,
            accuracy: 0.000_001
        )
        XCTAssertTrue(zip(stops, stops.dropFirst()).allSatisfy { previous, next in
            next.location >= previous.location && next.alpha >= previous.alpha
        })
    }

    func testSidebarRampStartsAfterSafeAreaAndListRampStartsAtWindowTop() {
        let safeAreaTop: CGFloat = 52
        let sidebar = MailWindowDissolvePolicy.sidebar
        let messageList = MailWindowDissolvePolicy.messageList

        XCTAssertEqual(sidebar.topOrigin, .titlebarSafeArea)
        XCTAssertEqual(messageList.topOrigin, .windowTop)

        // Sidebar: no ink anywhere in the traffic-light band, opaque again one
        // reach below it, which is exactly where its first row rests.
        XCTAssertEqual(sidebar.alpha(atDepth: 0, safeAreaTop: safeAreaTop), 0)
        XCTAssertEqual(sidebar.alpha(atDepth: 28, safeAreaTop: safeAreaTop), 0)
        XCTAssertEqual(sidebar.alpha(atDepth: safeAreaTop, safeAreaTop: safeAreaTop), 0)
        XCTAssertGreaterThan(sidebar.alpha(atDepth: safeAreaTop + 4, safeAreaTop: safeAreaTop), 0)
        XCTAssertEqual(
            sidebar.alpha(atDepth: safeAreaTop + sidebar.topReach, safeAreaTop: safeAreaTop),
            1
        )
        XCTAssertEqual(sidebar.restDepth(safeAreaTop: safeAreaTop), safeAreaTop + sidebar.topReach)

        // Message list: the ramp is anchored at the physical window top, so
        // content is already fading one point down.
        XCTAssertEqual(messageList.alpha(atDepth: 0, safeAreaTop: safeAreaTop), 0)
        XCTAssertGreaterThan(messageList.alpha(atDepth: 1, safeAreaTop: safeAreaTop), 0)
        XCTAssertEqual(
            messageList.alpha(atDepth: messageList.topReach, safeAreaTop: safeAreaTop),
            1
        )
        XCTAssertEqual(messageList.restDepth(safeAreaTop: 0), messageList.topReach)

        // Unmeasured geometry falls back to the documented titlebar token.
        XCTAssertEqual(
            sidebar.restDepth(safeAreaTop: 0),
            MailWindowTopDissolvePolicy.titlebarDepth + sidebar.topReach
        )
    }

    func testMailWindowDissolveDualEdgePoliciesUseFullSurfaceDimensions() {
        let height: CGFloat = 720
        let safeAreaTop: CGFloat = 52
        let sidebar = MailWindowDissolvePolicy.sidebar
        let messageList = MailWindowDissolvePolicy.messageList
        let sidebarStops = sidebar.stops(for: height, safeAreaTop: safeAreaTop)
        let messageStops = messageList.stops(for: height, safeAreaTop: safeAreaTop)

        XCTAssertEqual(sidebar.topReach, 32)
        XCTAssertEqual(sidebar.bottomReach, 48)
        XCTAssertEqual(sidebar.bottomReservedHeight, 0)
        XCTAssertEqual(messageList.topReach, 52)
        XCTAssertEqual(messageList.bottomReach, 48)
        XCTAssertEqual(messageList.bottomReservedHeight, 0)
        XCTAssertTrue(sidebar.hasBottomRamp)
        XCTAssertTrue(messageList.hasBottomRamp)

        // The sidebar holds a clear plateau across the measured band: a stop at
        // the window top and a second one at the boundary, with the first ink
        // below it. The message list has one clear stop, at the window top.
        XCTAssertEqual(
            sidebarStops.filter { $0.alpha == 0 && $0.location * height <= safeAreaTop }.count,
            2
        )
        XCTAssertEqual(sidebarStops.first?.location, 0)
        XCTAssertEqual(sidebarStops.first?.alpha, 0)
        XCTAssertGreaterThan(
            (sidebarStops.first { $0.alpha > 0 }?.location ?? 0) * height,
            safeAreaTop
        )
        XCTAssertEqual(messageStops.first?.location, 0)
        XCTAssertEqual(messageStops.first?.alpha, 0)
        XCTAssertEqual(
            (messageStops.first { $0.alpha > 0 }?.location ?? 0) * height,
            messageList.topReach / 8,
            accuracy: 0.000_1
        )

        // Both bottom ramps still end clear at the pane edge and stay ordered.
        XCTAssertEqual(sidebarStops.last?.location, 1)
        XCTAssertEqual(sidebarStops.last?.alpha, 0)
        XCTAssertEqual(messageStops.last?.location, 1)
        XCTAssertEqual(messageStops.last?.alpha, 0)
        XCTAssertTrue(zip(sidebarStops, sidebarStops.dropFirst()).allSatisfy {
            $0.1.location >= $0.0.location
        })
        XCTAssertTrue(zip(messageStops, messageStops.dropFirst()).allSatisfy {
            $0.1.location >= $0.0.location
        })
    }

    @MainActor
    func testScrollPocketSuppressionUsesOptionalGuardedCapability() {
        _ = NSApplication.shared
        let setter = NSSelectorFromString(ScrollEdgeEffectPolicy.allowedPocketEdgesSetter)
        XCTAssertEqual(ScrollEdgeEffectPolicy.allowedPocketEdgesKey, "allowedPocketEdges")
        XCTAssertEqual(ScrollEdgeEffectPolicy.suppressedPocketEdges, 0)

        let scrollView = NSScrollView()
        guard scrollView.responds(to: setter) else {
            XCTAssertFalse(scrollView.responds(to: setter))
            return
        }
        scrollView.setValue(
            ScrollEdgeEffectPolicy.suppressedPocketEdges,
            forKey: ScrollEdgeEffectPolicy.allowedPocketEdgesKey
        )
        XCTAssertEqual(
            scrollView.value(forKey: ScrollEdgeEffectPolicy.allowedPocketEdgesKey) as? Int,
            ScrollEdgeEffectPolicy.suppressedPocketEdges
        )
    }

    func testReaderTopInsetClearsTheViewerDissolveBeforeAnyGlyphRests() {
        let fadeReach = MailWindowDissolvePolicy.viewer.restDepth(safeAreaTop: 0)
        XCTAssertEqual(fadeReach, MailWindowTopDissolvePolicy.titlebarDepth)

        // Unmeasured geometry falls back to the documented 52 + 12.
        XCTAssertEqual(
            MessageViewerLayoutPolicy.readerTopInset(safeAreaTop: 0),
            fadeReach + MessageViewerLayoutPolicy.fadeGuard
        )
        // A titlebar shallower than the ramp never pulls content into it.
        XCTAssertEqual(
            MessageViewerLayoutPolicy.readerTopInset(safeAreaTop: 32),
            fadeReach + MessageViewerLayoutPolicy.fadeGuard
        )
        // A deeper measured titlebar wins over the fallback.
        XCTAssertEqual(
            MessageViewerLayoutPolicy.readerTopInset(safeAreaTop: 72),
            72 + MessageViewerLayoutPolicy.fadeGuard
        )
        // Whatever the geometry, the subject rests where the mask is opaque.
        for safeAreaTop in [CGFloat(0), 32, 52, 72] {
            XCTAssertEqual(
                MailWindowDissolvePolicy.viewer.alpha(
                    atDepth: MessageViewerLayoutPolicy.readerTopInset(safeAreaTop: safeAreaTop),
                    safeAreaTop: safeAreaTop
                ),
                1
            )
        }
    }

    func testReaderIslandsShareListInsetAndHTMLUsesDocumentHeight() {
        XCTAssertEqual(MessageViewerLayoutPolicy.islandCount, 2)
        XCTAssertEqual(MessageViewerLayoutPolicy.horizontalPadding, 16)
        XCTAssertEqual(MessageViewerLayoutPolicy.islandSpacing, 12)
        XCTAssertEqual(MessageViewerLayoutPolicy.islandContentPadding, 18)
        XCTAssertEqual(MessageViewerLayoutPolicy.bottomPadding, 40)
        XCTAssertEqual(MessageViewerLayoutPolicy.htmlMinimumHeight, 80)
        XCTAssertEqual(MessageViewerLayoutPolicy.plainTextMeasureCharacters, 72)

        XCTAssertEqual(
            MessageViewerLayoutPolicy.htmlHeight(contentHeight: 900),
            900
        )
        XCTAssertEqual(
            MessageViewerLayoutPolicy.htmlHeight(contentHeight: 120),
            120
        )
        XCTAssertEqual(
            MessageViewerLayoutPolicy.htmlHeight(contentHeight: 0),
            MessageViewerLayoutPolicy.htmlMinimumHeight
        )
        XCTAssertEqual(
            MessageViewerLayoutPolicy.htmlHeight(contentHeight: .infinity),
            MessageViewerLayoutPolicy.htmlMinimumHeight
        )
    }

    func testRawHeaderPolicyUnfoldsAndPreservesOrderedHeaders() {
        let raw = """
        Received: from mx.example\r
         by mail.example; Tue, 2 Sep 2026 12:00:00 +0000\r
        Message-ID: <abc@example.com>\r
        Content-Type: text/plain;\r
         charset=utf-8\r
        \r
        This is the body.
        """

        let headers = MessageHeaderPolicy.rawHeaders(from: raw)
        XCTAssertEqual(headers.map { $0.name }, ["Received", "Message-ID", "Content-Type"])
        XCTAssertEqual(
            headers.map { $0.value },
            [
                "from mx.example by mail.example; Tue, 2 Sep 2026 12:00:00 +0000",
                "<abc@example.com>",
                "text/plain; charset=utf-8",
            ]
        )
        XCTAssertEqual(
            MessageHeaderPolicy.rawHeaderBlock(from: raw),
            "Received: from mx.example by mail.example; Tue, 2 Sep 2026 12:00:00 +0000\n"
                + "Message-ID: <abc@example.com>\n"
                + "Content-Type: text/plain; charset=utf-8"
        )
    }

    func testRawHeaderPolicyAcceptsLFAndMissingBlankLine() {
        let raw = "X-First: one\n\tcontinued\nX-Second: two"
        let headers = MessageHeaderPolicy.rawHeaders(from: raw)

        XCTAssertEqual(headers.map { $0.name }, ["X-First", "X-Second"])
        XCTAssertEqual(headers.map { $0.value }, ["one continued", "two"])
    }

    func testDetailRowsExposeEveryStoredHeaderAndInventNothing() {
        let sent = Date(timeIntervalSince1970: 1_700_000_000)
        let envelope = Envelope(
            subject: "Quarterly planning",
            from: [MailAddress(displayName: "Alex Morgan", address: "alex@example.com")],
            to: [MailAddress(displayName: "Kay", address: "kay@example.com")],
            cc: [MailAddress(displayName: nil, address: "cc@example.com")],
            replyTo: [MailAddress(displayName: nil, address: "desk@example.com")],
            internalDate: sent.addingTimeInterval(90),
            headerDate: sent,
            rfcMessageID: "<1@example.com>",
            inReplyTo: "<0@example.com>",
            references: ["<0@example.com>", "  "]
        )

        let rows = MessageHeaderPolicy.detailRows(for: envelope)
        XCTAssertEqual(
            rows.map(\.label),
            ["From", "Reply-To", "To", "Cc", "Sent", "Received", "Message-ID", "In-Reply-To", "References"]
        )
        XCTAssertEqual(rows.first?.value, "Alex Morgan <alex@example.com>")
        // An address without a display name is not padded into one.
        XCTAssertEqual(rows.first(where: { $0.label == "Cc" })?.value, "cc@example.com")
        // Blank references are dropped rather than shown as empty rows.
        XCTAssertEqual(rows.last?.value, "<0@example.com>")
    }

    func testAbsentHeadersGetNoRowAndDatesCollapseWhenTheyAgree() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let sender = MailAddress(displayName: "Alex", address: "alex@example.com")
        let envelope = Envelope(
            subject: "",
            from: [sender],
            to: [],
            cc: [],
            replyTo: [sender],
            internalDate: date,
            headerDate: date,
            rfcMessageID: nil,
            inReplyTo: nil,
            references: []
        )

        // One date fact, no empty recipient rows, no Reply-To that repeats
        // From, and never a Bcc or a security field the store never parsed.
        XCTAssertEqual(MessageHeaderPolicy.detailRows(for: envelope).map(\.label), ["From", "Date"])
    }

    func testRecipientSummaryCountsTheRestAndSpeaksItInFull() {
        let recipients = [
            MailAddress(displayName: "Kay", address: "kay@example.com"),
            MailAddress(displayName: nil, address: "b@example.com"),
            MailAddress(displayName: "Cee", address: "c@example.com"),
        ]
        XCTAssertEqual(MessageHeaderPolicy.summary(recipients), "Kay +2")
        XCTAssertEqual(MessageHeaderPolicy.spokenSummary(recipients), "Kay and 2 more")
        XCTAssertEqual(MessageHeaderPolicy.summary([recipients[1]]), "b@example.com")
        XCTAssertNil(MessageHeaderPolicy.summary([]))
        XCTAssertNil(MessageHeaderPolicy.spokenSummary([]))
    }

    func testBlankSubjectIsMarkedAsAPlaceholder() {
        XCTAssertEqual(MessageHeaderPolicy.subject("Lunch?").text, "Lunch?")
        XCTAssertFalse(MessageHeaderPolicy.subject("Lunch?").isPlaceholder)
        XCTAssertTrue(MessageHeaderPolicy.subject("   \n").isPlaceholder)
        XCTAssertEqual(
            MessageHeaderPolicy.subject("").text,
            MessageHeaderPolicy.noSubjectPlaceholder
        )
    }

    func testAttachmentLabelFallsBackToThePartSpecifier() {
        let named = AttachmentInfo(
            id: "2",
            filename: "notes.pdf",
            mimeType: "application/pdf",
            sizeEstimate: 24_000,
            contentID: nil
        )
        let unnamed = AttachmentInfo(
            id: "3",
            filename: "  ",
            mimeType: "application/octet-stream",
            sizeEstimate: nil,
            contentID: nil
        )
        XCTAssertEqual(MessageHeaderPolicy.attachmentName(named), "notes.pdf")
        XCTAssertEqual(MessageHeaderPolicy.attachmentName(unnamed), "3")
        XCTAssertNotNil(MessageHeaderPolicy.attachmentSize(named))
        XCTAssertNil(MessageHeaderPolicy.attachmentSize(unnamed))
    }

    func testMainWindowPolicyKeepsMinimumsAndResizability() {
        XCTAssertTrue(MainWindowLayoutPolicy.isResizable)
        XCTAssertGreaterThan(
            MainWindowLayoutPolicy.defaultContentSize.width,
            MainWindowLayoutPolicy.minimumContentSize.width
        )
        XCTAssertGreaterThan(
            MainWindowLayoutPolicy.defaultContentSize.height,
            MainWindowLayoutPolicy.minimumContentSize.height
        )
        let styleMask: NSWindow.StyleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView,
        ]
        XCTAssertTrue(styleMask.contains(.resizable))
    }

    @MainActor
    func testActionSettingsDefaults() {
        let suiteName = "Mailternal.ActionDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = ActionSettings(defaults: defaults)

        XCTAssertEqual(settings.leadingSwipe, [.toggleRead])
        XCTAssertEqual(settings.trailingSwipe, [.archive, .trash])
    }

    @MainActor
    func testActionSettingsClampsTrailingActions() {
        let suiteName = "Mailternal.ActionClamp.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("[\"archive\",\"trash\",\"toggleRead\",\"toggleFlag\"]", forKey: "mailternal.actions.swipe.trailing")

        let settings = ActionSettings(defaults: defaults)

        XCTAssertEqual(settings.trailingSwipe, [.archive, .trash, .toggleRead])
    }

    @MainActor
    func testActionSettingsDropsUnknownAndDuplicateActions() {
        let suiteName = "Mailternal.ActionNormalization.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            "[\"toggleFlag\",\"not-an-action\",\"toggleFlag\",\"archive\"]",
            forKey: "mailternal.actions.swipe.leading"
        )

        let settings = ActionSettings(defaults: defaults)

        XCTAssertEqual(settings.leadingSwipe, [.toggleFlag, .archive])
    }

    @MainActor
    func testActionSettingsRoundTripsPersistence() {
        let suiteName = "Mailternal.ActionRoundTrip.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = ActionSettings(defaults: defaults)
        settings.leadingSwipe = [.toggleFlag, .archive]
        settings.trailingSwipe = [.trash]

        XCTAssertEqual(
            defaults.string(forKey: "mailternal.actions.swipe.leading"),
            "[\"toggleFlag\",\"archive\"]"
        )
        XCTAssertEqual(
            ActionSettings(defaults: defaults).trailingSwipe,
            [.trash]
        )
    }

    func testActionSettingsPickerNoneCompactsRemainingActions() {
        XCTAssertEqual(
            ActionSettings.applying(
                nil,
                at: 1,
                to: [.archive, .trash, .toggleFlag],
                maxCount: 3
            ),
            [.archive, .toggleFlag]
        )
        XCTAssertEqual(
            ActionSettings.applying(
                .toggleFlag,
                at: 0,
                to: [.archive, .toggleFlag],
                maxCount: 3
            ),
            [.toggleFlag, .archive]
        )
    }
    func testSwipeActionFactoryUsesMailPalette() {
        XCTAssertTrue(SwipeActionKind.archive.backgroundColor.isEqual(NSColor.systemYellow))
        XCTAssertTrue(SwipeActionKind.trash.backgroundColor.isEqual(NSColor.systemRed))
        XCTAssertTrue(SwipeActionKind.toggleRead.backgroundColor.isEqual(NSColor.systemBlue))
        XCTAssertTrue(SwipeActionKind.toggleFlag.backgroundColor.isEqual(NSColor.systemOrange))
    }
    func testMessageContextMenuPolicyUsesMailOrderAndComposerTooltips() {
        let id = MessageID(rawValue: 1)
        let items = MessageContextMenuPolicy.items(
            selection: [id],
            isReadStates: [id: false],
            flagStates: [id: false],
            folders: [],
            current: nil
        )
        XCTAssertEqual(
            items.map(\.title),
            [
                "Open in New Window", "",
                "Reply", "Reply All", "Forward", "",
                "Mark as Read", "Flag", "Move to Junk", "Delete", "",
                "Archive", "Move to", "",
                "Copy Link", "Copy Subject",
            ]
        )
        XCTAssertTrue(items[0].isEnabled)
        XCTAssertFalse(items[2].isEnabled)
        XCTAssertEqual(items[2].toolTip, "Available with the composer")
        XCTAssertEqual(items[3].toolTip, "Available with the composer")
        XCTAssertEqual(items[4].toolTip, "Available with the composer")
    }

    func testMessageContextMenuPolicyPluralizesAndUsesMixedStateVerbs() {
        let ids: Set<MessageID> = [MessageID(rawValue: 1), MessageID(rawValue: 2), MessageID(rawValue: 3)]
        let items = MessageContextMenuPolicy.items(
            selection: ids,
            isReadStates: [MessageID(rawValue: 1): true, MessageID(rawValue: 2): false],
            flagStates: [
                MessageID(rawValue: 1): true,
                MessageID(rawValue: 2): true,
                MessageID(rawValue: 3): true,
            ],
            folders: [],
            current: nil
        )
        XCTAssertFalse(items[0].isEnabled)
        XCTAssertEqual(items[6].title, "Mark as Read")
        XCTAssertEqual(items[7].title, "Unflag")
        XCTAssertEqual(items[8].title, "Move 3 Messages to Junk")
        XCTAssertEqual(items[9].title, "Delete 3 Messages")
        XCTAssertEqual(items[11].title, "Archive 3 Messages")

        let single = MessageID(rawValue: 4)
        let singleItems = MessageContextMenuPolicy.items(
            selection: [single],
            isReadStates: [single: true],
            flagStates: [single: true],
            folders: [],
            current: nil
        )
        XCTAssertEqual(singleItems[6].title, "Mark as Unread")
        XCTAssertEqual(singleItems[7].title, "Unflag")
    }

    func testMessageContextMenuPolicyExcludesCurrentAndNestsFolderPaths() throws {
        func folder(_ id: Int64, _ name: String, _ path: String, _ role: FolderRole = .none) -> FolderSummary {
            FolderSummary(
                id: FolderID(rawValue: id),
                name: name,
                path: path,
                separator: "/",
                role: role,
                unreadCount: 0,
                totalCount: 0,
                backfill: .idle
            )
        }
        let current = folder(1, "Inbox", "Inbox", .inbox)
        let archive = folder(2, "Archive", "Archive", .archive)
        let projects = folder(3, "Projects", "Projects")
        let invoices = folder(4, "Invoices", "Projects/Invoices")
        let zeta = folder(5, "Zeta", "Zeta")
        let items = MessageContextMenuPolicy.items(
            selection: [MessageID(rawValue: 9)],
            isReadStates: [:],
            flagStates: [:],
            folders: [zeta, invoices, current, projects, archive],
            current: current.id
        )
        let move = items[12]
        XCTAssertEqual(move.title, "Move to")
        XCTAssertEqual(move.children.map(\.title), ["Archive", "Projects", "Zeta"])
        XCTAssertFalse(move.children.contains { $0.action == .moveTo(current.id) })
        let projectsItem = try XCTUnwrap(move.children.first { $0.title == "Projects" })
        XCTAssertEqual(projectsItem.children.map(\.title), ["Invoices"])
        XCTAssertEqual(projectsItem.children[0].action, .moveTo(invoices.id))
    }

    func testMessageToolbarPolicyOrdersItemsAndTracksSelectionState() {
        let first = MessageID(rawValue: 1)
        let second = MessageID(rawValue: 2)
        let selection: Set<MessageID> = [first, second]
        XCTAssertEqual(
            MessageToolbarPolicy.defaultItemIdentifiers,
            [.archive, .trash, .flag, .overflow]
        )
        XCTAssertEqual(
            MessageToolbarPolicy.allowedItemIdentifiers,
            MessageToolbarPolicy.defaultItemIdentifiers
        )
        let visible = MessageToolbarPolicy.visibleItems(
            selection: selection,
            flagStates: [first: true, second: true]
        )
        XCTAssertEqual(
            visible.map(\.identifier),
            [.archive, .trash, .flag]
        )
        XCTAssertEqual(visible.map(\.title), [
            "Archive 2 Messages",
            "Trash 2 Messages",
            "Unflag 2 Messages",
        ])
        XCTAssertEqual(visible.map(\.imageName), ["archivebox", "trash", "flag.slash"])
        XCTAssertTrue(visible.allSatisfy(\.isEnabled))

        let emptyVisible = MessageToolbarPolicy.visibleItems(selection: [], flagStates: [:])
        XCTAssertTrue(emptyVisible.allSatisfy { !$0.isEnabled })
    }

    func testMessageToolbarPolicyOrdersOverflowAndValidatesSelection() throws {
        let id = MessageID(rawValue: 9)
        let items = MessageToolbarPolicy.overflowItems(
            selection: [id],
            isReadStates: [id: false],
            flagStates: [id: false],
            folders: [],
            current: nil
        )
        XCTAssertTrue(items[0].isEnabled)
        XCTAssertFalse(items[1].isEnabled)
        XCTAssertFalse(items[2].isEnabled)
        XCTAssertTrue(items[3].isEnabled)
        XCTAssertTrue(items[5].isEnabled)
        XCTAssertTrue(items[6].isEnabled)
        XCTAssertTrue(items[7].isEnabled)
        XCTAssertEqual(items.map(\.title), [
            "Mark as Read",
            "Move to Junk",
            "Move to",
            "Open in New Window",
            "",
            "Copy Link",
            "Copy Subject",
            "View Raw Source",
        ])
        XCTAssertEqual(items[0].action, .markRead)
        XCTAssertEqual(items[7].action, .viewRawSource)

        let empty = MessageToolbarPolicy.overflowItems(
            selection: [],
            isReadStates: [:],
            flagStates: [:],
            folders: [],
            current: nil
        )
        XCTAssertEqual(empty.map(\.title), items.map(\.title))
        XCTAssertTrue(empty.allSatisfy { !$0.isEnabled || $0.isSeparator })
        XCTAssertFalse(empty[3].isEnabled)
        XCTAssertFalse(empty[7].isEnabled)
    }

    func testMessageLinkPasteboardRoundTripsJSONPayload() {
        let links = [
            "mailternal://open/v1/account/00000000-0000-4000-8000-000000000002/folder/path/SU5CT1g/message/1788195160/134810",
            "mailternal://open/v1/account/00000000-0000-4000-8000-000000000002/folder/path/QXJjaGl2ZQ",
        ]
        let decoded = MessageLinkPasteboard.decode(MessageLinkPasteboard.encode(links))
        XCTAssertEqual(decoded, links)
    }

    func testMessageLinkPasteboardRoundTripsUnprefetchedMessageID() {
        let id = MessageID(rawValue: 94_002)
        let payload = MessageLinkPasteboard.encode([MessageLinkPasteboard.encodeMessageID(id)])
        XCTAssertEqual(
            MessageLinkPasteboard.decode(payload).flatMap { $0.first }.flatMap(MessageLinkPasteboard.decodeMessageID),
            id
        )
    }

    func testMessageReaderStatePolicyFormatsFullMailboxSelectionCount() {
        XCTAssertNil(MessageReaderStatePolicy.emptyStateTitle(selectionCount: 0))
        XCTAssertNil(MessageReaderStatePolicy.emptyStateTitle(selectionCount: 1))
        XCTAssertEqual(
            MessageReaderStatePolicy.emptyStateTitle(selectionCount: 3),
            "3 Messages Selected"
        )
        XCTAssertEqual(
            MessageReaderStatePolicy.emptyStateTitle(selectionCount: 94_002),
            "94,002 Messages Selected"
        )
        XCTAssertEqual(
            MessageReaderStatePolicy.emptyStateDetail(selectionCount: 3),
            "Choose one message to read it."
        )
    }
}
