import AppKit
import Observation
import SwiftUI

struct ToastID: Hashable, Sendable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
}

enum ToastSeverity: Sendable {
    case info, warning, error

    var spokenWord: String {
        switch self {
        case .info: "Information"
        case .warning: "Warning"
        case .error: "Error"
        }
    }

    var iconName: String {
        switch self {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    func iconTint(increasedContrast: Bool) -> Color {
        switch self {
        case .info: increasedContrast ? .primary : .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}

struct ToastEntry: Identifiable, Equatable {
    var id: ToastID
    var title: String
    var detail: String?
    var severity: ToastSeverity
}

enum ToastMotion {
    static let enter = Animation.spring(duration: 0.40, bounce: 0.16)
    static let exit = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.20)
    static let restack = Animation.spring(duration: 0.34, bounce: 0.10)
    static let expand = Animation.spring(duration: 0.30, bounce: 0.0)
    static let settle = Animation.spring(duration: 0.32, bounce: 0.22)
    static let fling = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)
    static let reducedEnter = Animation.easeOut(duration: 0.16)
    static let reducedExit = Animation.easeOut(duration: 0.12)
    static let reducedRestack = Animation.easeInOut(duration: 0.18)
}

enum ToastStackGeometry {
    static let gap: CGFloat = 14
    static let scaleStep: CGFloat = 0.05
    static let renderedLimit = 3
    static let maxWidth: CGFloat = 360
    static let minHeight: CGFloat = 44
    static let enterScale: CGFloat = 0.94
    static let enterOffset: CGFloat = -12
    static let estimatedCardHeight: CGFloat = 56
    static let horizontalPadding: CGFloat = 16

    static func collapsedOffset(depth: Int) -> CGFloat {
        CGFloat(depth) * gap
    }

    static func expandedOffset(depth: Int, heights: [CGFloat]) -> CGFloat {
        guard depth > 0, !heights.isEmpty else { return 0 }
        let preceding = heights.prefix(depth).reduce(0, +)
        return preceding + CGFloat(depth) * gap
    }

    static func depthScale(depth: Int, reduceMotion: Bool) -> CGFloat {
        reduceMotion ? 1 : 1 - CGFloat(depth) * scaleStep
    }

    static func depthOpacity(depth: Int, reduceMotion: Bool) -> Double {
        reduceMotion ? max(0, 1 - Double(depth) * 0.08) : 1
    }

    static func stackedHeight(of heights: [CGFloat]) -> CGFloat {
        guard let front = heights.first else { return 0 }
        return front + CGFloat(max(heights.count - 1, 0)) * gap
    }

    static func expandedHeight(of heights: [CGFloat]) -> CGFloat {
        guard !heights.isEmpty else { return 0 }
        return heights.reduce(0, +) + CGFloat(max(heights.count - 1, 0)) * gap
    }

    static func width(in container: CGFloat) -> CGFloat {
        min(maxWidth, max(0, container - horizontalPadding * 2))
    }
}

@MainActor
@Observable
final class ToastPresenter {
    private(set) var entries: [ToastEntry] = []
    var isSuppressed = false

    @ObservationIgnored private var expiry: [ToastID: Task<Void, Never>] = [:]

    func post(title: String, detail: String? = nil, severity: ToastSeverity = .error) {
        let id = ToastID("toast-\(UUID().uuidString)")
        let entry = ToastEntry(id: id, title: title, detail: detail, severity: severity)
        entries.insert(entry, at: 0)
        if entries.count > ToastStackGeometry.renderedLimit {
            let dropped = entries.suffix(from: ToastStackGeometry.renderedLimit)
            for item in dropped { expiry[item.id]?.cancel() }
            entries = Array(entries.prefix(ToastStackGeometry.renderedLimit))
        }
        expiry[id]?.cancel()
        expiry[id] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            dismiss(id)
        }
        var text = AttributedString([severity.spokenWord, title, detail].compactMap { $0 }.joined(separator: ". "))
        text.accessibilitySpeechAnnouncementPriority = severity == .error ? .high : .default
        AccessibilityNotification.Announcement(text).post()
    }

    func dismiss(_ id: ToastID) {
        expiry[id]?.cancel()
        expiry[id] = nil
        entries.removeAll { $0.id == id }
    }

    func dismissFront() {
        guard let first = entries.first else { return }
        dismiss(first.id)
    }
}

struct ToastLayer: View {
    @Environment(ToastPresenter.self) private var presenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false
    @State private var heights: [ToastID: CGFloat] = [:]

