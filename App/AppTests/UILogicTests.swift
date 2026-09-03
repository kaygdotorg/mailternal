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
    func testEmailReadingOverridePolicyResetsWhenDetailChanges() {
        let first = MessageID(rawValue: 1)
        let second = MessageID(rawValue: 2)
        XCTAssertFalse(EmailReadingOverridePolicy.resetsOverride(oldID: first, newID: first))
        XCTAssertTrue(EmailReadingOverridePolicy.resetsOverride(oldID: first, newID: second))
        XCTAssertTrue(EmailReadingOverridePolicy.resetsOverride(oldID: first, newID: nil))
        XCTAssertTrue(EmailReadingOverridePolicy.resetsOverride(oldID: nil, newID: first))
    }

    func testEmailReadingOverridePolicyTogglesFromGlobalDarkToOriginal() {
        XCTAssertEqual(EmailReadingOverridePolicy.next(effective: .dark), .original)
        XCTAssertEqual(EmailReadingOverridePolicy.next(effective: .original), .dark)
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
    func testAppearanceDefaultsToFrostedBlurAtEightyPercent() {
        let suiteName = "Mailternal.AppearanceDefaultsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppearanceSettings(defaults: defaults)

        XCTAssertEqual(settings.backdropStyle, .frostedBlur)
        XCTAssertFalse(settings.showsSenderIcons)
        XCTAssertEqual(settings.backgroundOpacity, 0.80)
        XCTAssertEqual(
            defaults.string(forKey: "mailternal.appearance.backdropStyle"),
            WindowBackdropStyle.frostedBlur.rawValue
        )
        XCTAssertNil(defaults.object(forKey: "mailternal.appearance.usesLiquidGlass"))
        let plan = WindowBackdropPlan(
            style: settings.backdropStyle,
            opacity: settings.backgroundOpacity,
            reduceTransparency: false,
            isFullScreen: false
        )
        XCTAssertEqual(plan.treatment, .blur)
        XCTAssertEqual(plan.fillOpacity, 0.80, accuracy: 0.0001)
        XCTAssertEqual(defaults.integer(forKey: "mailternal.appearance.defaultsVersion"), 2)
    }

    @MainActor
    func testAppearanceMigratesUnmarkedFullOpacityExactlyOnce() {
        let suiteName = "Mailternal.AppearanceOpacityMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(1.0, forKey: "mailternal.appearance.opacity")

        let migrated = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(migrated.backgroundOpacity, 0.80)
        XCTAssertEqual(defaults.double(forKey: "mailternal.appearance.opacity"), 0.80)
        XCTAssertEqual(defaults.integer(forKey: "mailternal.appearance.defaultsVersion"), 2)

        defaults.set(1.0, forKey: "mailternal.appearance.opacity")
        let current = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(current.backgroundOpacity, 1.0)
    }

    @MainActor
    func testAppearanceMigratesLegacyLiquidGlassChoiceExactlyOnce() {
        for legacyValue in [false, true] {
            let suiteName = "Mailternal.AppearanceStyleMigrationTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(legacyValue, forKey: "mailternal.appearance.usesLiquidGlass")
            let expectedStyle: WindowBackdropStyle = legacyValue ? .regularGlass : .frostedBlur

            let migrated = AppearanceSettings(defaults: defaults)
            XCTAssertEqual(migrated.backdropStyle, expectedStyle)
            XCTAssertEqual(
                defaults.string(forKey: "mailternal.appearance.backdropStyle"),
                expectedStyle.rawValue
            )
            XCTAssertNil(defaults.object(forKey: "mailternal.appearance.usesLiquidGlass"))
            XCTAssertEqual(defaults.integer(forKey: "mailternal.appearance.defaultsVersion"), 2)

            // A stale legacy value written after migration cannot change the
            // already migrated choice: version 2 and the new key win.
            defaults.set(!legacyValue, forKey: "mailternal.appearance.usesLiquidGlass")
            let current = AppearanceSettings(defaults: defaults)
            XCTAssertEqual(current.backdropStyle, expectedStyle)
            XCTAssertNil(defaults.object(forKey: "mailternal.appearance.usesLiquidGlass"))
        }
    }

    @MainActor
    func testAppearanceSenderIconsDefaultsPersistsAndReloads() {
        let suiteName = "Mailternal.AppearanceSenderIconsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppearanceSettings(defaults: defaults)
        XCTAssertFalse(settings.showsSenderIcons)
        settings.showsSenderIcons = true
        XCTAssertTrue(defaults.bool(forKey: "mailternal.appearance.showsSenderIcons"))
        XCTAssertTrue(AppearanceSettings(defaults: defaults).showsSenderIcons)
    }

    @MainActor
    func testAppearanceMigratesLegacyOpaqueToShippingDefault() {
        let suiteName = "Mailternal.AppearanceLegacyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("opaque", forKey: "mailternal.appearance.backdrop")
        defaults.set(0.62, forKey: "mailternal.appearance.opacity")

        let settings = AppearanceSettings(defaults: defaults)

        XCTAssertEqual(settings.backdropStyle, .frostedBlur)
        XCTAssertEqual(settings.backgroundOpacity, 0.62)
        XCTAssertNil(defaults.string(forKey: "mailternal.appearance.backdrop"))
        XCTAssertEqual(
            defaults.string(forKey: "mailternal.appearance.backdropStyle"),
            WindowBackdropStyle.frostedBlur.rawValue
        )
        XCTAssertEqual(defaults.integer(forKey: "mailternal.appearance.defaultsVersion"), 2)
    }

    @MainActor
    func testAppearancePersistsEachBackdropStyleAndOpacity() {
        let suiteName = "Mailternal.AppearanceStylePersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppearanceSettings(defaults: defaults)
        for style in WindowBackdropStyle.allCases {
            settings.backdropStyle = style
            XCTAssertEqual(
                defaults.string(forKey: "mailternal.appearance.backdropStyle"),
                style.rawValue
            )
            XCTAssertEqual(AppearanceSettings(defaults: defaults).backdropStyle, style)
        }
    }

    func testWindowBackdropPlanMatrixResolvesMutuallyExclusiveTreatments() {
        let opacities = [0.0, 0.5, 0.8, 1.0]
        for style in WindowBackdropStyle.allCases {
            for opacity in opacities {
                let plan = WindowBackdropPlan(
                    style: style,
                    opacity: opacity,
                    reduceTransparency: false,
                    isFullScreen: false
                )
                let expectedTreatment: WindowBackdropTreatment =
                    opacity == 1
                        ? .opaque
                        : style == .frostedBlur ? .blur : .glass
                XCTAssertEqual(plan.style, style)
                XCTAssertEqual(plan.treatment, expectedTreatment)
                XCTAssertEqual(plan.opacity, opacity)
                XCTAssertEqual(
                    plan.fillOpacity,
                    expectedTreatment == .glass ? 0 : opacity,
                    accuracy: 0.0001
                )
                XCTAssertEqual(
                    plan.glassTintOpacity,
                    expectedTreatment == .glass ? opacity : 0,
                    accuracy: 0.0001
                )
            }
        }
    }

    func testWindowBackdropPlanForcesOpaqueForAccessibilityAndFullscreen() {
        let fallbackInputs: [(Bool, Bool)] = [(true, false), (false, true)]
        for (reduceTransparency, isFullScreen) in fallbackInputs {
            for style in WindowBackdropStyle.allCases {
                for opacity in [0.0, 0.5, 0.8, 1.0] {
                    let plan = WindowBackdropPlan(
                        style: style,
                        opacity: opacity,
                        reduceTransparency: reduceTransparency,
                        isFullScreen: isFullScreen
                    )
                    XCTAssertEqual(plan.style, style)
                    XCTAssertEqual(plan.opacity, 1)
                    XCTAssertEqual(plan.treatment, .opaque)
                    XCTAssertEqual(plan.fillOpacity, 1)
                    XCTAssertEqual(plan.glassTintOpacity, 0)
                }
            }
        }
    }

    @MainActor
    func testWindowBackdropViewAppliesPlanToWindowAndLayers() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let backdrop = WindowBackdropView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = backdrop
        defer {
            backdrop.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }

        // Start with the frosted path so the lazily-created effect view is
        // present while the glass paths verify that it is hidden.
        for style in [WindowBackdropStyle.frostedBlur, .clearGlass, .regularGlass] {
            for opacity in [0.0, 0.5, 0.8, 1.0] {
                let plan = WindowBackdropPlan(
                    style: style,
                    opacity: opacity,
                    reduceTransparency: false,
                    isFullScreen: false
                )
                backdrop.apply(
                    style: style,
                    opacity: opacity,
                    reduceTransparency: false
                )

                XCTAssertEqual(window.isOpaque, plan.treatment == .opaque)
                let effectViews = backdrop.subviews.compactMap { $0 as? NSVisualEffectView }
                XCTAssertEqual(effectViews.count, 1)
                guard let effect = effectViews.first else { continue }
                XCTAssertEqual(effect.isHidden, plan.treatment != .blur)
                XCTAssertEqual(effect.subviews.count, 1)
                guard let tint = effect.subviews.first else {
                    XCTFail("Expected the blur tint to be nested in the effect view")
                    continue
                }
                XCTAssertTrue(tint.superview === effect)
                let tintAlpha = tint.layer?.backgroundColor?.alpha ?? 0
                XCTAssertEqual(Double(tintAlpha), plan.fillOpacity, accuracy: 0.001)
                if plan.treatment != .opaque {
                    XCTAssertFalse(backdrop.layer?.isOpaque ?? true)
                }
            }
        }
    }

    func testWindowBackdropStylesAreSortedAndLabeled() {
        XCTAssertEqual(
            WindowBackdropStyle.allCases.map(\.rawValue),
            ["clearGlass", "frostedBlur", "regularGlass"]
        )
        XCTAssertEqual(
            WindowBackdropStyle.allCases.map(\.label),
            ["Clear glass", "Frosted blur", "Regular glass"]
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
        XCTAssertTrue(defaults.bool(forKey: "mailternal.appearance.opacity-user-written"))
        XCTAssertEqual(AppearanceSettings(defaults: defaults).backgroundOpacity, 0)
    }

    func testWindowBackdropKeepsTreatmentDownToZeroOpacity() {
        for style in WindowBackdropStyle.allCases {
            XCTAssertEqual(
                WindowBackdropPlan(
                    style: style,
                    opacity: 0,
                    reduceTransparency: false,
                    isFullScreen: false
                ).treatment,
                style == .frostedBlur ? .blur : .glass
            )
            XCTAssertEqual(
                WindowBackdropPlan(
                    style: style,
                    opacity: 0.99,
                    reduceTransparency: false,
                    isFullScreen: false
                ).treatment,
                style == .frostedBlur ? .blur : .glass
            )
        }
        for style in WindowBackdropStyle.allCases {
            XCTAssertEqual(
                WindowBackdropPlan(
                    style: style,
                    opacity: 1,
                    reduceTransparency: false,
                    isFullScreen: false
                ).treatment,
                .opaque
            )
        }
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

    func testMessageListRowHeightsMatchMeasuredContentAtEveryLineCount() {
        let heights = MessageListLayout.lineRange.map { MessageListLayout.rowHeight(for: $0) }
        // The cell's fixed 10-point top/bottom insets and 18-point text
        // baseline step produce these measured heights for one through six
        // visible lines.
        XCTAssertEqual(heights, [36, 54, 72, 90, 108, 126])
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

    func testPaneHeaderInsetsAreIndependentOfSafeArea() {
        let safeAreas = [CGFloat(0), 28, 52, 80]

        for safeAreaTop in safeAreas {
            XCTAssertEqual(
                PaneHeaderInsetPolicy.topInset(for: .sidebar, safeAreaTop: safeAreaTop),
                PaneHeaderInsetPolicy.sidebarTopInset
            )
            XCTAssertEqual(
                PaneHeaderInsetPolicy.topInset(for: .messageList, safeAreaTop: safeAreaTop),
                PaneHeaderInsetPolicy.messageListTopInset
            )
            XCTAssertEqual(
                MailWindowDissolvePolicy.messageList.restDepth(safeAreaTop: safeAreaTop),
                MailWindowDissolvePolicy.messageList.topReach
            )
            XCTAssertEqual(
                MessageViewerLayoutPolicy.readerTopInset(safeAreaTop: safeAreaTop),
                MessageViewerLayoutPolicy.readerTopInset()
            )
        }

        XCTAssertEqual(PaneHeaderInsetPolicy.sidebarTopInset, 52)
        XCTAssertEqual(PaneHeaderInsetPolicy.messageListTopInset, 52)
        // The sidebar List keeps its safe-area layout; the header adds air
        // below the titlebar band and above the first row. The scroll view
        // itself is never inset.
        XCTAssertEqual(PaneHeaderInsetPolicy.sidebarHeaderPadding, 12)
        XCTAssertEqual(PaneHeaderInsetPolicy.sidebarHeaderBottomPadding, 10)
    }

    func testSettingsDissolvePolicyUsesMeasuredH1OriginAndNoBottomRamp() {
        let settings = MailWindowDissolvePolicy.settings

        // The settings window has no toolbar: its H1 sits close to the top.
        XCTAssertEqual(PaneHeaderInsetPolicy.topInset(for: .settings), 46)
        XCTAssertEqual(PaneHeaderInsetPolicy.settingsHeaderTopPadding, 46)
        XCTAssertEqual(PaneHeaderInsetPolicy.headerTopPadding, 64)
        XCTAssertEqual(PaneHeaderInsetPolicy.settingsTitleBottomPadding, 12)
        XCTAssertEqual(settings.topOrigin, .windowTop)
        XCTAssertEqual(settings.topReach, 24)
        XCTAssertNil(settings.bottomReach)
        XCTAssertEqual(settings.bottomReservedHeight, 0)
        XCTAssertFalse(settings.hasBottomRamp)
        XCTAssertEqual(settings.restDepth(safeAreaTop: 52), 24)

        let measured = settings.withTopOrigin(96)
        XCTAssertEqual(measured.topOrigin, .measured(96))
        XCTAssertEqual(measured.restDepth(safeAreaTop: 52), 120)
    }

    func testSidebarDissolveEndsBeforeAccountHeader() {
        let sidebar = MailWindowDissolvePolicy.sidebar
        let height: CGFloat = 720
        let safeAreaTop: CGFloat = 52
        let stops = sidebar.stops(for: height, safeAreaTop: safeAreaTop)
        let topEnd = sidebar.topOrigin.depth(safeAreaTop: safeAreaTop) + sidebar.topReach

        // The ramp starts just below the traffic-light band, is short, and is
        // fully opaque before the account title's cap height (title top =
        // band + header padding; a 20pt font's cap sits ~5pt lower).
        XCTAssertEqual(sidebar.topOrigin, .titlebarSafeArea)
        XCTAssertEqual(sidebar.topReach, PaneHeaderInsetPolicy.sidebarDissolveReach)
        XCTAssertLessThanOrEqual(
            topEnd,
            safeAreaTop + PaneHeaderInsetPolicy.sidebarHeaderPadding + PaneHeaderInsetPolicy.sidebarDissolveGuard
        )
        XCTAssertGreaterThan(
            (stops.first { $0.alpha > 0 }?.location ?? 0) * height,
            safeAreaTop
        )
    }

    func testMailWindowDissolveDualEdgePoliciesUseFullSurfaceDimensions() {
        let height: CGFloat = 720
        let safeAreaTop: CGFloat = 52
        let sidebar = MailWindowDissolvePolicy.sidebar
        let messageList = MailWindowDissolvePolicy.messageList
        let sidebarStops = sidebar.stops(for: height, safeAreaTop: safeAreaTop)
        let messageStops = messageList.stops(for: height, safeAreaTop: safeAreaTop)

        XCTAssertEqual(sidebar.topReach, 20)
        XCTAssertEqual(sidebar.bottomReach, 48)
        XCTAssertEqual(sidebar.bottomReservedHeight, 0)
        XCTAssertEqual(messageList.topReach, MailWindowDissolvePolicy.messageListTopReach)
        XCTAssertEqual(messageList.bottomReach, 48)
        XCTAssertEqual(messageList.bottomReservedHeight, 0)
        XCTAssertTrue(sidebar.hasBottomRamp)
        XCTAssertTrue(messageList.hasBottomRamp)

        // The sidebar holds a clear plateau across the measured band: a stop at
        // the window top and a second one at the boundary, with the first ink
        // below it. The message list has one clear stop, at the window top.
        XCTAssertEqual(sidebar.topOrigin, .titlebarSafeArea)
        XCTAssertEqual(messageList.topOrigin, .windowTop)
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

    func testReaderTopInsetIsFixedAcrossSafeAreaChanges() {
        let inset = MessageViewerLayoutPolicy.readerTopInset()
        XCTAssertEqual(inset, MailWindowTopDissolvePolicy.titlebarDepth + MessageViewerLayoutPolicy.fadeGuard)

        for safeAreaTop in [CGFloat(0), 28, 52, 80] {
            XCTAssertEqual(
                MessageViewerLayoutPolicy.readerTopInset(safeAreaTop: safeAreaTop),
                inset
            )
            XCTAssertEqual(
                MailWindowDissolvePolicy.viewer.alpha(
                    atDepth: inset,
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
        XCTAssertEqual(headers.map(\.keyCopyText), ["Received", "Message-ID", "Content-Type"])
        XCTAssertEqual(
            headers.map(\.valueCopyText),
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

    func testRawHeaderItemCopyPayloadsSeparateKeyAndValue() {
        let item = MessageHeaderPolicy.HeaderItem(
            id: 0,
            name: "X-Thing",
            value: "first line second line"
        )
        let emptyValue = MessageHeaderPolicy.HeaderItem(
            id: 1,
            name: "X-Empty",
            value: ""
        )

        XCTAssertEqual(item.keyCopyText, "X-Thing")
        XCTAssertEqual(item.valueCopyText, "first line second line")
        XCTAssertEqual(item.copyText, "X-Thing: first line second line")
        XCTAssertEqual(emptyValue.keyCopyText, "X-Empty")
        XCTAssertEqual(emptyValue.valueCopyText, "")
        XCTAssertEqual(emptyValue.copyText, "X-Empty:")
    }
    
    func testQRCodePolicyUsesExactCopyPayloadAndRejectsEmptyText() {
        XCTAssertEqual(
            QRCodePolicy.payload(for: "ada@example.com"),
            "ada@example.com"
        )
        XCTAssertEqual(
            QRCodePolicy.payload(for: " first line second line "),
            " first line second line "
        )
        XCTAssertNil(QRCodePolicy.payload(for: ""))
        XCTAssertFalse(QRCodePolicy.canEncode(""))
    }

    func testQRCodePolicyUsesLevelMByteLimit() {
        XCTAssertEqual(QRCodePolicy.errorCorrectionLevel, "M")
        XCTAssertEqual(QRCodePolicy.maxPayloadBytes, 2_953)
        XCTAssertEqual(QRCodePolicy.renderedSide, 176)
        let maximum = String(repeating: "a", count: QRCodePolicy.maxPayloadBytes)
        let overLimit = maximum + "b"
        XCTAssertTrue(QRCodePolicy.canEncode(maximum))
        XCTAssertFalse(QRCodePolicy.canEncode(overLimit))
        XCTAssertTrue(QRCodePolicy.canEncode(String(repeating: "é", count: QRCodePolicy.maxPayloadBytes / 2)))
        XCTAssertFalse(QRCodePolicy.canEncode(String(repeating: "é", count: QRCodePolicy.maxPayloadBytes / 2 + 1)))
    }

    func testQRCodeGeneratorHandlesAddressAndEmptyPayload() {
        XCTAssertNotNil(QRCodeRenderer.outputImage(for: "ada@example.com"))
        XCTAssertNotNil(QRCodeRenderer.image(for: "ada@example.com"))
        XCTAssertNil(QRCodeRenderer.outputImage(for: ""))
        XCTAssertNil(QRCodeRenderer.image(for: ""))
    }

    func testQRCodePolicyExplainsDisabledPayloads() {
        XCTAssertTrue(QRCodePolicy.menuHelp(for: "").contains("no text"))
        let overLimit = String(repeating: "a", count: QRCodePolicy.maxPayloadBytes + 1)
        XCTAssertTrue(QRCodePolicy.menuHelp(for: overLimit).contains("2,953"))
    }



    func testDetailHeadersProvideImmediateSourceFallbackFromEnvelope() {
        let internalDate = Date(timeIntervalSince1970: 1_757_000_000)
        let envelope = Envelope(
            subject: "Subject",
            from: [MailAddress(displayName: "Ada Lovelace", address: "ada@x")],
            to: [MailAddress(displayName: "Grace Hopper", address: "grace@x")],
            cc: [],
            replyTo: [],
            internalDate: internalDate,
            headerDate: internalDate,
            rfcMessageID: "<abc@example.com>",
            inReplyTo: nil,
            references: ["<root@example.com>"]
        )

        let headers = MessageHeaderPolicy.detailHeaders(for: envelope)

        XCTAssertEqual(headers.map(\.name), ["From", "To", "Date", "Message-ID", "References"])
        XCTAssertEqual(Array(headers.map(\.copyText).prefix(2)), [
            "From: Ada Lovelace <ada@x>",
            "To: Grace Hopper <grace@x>",
        ])
        XCTAssertEqual(
            MessageHeaderPolicy.rawHeaderBlock(from: headers),
            headers.map(\.copyText).joined(separator: "\n")
        )
    }


    func testEnvelopeIdentityPolicyUsesMonogramsAndAddressCopyPayloads() {
        let named = MailAddress(displayName: "Ada Lovelace", address: "ada@x")
        let bare = MailAddress(displayName: nil, address: "grace@x")

        XCTAssertEqual(MessageHeaderPolicy.initials(for: named), "AL")
        XCTAssertEqual(MessageHeaderPolicy.initials(for: bare), "G")
        XCTAssertEqual(MessageHeaderPolicy.copyPayload(for: named), "ada@x")
    }

    func testEnvelopeRecipientPolicyKeepsPrimaryAddressAndCollapsesRemainder() {
        let recipients = [
            MailAddress(displayName: "Ada Lovelace", address: "ada@x"),
            MailAddress(displayName: "Grace Hopper", address: "grace@x"),
            MailAddress(displayName: nil, address: "third@x"),
        ]

        let collapsed = try! XCTUnwrap(MessageHeaderPolicy.collapseRecipients(recipients))
        XCTAssertEqual(collapsed.first.address, "ada@x")
        XCTAssertEqual(collapsed.additionalCount, 2)
        XCTAssertEqual(collapsed.summary, "Ada Lovelace +2")
        XCTAssertNil(MessageHeaderPolicy.collapseRecipients([]))
    }

    func testDeliveredDateUsesTopmostReceivedHeaderAndEachHeaderCopiesUnfoldedText() {
        let raw = """
        Received: from first.example; Tue, 2 Sep 2026 12:00:00 +0000
        Received: from second.example; Tue, 2 Sep 2026 11:00:00 +0000
        X-Note: first line
         second line

        Body
        """
        let headers = MessageHeaderPolicy.rawHeaders(from: raw)
        let date = try! XCTUnwrap(MessageHeaderPolicy.deliveredDate(from: headers))
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 9
        components.day = 2
        components.hour = 12
        components.minute = 0
        components.second = 0
        XCTAssertEqual(date, try! XCTUnwrap(components.calendar?.date(from: components)))
        XCTAssertEqual(headers.map(\.copyText), [
            "Received: from first.example; Tue, 2 Sep 2026 12:00:00 +0000",
            "Received: from second.example; Tue, 2 Sep 2026 11:00:00 +0000",
            "X-Note: first line second line",
        ])
        XCTAssertEqual(headers.map(\.id), [0, 1, 2])
    }

    func testRawHeaderPolicyUnescapesFacadeValuesAndPreservesEncodedWords() {
        let raw = """
        Message-ID: &lt;li@example.cn&gt;
        X-Display: &quot;Mail &amp; Team&quot;
        Subject: =?UTF-8?B?5L2g5aW9?=

        body
        """

        let headers = MessageHeaderPolicy.rawHeaders(from: raw)

        XCTAssertEqual(
            headers.map { $0.value },
            [
                "<li@example.cn>",
                "\"Mail & Team\"",
                "=?UTF-8?B?5L2g5aW9?=",
            ]
        )
        XCTAssertEqual(
            MessageHeaderPolicy.rawHeaderBlock(from: raw),
            "Message-ID: <li@example.cn>\n"
                + "X-Display: \"Mail & Team\"\n"
                + "Subject: =?UTF-8?B?5L2g5aW9?="
        )
    }

    func testRawHeaderPolicyAcceptsLFAndMissingBlankLine() {
        let raw = "X-First: one\n\tcontinued\nX-Second: two"
        let headers = MessageHeaderPolicy.rawHeaders(from: raw)

        XCTAssertEqual(headers.map { $0.name }, ["X-First", "X-Second"])
        XCTAssertEqual(headers.map { $0.value }, ["one continued", "two"])
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

    func testMessageToolbarPolicyGroupsKeepAllActionsInOneCapsule() {
        XCTAssertEqual(
            MessageToolbarPolicy.groups,
            [.messageActions]
        )
        XCTAssertEqual(MessageToolbarPolicy.defaultGroupIdentifiers, MessageToolbarPolicy.groups)
        XCTAssertEqual(MessageToolbarPolicy.allowedGroupIdentifiers, MessageToolbarPolicy.groups)
        XCTAssertEqual(
            MessageToolbarPolicy.itemIdentifiers(in: .messageActions),
            [.archive, .trash, .flag, .source, .colorScheme, .overflow]
        )
        XCTAssertEqual(
            MessageToolbarPolicy.defaultItemIdentifiers,
            MessageToolbarPolicy.groups.flatMap { $0.itemIdentifiers }
        )
    }
    func testMessageToolbarPolicyKeepsSourceOnStateWithinItsGroup() {
        let id = MessageID(rawValue: 1)
        let source = MessageToolbarPolicy.visibleItems(
            selection: [id],
            flagStates: [:],
            isShowingRawSource: true
        ).first { $0.identifier == .source }
        XCTAssertTrue(source?.isOn == true)
        XCTAssertTrue(source?.isEnabled == true)
    }


    func testMessageToolbarPolicyOrdersItemsAndTracksSelectionState() {
        let first = MessageID(rawValue: 1)
        let second = MessageID(rawValue: 2)
        let selection: Set<MessageID> = [first, second]
        XCTAssertEqual(
            MessageToolbarPolicy.defaultItemIdentifiers,
            [.archive, .trash, .flag, .source, .colorScheme, .overflow]
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
            [.archive, .trash, .flag, .source, .colorScheme]
        )
        XCTAssertEqual(visible.map(\.title), [
            "Archive 2 Messages",
            "Trash 2 Messages",
            "Unflag 2 Messages",
            "Source",
            "Email Colour Scheme",
        ])
        XCTAssertEqual(
            visible.map(\.imageName),
            ["archivebox", "trash", "flag.slash", "chevron.left.forwardslash.chevron.right", "sun.max"]
        )
        XCTAssertTrue(visible[0..<3].allSatisfy(\.isEnabled))
        XCTAssertTrue(visible[3...].allSatisfy { !$0.isEnabled })

        let emptyVisible = MessageToolbarPolicy.visibleItems(selection: [], flagStates: [:])
        XCTAssertTrue(emptyVisible.allSatisfy { !$0.isEnabled })
    }

    func testMessageToolbarPolicyColourSchemeSymbolFollowsEffectiveMode() {
        let id = MessageID(rawValue: 1)
        let original = MessageToolbarPolicy.visibleItems(
            selection: [id],
            flagStates: [:],
            effectiveEmailReadingMode: .original
        )
        let dark = MessageToolbarPolicy.visibleItems(
            selection: [id],
            flagStates: [:],
            effectiveEmailReadingMode: .dark
        )
        XCTAssertEqual(original.first { $0.identifier == .colorScheme }?.imageName, "sun.max")
        XCTAssertEqual(dark.first { $0.identifier == .colorScheme }?.imageName, "moon")
        XCTAssertTrue(original.first { $0.identifier == .source }?.isEnabled == true)
        XCTAssertFalse(original.first { $0.identifier == .source }?.isOn == true)
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
        XCTAssertTrue(items[8].isEnabled)
        XCTAssertEqual(items.map(\.title), [
            "Mark as Read",
            "Move to Junk",
            "Move to",
            "Open in New Window",
            "",
            "Copy Link",
            "Copy Subject",
            "Source",
            "Email Colour Scheme",
        ])
        XCTAssertEqual(items[0].action, .markRead)
        XCTAssertEqual(items[7].action, .viewRawSource)
        XCTAssertEqual(items[8].action, .toggleEmailReadingOverride)

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
        XCTAssertFalse(empty[8].isEnabled)
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
