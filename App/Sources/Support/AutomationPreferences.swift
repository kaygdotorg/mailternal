import Foundation

/// The single typed seam between native settings models and automation clients.
///
/// Automation values are rendered as strings at the command boundary, but are
/// decoded into the existing enums, booleans, numbers, colors, and gesture
/// arrays before they reach the observable models. Unknown keys never fall
/// through to UserDefaults.
enum AutomationPreferences {
    /// JSON for one swipe-picker edit. `action` is present and nullable:
    /// `{"index":1,"action":"archive"}` inserts/moves an action at slot 1,
    /// while `{"index":1,"action":null}` removes the action at that slot.
    /// Full-array JSON remains supported for automation clients.
    struct SwipeActionEditPayload: Codable, Equatable {
        let index: Int
        let action: String?

        init(index: Int, action: SwipeActionKind?) {
            self.index = index
            self.action = action?.rawValue
        }

        private enum CodingKeys: String, CodingKey {
            case index
            case action
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            index = try container.decode(Int.self, forKey: .index)
            guard container.contains(.action) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.action,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Swipe edit payload must include a nullable action."
                    )
                )
            }
            action = try container.decodeIfPresent(String.self, forKey: .action)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(index, forKey: .index)
            try container.encode(action, forKey: .action)
        }
    }

    static func encodedSwipeActionEdit(
        index: Int,
        action: SwipeActionKind?
    ) throws -> String {
        do {
            let data = try JSONEncoder().encode(
                SwipeActionEditPayload(index: index, action: action)
            )
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw Error.encodingFailed("actions.swipe", underlying: error)
        }
    }
    enum Keys {
        static let mode = "mailternal.appearance.mode"
        static let emailReadingMode = "mailternal.appearance.email-reading"
        static let tabStyle = "mailternal.appearance.tab-style"
        static let showsSenderIcons = "mailternal.appearance.showsSenderIcons"
        static let backgroundOpacity = "mailternal.appearance.opacity"
        static let backdropStyle = "mailternal.appearance.backdropStyle"
        static let messageListLines = "mailternal.appearance.message-list-lines"
        static let accent = "mailternal.appearance.accent"
        static let leadingSwipe = "mailternal.actions.swipe.leading"
        static let trailingSwipe = "mailternal.actions.swipe.trailing"
    }

    static let knownKeys = [
        Keys.mode,
        Keys.emailReadingMode,
        Keys.tabStyle,
        Keys.showsSenderIcons,
        Keys.backgroundOpacity,
        Keys.backdropStyle,
        Keys.messageListLines,
        Keys.accent,
        Keys.leadingSwipe,
        Keys.trailingSwipe
    ]

    static func supports(_ key: String) -> Bool {
        knownKeys.contains(key)
    }

    @MainActor
    static func snapshot(
        appearance: AppearanceSettings,
        actions: ActionSettings
    ) -> [String: String] {
        Dictionary(uniqueKeysWithValues: knownKeys.compactMap { key in
            value(for: key, appearance: appearance, actions: actions).map { (key, $0) }
        })
    }

    @MainActor
    static func value(
        for key: String,
        appearance: AppearanceSettings,
        actions: ActionSettings
    ) -> String? {
        switch key {
        case Keys.mode:
            appearance.mode.rawValue
        case Keys.emailReadingMode:
            appearance.emailReadingMode.rawValue
        case Keys.tabStyle:
            appearance.tabStyle.rawValue
        case Keys.showsSenderIcons:
            appearance.showsSenderIcons ? "true" : "false"
        case Keys.backgroundOpacity:
            String(appearance.backgroundOpacity)
        case Keys.backdropStyle:
            appearance.backdropStyle.rawValue
        case Keys.messageListLines:
            String(appearance.messageListLines)
        case Keys.accent:
            appearance.accent.accentOverride.map(encodeAccent) ?? "system"
        case Keys.leadingSwipe:
            actions.encodedSwipeActions(for: .leading)
        case Keys.trailingSwipe:
            actions.encodedSwipeActions(for: .trailing)
        default:
            nil
        }
    }

    @MainActor
    static func apply(
        key: String,
        value: String?,
        appearance: AppearanceSettings,
        actions: ActionSettings
    ) throws {
        switch key {
        case Keys.mode:
            guard let value else {
                appearance.resetMode()
                return
            }
            guard let mode = AppearanceMode(rawValue: value) else { throw Error.invalidValue(key) }
            appearance.mode = mode
        case Keys.emailReadingMode:
            guard let value else {
                appearance.resetEmailReadingMode()
                return
            }
            guard let mode = EmailReadingMode(rawValue: value) else { throw Error.invalidValue(key) }
            appearance.emailReadingMode = mode
        case Keys.tabStyle:
            guard let value else {
                appearance.resetTabStyle()
                return
            }
            guard let style = ReaderTabStyle(rawValue: value) else { throw Error.invalidValue(key) }
            appearance.tabStyle = style
        case Keys.showsSenderIcons:
            guard let value else {
                appearance.resetShowsSenderIcons()
                return
            }
            guard let enabled = parseBool(value) else { throw Error.invalidValue(key) }
            appearance.showsSenderIcons = enabled
        case Keys.backgroundOpacity:
            guard let value else {
                appearance.resetBackgroundOpacity()
                return
            }
            guard let opacity = Double(value), opacity.isFinite,
                  AppearanceSettings.backgroundOpacityRange.contains(opacity)
            else { throw Error.invalidValue(key) }
            appearance.backgroundOpacity = opacity
            appearance.persistOpacity()
        case Keys.backdropStyle:
            guard let value else {
                appearance.resetBackdropStyle()
                return
            }
            guard let style = WindowBackdropStyle(rawValue: value) else { throw Error.invalidValue(key) }
            appearance.backdropStyle = style
        case Keys.messageListLines:
            guard let value else {
                appearance.resetMessageListLines()
                return
            }
            guard let lines = Int(value),
                  AppearanceSettings.messageListLineRange.contains(lines)
            else { throw Error.invalidValue(key) }
            appearance.messageListLines = lines
        case Keys.accent:
            guard let value, value != "system", value != "none" else {
                appearance.accent.resetOverride()
                return
            }
            guard let accent = decodeAccent(value) else { throw Error.invalidValue(key) }
            appearance.accent.accentOverride = accent
        case Keys.leadingSwipe:
            try applySwipeSetting(
                value,
                key: key,
                edge: .leading,
                actions: actions
            )
        case Keys.trailingSwipe:
            try applySwipeSetting(
                value,
                key: key,
                edge: .trailing,
                actions: actions
            )
        default:
            throw Error.unsupportedKey(key)
        }
    }

    enum Error: Swift.Error, LocalizedError {
        case unsupportedKey(String)
        case invalidValue(String)
        case encodingFailed(String, underlying: Swift.Error)

        var errorDescription: String? {
            switch self {
            case .unsupportedKey(let key):
                "This setting is not supported by this version of Mailternal: \(key)."
            case .invalidValue(let key):
                "The value for setting \(key) is invalid."
            case .encodingFailed(let key, let underlying):
                "Couldn’t encode setting \(key): \(underlying.localizedDescription)"
            }
        }
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true": true
        case "false": false
        default: nil
        }
    }

    private static func encodeAccent(_ accent: AccentColorValue) -> String {
        let values = [accent.red, accent.green, accent.blue, accent.alpha]
        guard let data = try? JSONEncoder().encode(values) else { return "system" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeAccent(_ value: String) -> AccentColorValue? {
        guard let data = value.data(using: .utf8),
              let values = try? JSONDecoder().decode([Double].self, from: data),
              values.count == 4,
              values.allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else { return nil }
        return AccentColorValue(red: values[0], green: values[1], blue: values[2], alpha: values[3])
    }

    @MainActor
    private static func applySwipeSetting(
        _ value: String?,
        key: String,
        edge: SwipeEdge,
        actions: ActionSettings
    ) throws {
        guard let value else {
            switch edge {
            case .leading: actions.resetLeadingSwipe()
            case .trailing: actions.resetTrailingSwipe()
            }
            return
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { throw Error.invalidValue(key) }
        if first == "{" {
            let payload: SwipeActionEditPayload
            do {
                guard let data = trimmed.data(using: .utf8) else {
                    throw Error.invalidValue(key)
                }
                payload = try JSONDecoder().decode(SwipeActionEditPayload.self, from: data)
            } catch let error as Error {
                throw error
            } catch {
                throw Error.invalidValue(key)
            }

            let limit = edge == .leading
                ? ActionSettings.leadingSwipeLimit
                : ActionSettings.trailingSwipeLimit
            guard (0..<limit).contains(payload.index) else {
                throw Error.invalidValue(key)
            }
            let action: SwipeActionKind?
            if let rawAction = payload.action {
                guard let decodedAction = SwipeActionKind(rawValue: rawAction) else {
                    throw Error.invalidValue(key)
                }
                action = decodedAction
            } else {
                action = nil
            }
            actions.setSwipeAction(action, at: payload.index, edge: edge)
            return
        }
        guard first == "[" else { throw Error.invalidValue(key) }
        actions.setSwipeActions(try decodeSwipeActions(trimmed), for: edge)
    }

    private static func decodeSwipeActions(_ value: String) throws -> [SwipeActionKind] {
        guard let data = value.data(using: .utf8),
              let rawValues = try? JSONDecoder().decode([String].self, from: data),
              rawValues.allSatisfy({ SwipeActionKind(rawValue: $0) != nil })
        else { throw Error.invalidValue("actions.swipe") }
        return rawValues.compactMap(SwipeActionKind.init(rawValue:))
    }
}