    var body: some View {
        GeometryReader { geometry in
            let rendered = Array(presenter.entries.prefix(ToastStackGeometry.renderedLimit))
            let width = ToastStackGeometry.width(in: geometry.size.width)
            let measured = rendered.map { heights[$0.id] ?? ToastStackGeometry.estimatedCardHeight }
            let region = hovering
                ? ToastStackGeometry.expandedHeight(of: measured)
                : ToastStackGeometry.stackedHeight(of: measured)

            ZStack(alignment: .top) {
                ForEach(Array(rendered.enumerated()), id: \.element.id) { depth, entry in
                    ToastCard(
                        entry: entry,
                        depth: depth,
                        stackOffset: hovering
                            ? ToastStackGeometry.expandedOffset(depth: depth, heights: measured)
                            : ToastStackGeometry.collapsedOffset(depth: depth),
                        isExpanded: hovering,
                        reduceMotion: reduceMotion,
                        reduceTransparency: reduceTransparency,
                        contrast: contrast,
                        width: width,
                        presenter: presenter,
                        measure: { heights[entry.id] = $0 }
                    )
                    .zIndex(Double(-depth))
                    .transition(transition)
                }
            }
            .animation(reduceMotion ? ToastMotion.reducedEnter : ToastMotion.enter, value: presenter.entries.count)
            .frame(width: width, height: region, alignment: .top)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.top, 10)
            .opacity(presenter.isSuppressed ? 0 : 1)
            .accessibilityIdentifier(UIIdentifier.toastStack)
            .allowsHitTesting(!presenter.isSuppressed && !rendered.isEmpty)
        }
    }

    private var transition: AnyTransition {
        let insertion: AnyTransition = reduceMotion
            ? .opacity
            : .scale(scale: ToastStackGeometry.enterScale, anchor: .top)
                .combined(with: .offset(y: ToastStackGeometry.enterOffset))
                .combined(with: .opacity)
        let removal: AnyTransition = (reduceMotion ? AnyTransition.opacity : .offset(y: -12).combined(with: .opacity))
            .animation(reduceMotion ? ToastMotion.reducedExit : ToastMotion.exit)
        return .asymmetric(insertion: insertion, removal: removal)
    }
}

private struct ToastCard: View {
    let entry: ToastEntry
    let depth: Int
    let stackOffset: CGFloat
    let isExpanded: Bool
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let contrast: ColorSchemeContrast
    let width: CGFloat
    let presenter: ToastPresenter
    let measure: (CGFloat) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.severity.iconName)
                .font(.system(size: 15))
                .symbolRenderingMode(contrast == .increased ? .monochrome : .hierarchical)
                .foregroundStyle(entry.severity.iconTint(increasedContrast: contrast == .increased))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = entry.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                presenter.dismiss(entry.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: width, alignment: .top)
        .frame(minHeight: ToastStackGeometry.minHeight, alignment: .top)
        .onGeometryChange(for: CGFloat.self, of: \.size.height, action: measure)
        .background {
            let shape = RoundedRectangle(cornerRadius: AppShapeScale.toast, style: .continuous)
            ZStack {
                shape.fill(Color(nsColor: .controlBackgroundColor))
                    .opacity(reduceTransparency || depth > 0 && !isExpanded ? 1 : 0)
                if !reduceTransparency {
                    shape.fill(.thickMaterial)
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppShapeScale.toast, style: .continuous)
                .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.55 : 0.12), lineWidth: contrast == .increased ? 1.5 : 0.75)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppShapeScale.toast, style: .continuous))
        .shadow(color: .black.opacity(depth == 0 || isExpanded ? 0.18 : 0), radius: 14, y: 8)
        .offset(y: stackOffset)
        .scaleEffect(ToastStackGeometry.depthScale(depth: depth, reduceMotion: reduceMotion), anchor: .top)
        .opacity(ToastStackGeometry.depthOpacity(depth: depth, reduceMotion: reduceMotion))
        .animation(reduceMotion ? ToastMotion.reducedRestack : ToastMotion.expand, value: isExpanded)
        .animation(reduceMotion ? ToastMotion.reducedRestack : ToastMotion.restack, value: depth)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.severity.spokenWord). \(entry.title)")
        .accessibilityValue(entry.detail ?? "")
        .accessibilityIdentifier(UIIdentifier.toast)
    }
}
