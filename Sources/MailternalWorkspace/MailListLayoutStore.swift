import Foundation
import Observation
import MailternalInterfaces

/// Errors raised when a list customization cannot be represented safely.
public enum MailListLayoutError: Error, LocalizedError, Equatable, Sendable {
    case invalidScope
    case invalidColumnOrder
    case invalidColumnWidth
    case invalidEncodedValue

    public var errorDescription: String? {
        switch self {
        case .invalidScope:
            "The list customization scope is invalid."
        case .invalidColumnOrder:
            "Column order must contain every known column exactly once."
        case .invalidColumnWidth:
            "Column width must be a finite positive number."
        case .invalidEncodedValue:
            "The list customization could not be encoded."
        }
    }
}

/// Durable global and per-folder list customization backed by the shared
/// workspace synchronization controller.
///
/// The store never writes while resolving a configuration. Unknown or malformed
/// received values are ignored and therefore cannot be republished as local
/// edits. Each visibility and width is its own workspace key; order and sorting
/// are complete atomic values.
@MainActor
@Observable
public final class MailListLayoutStore {
    nonisolated public static let keyPrefix = "mailternal.workspace.list-layout."

    nonisolated private static let presentationField = "presentation"
    nonisolated private static let paneLayoutField = "pane-layout"
    nonisolated private static let columnOrderField = "column-order"
    nonisolated private static let sortField = "sort"

    private let controller: WorkspaceSyncController

    public init(controller: WorkspaceSyncController) {
        self.controller = controller
    }

    /// Returns effective settings after applying a folder's valid overrides to
    /// the global values. A malformed value is treated as absent.
    public func configuration(for scope: MailListScope) -> MailListConfiguration {
        let global = applyingValues(
            controller.values,
            for: .global,
            to: .defaults
        )
        guard case .folder(_, _) = scope, Self.isValidScope(scope) else {
            return global
        }
        return applyingValues(controller.values, for: scope, to: global)
    }

    /// Sets the presentation for `scope`.
    public func setPresentation(
        _ presentation: MailListPresentation,
        for scope: MailListScope
    ) async throws {
        try await set(
            .string(presentation.rawValue),
            field: Self.presentationField,
            scope: scope
        )
    }

    /// Sets the list/reader pane arrangement for `scope`.
    public func setPaneLayout(
        _ paneLayout: MailPaneLayout,
        for scope: MailListScope
    ) async throws {
        try await set(
            .string(paneLayout.rawValue),
            field: Self.paneLayoutField,
            scope: scope
        )
    }

    /// Replaces the complete column order for `scope` as one atomic value.
    public func setColumnOrder(
        _ columnOrder: [MailListColumn],
        for scope: MailListScope
    ) async throws {
        guard Self.isCompleteColumnOrder(columnOrder) else {
            throw MailListLayoutError.invalidColumnOrder
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(columnOrder)
        } catch {
            throw MailListLayoutError.invalidEncodedValue
        }
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw MailListLayoutError.invalidEncodedValue
        }
        try await set(.string(encoded), field: Self.columnOrderField, scope: scope)
    }

    /// Sets one column's visibility independently of every other column field.
    public func setColumnVisible(
        _ column: MailListColumn,
        visible: Bool,
        for scope: MailListScope
    ) async throws {
        try await set(
            .bool(visible),
            field: Self.columnField(column, "visible"),
            scope: scope
        )
    }

    /// Sets one column width independently of every other column field.
    public func setColumnWidth(
        _ column: MailListColumn,
        width: Double,
        for scope: MailListScope
    ) async throws {
        guard Self.isValidWidth(width) else {
            throw MailListLayoutError.invalidColumnWidth
        }
        try await set(
            .number(width),
            field: Self.columnField(column, "width"),
            scope: scope
        )
    }

    /// Replaces the complete sort descriptor for `scope` as one atomic value.
    public func setSort(
        _ sort: MailListSort,
        for scope: MailListScope
    ) async throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(sort)
        } catch {
            throw MailListLayoutError.invalidEncodedValue
        }
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw MailListLayoutError.invalidEncodedValue
        }
        try await set(.string(encoded), field: Self.sortField, scope: scope)
    }

    /// Persists tombstones for every field in `scope`, returning a folder to
    /// global inheritance (or global to built-in defaults).
    public func resetOverrides(for scope: MailListScope) async throws {
        guard Self.isValidScope(scope) else {
            throw MailListLayoutError.invalidScope
        }
        let fields = [
            Self.presentationField,
            Self.paneLayoutField,
            Self.columnOrderField,
            Self.sortField,
        ] + MailListColumn.allCases.flatMap { column in
            [Self.columnField(column, "visible"), Self.columnField(column, "width")]
        }
        for field in fields {
            try await set(nil, field: field, scope: scope)
        }
    }

    /// Returns whether a canonical workspace key belongs to this layout schema.
    /// This is shared by both Apple pairing/category bridges.
    nonisolated public static func isSupportedKey(_ key: String) -> Bool {
        guard key.hasPrefix(keyPrefix) else { return false }
        let suffix = String(key.dropFirst(keyPrefix.count))
        let parts = suffix.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let token = parts.first, isValidScopeToken(token) else { return false }
        let fields = Array(parts.dropFirst())
        if fields.count == 1 {
            return fields[0] == presentationField
                || fields[0] == paneLayoutField
                || fields[0] == columnOrderField
                || fields[0] == sortField
        }
        guard fields.count == 3,
              fields[0] == "column",
              MailListColumn(rawValue: fields[1]) != nil
        else { return false }
        return fields[2] == "visible" || fields[2] == "width"
    }
    /// Returns the same layout key with its account-scoped identity replaced.
    ///
    /// Global keys and keys for another account are returned unchanged. A
    /// malformed or unsupported key returns `nil` so callers cannot turn
    /// arbitrary workspace data into a trusted account-scoped identity.
    nonisolated public static func remappedAccountLinkID(
        in key: String,
        from source: AccountLinkID,
        to destination: AccountLinkID
    ) -> String? {
        guard isSupportedKey(key) else { return nil }
        let suffix = String(key.dropFirst(keyPrefix.count))
        let parts = suffix.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let token = parts.first, token != "global",
              let decoded = decodeBase64URL(token),
              let scope = String(data: decoded, encoding: .utf8) else {
            return key
        }
        let components = scope.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 2,
              let account = AccountLinkID(uuidString: components[0]),
              account == source else {
            return key
        }
        let replacement = scopeToken(
            for: .folder(account: destination, path: components[1])
        )
        return "\(keyPrefix)\(replacement).\(parts.dropFirst().joined(separator: "."))"
    }


    /// The stable, device-independent scope token used in canonical keys.
    nonisolated public static func scopeToken(for scope: MailListScope) -> String {
        switch scope {
        case .global:
            return "global"
        case .folder(let account, let path):
            var data = Data(account.uuidString.utf8)
            data.append(0)
            data.append(contentsOf: path.utf8)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }

    private func set(
        _ value: WorkspaceSyncValue?,
        field: String,
        scope: MailListScope
    ) async throws {
        guard Self.isValidScope(scope) else {
            throw MailListLayoutError.invalidScope
        }
        let key = Self.key(scope: scope, field: field)
        try await controller.setValue(value, for: key, category: .workspace)
    }

    private func applyingValues(
        _ values: [String: WorkspaceSyncValue],
        for scope: MailListScope,
        to base: MailListConfiguration
    ) -> MailListConfiguration {
        guard Self.isValidScope(scope) else { return base }
        let token = Self.scopeToken(for: scope)
        func value(_ field: String) -> WorkspaceSyncValue? {
            values[Self.key(token: token, field: field)]
        }

        var configuration = base
        if case .string(let raw)? = value(Self.presentationField),
           let presentation = MailListPresentation(rawValue: raw) {
            configuration.presentation = presentation
        }
        if case .string(let raw)? = value(Self.paneLayoutField),
           let paneLayout = MailPaneLayout(rawValue: raw) {
            configuration.paneLayout = paneLayout
        }
        if case .string(let raw)? = value(Self.columnOrderField),
           let data = raw.data(using: .utf8),
           let order = try? JSONDecoder().decode([MailListColumn].self, from: data),
           Self.isCompleteColumnOrder(order) {
            configuration.columnOrder = order
        }
        if case .string(let raw)? = value(Self.sortField),
           let data = raw.data(using: .utf8),
           let sort = try? JSONDecoder().decode(MailListSort.self, from: data) {
            configuration.sort = sort
        }

        for column in MailListColumn.allCases {
            if case .bool(let visible)? = value(Self.columnField(column, "visible")) {
                if visible {
                    configuration.hiddenColumns.remove(column)
                } else {
                    configuration.hiddenColumns.insert(column)
                }
            }
            if case .number(let width)? = value(Self.columnField(column, "width")),
               Self.isValidWidth(width) {
                configuration.columnWidths[column] = width
            }
        }
        return configuration
    }

    private static func key(scope: MailListScope, field: String) -> String {
        key(token: scopeToken(for: scope), field: field)
    }

    private static func key(token: String, field: String) -> String {
        "\(keyPrefix)\(token).\(field)"
    }

    private static func columnField(_ column: MailListColumn, _ field: String) -> String {
        "column.\(column.rawValue).\(field)"
    }

    private static func isCompleteColumnOrder(_ order: [MailListColumn]) -> Bool {
        order.count == MailListColumn.allCases.count
            && Set(order) == Set(MailListColumn.allCases)
    }

    private static func isValidWidth(_ width: Double) -> Bool {
        width.isFinite && width > 0
    }

    private static func isValidScope(_ scope: MailListScope) -> Bool {
        switch scope {
        case .global:
            return true
        case .folder(let account, let path):
            return !path.isEmpty && !path.contains("\0") && !account.uuidString.isEmpty
        }
    }

    nonisolated private static func isValidScopeToken(_ token: String) -> Bool {
        if token != "global" {
            guard !token.isEmpty,
                  !token.contains("="),
                  let decoded = decodeBase64URL(token),
                  let string = String(data: decoded, encoding: .utf8)
            else { return false }
            let components = string.split(separator: "\0", omittingEmptySubsequences: false)
            guard components.count == 2,
                  let account = AccountLinkID(uuidString: String(components[0])),
                  !account.uuidString.isEmpty,
                  !components[1].isEmpty
            else { return false }
        }
        return true
    }

    nonisolated private static func decodeBase64URL(_ token: String) -> Data? {
        guard token.allSatisfy({ $0.isASCII && ($0.isNumber || $0.isLetter || $0 == "-" || $0 == "_") }) else {
            return nil
        }
        var base64 = token.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.utf8.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}
