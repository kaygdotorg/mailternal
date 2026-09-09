import AppKit
import QuartzCore
import os

/// Drives real AppKit scroll handlers for a bounded QA-only workload.
///
/// The profile is intentionally inert unless both `MAILTERNAL_QA=1` and
/// `-qa-interaction-profile` are present. It discovers the visible tab, list,
/// and reader scroll views after the window has been laid out, then sends
/// synthetic NSEvents through `NSScrollView.scrollWheel(with:)`. It never
/// assigns a scroll position. Results describe synthetic AppKit event and
/// Core Animation timing on the QA VM, not physical trackpad or GPU smoothness.
@MainActor
enum QAInteractionProfile {
    private static let signpostLog = OSLog(
        subsystem: "org.kayg.mailternal",
        category: "QAInteractionProfile"
    )
    private static let profileFlag = "-qa-interaction-profile"
    private static let sampleInterval: TimeInterval = 1.0 / 60.0
    private static let samplesPerSurface = 120
    private static let strokeLength = samplesPerSurface / 2
    private static let discoveryAttempts = 300
    private static let maxStoredSamples = samplesPerSurface

    private struct Surface {
        enum Axis {
            case horizontal
            case vertical
        }

        let name: String
        let scrollView: NSScrollView
        let axis: Axis
        let window: NSWindow
    }

    @MainActor
    private final class SurfaceStats {
        let surface: Surface
        var handlerMicroseconds = Array(repeating: 0.0, count: maxStoredSamples)
        var caCompletionMicroseconds = Array(repeating: 0.0, count: maxStoredSamples)
        var jitterMicroseconds = Array(repeating: 0.0, count: maxStoredSamples)
        var handlerCount = 0
        var caCompletionCount = 0
        var jitterCount = 0
        var pendingCACompletions = 0
        var strokeDirection: CGFloat = 1
        var startOffset = 0.0
        var midOffset = 0.0
        var endOffset = 0.0
        var didEndGesture = false
        var lastSettlingOffset: Double?
        var stableOffsetCount = 0
        var settlingAttempts = 0

        init(surface: Surface) {
            self.surface = surface
        }

        func recordHandler(_ value: Double, jitter: Double) -> Int? {
            guard handlerCount < handlerMicroseconds.count else { return nil }
            let index = handlerCount
            handlerMicroseconds[index] = value
            handlerCount += 1
            guard jitterCount < jitterMicroseconds.count else { return index }
            jitterMicroseconds[jitterCount] = jitter
            jitterCount += 1
            return index
        }

        func recordCACompletion(_ value: Double, index: Int) {
            guard index >= 0, index < caCompletionMicroseconds.count else { return }
            caCompletionMicroseconds[index] = value
            caCompletionCount = max(caCompletionCount, index + 1)
            pendingCACompletions = max(0, pendingCACompletions - 1)
        }
    }

    @MainActor
    private final class Runner {
        var surfaces: [SurfaceStats] = []
        var surfaceIndex = 0
        var sampleIndex = 0
        var expectedTick = ProcessInfo.processInfo.systemUptime
        var timer: Timer?
        var discoveryAttempt = 0
        var lastGeometry: [CGRect] = []
        var stableGeometryCount = 0
        var didFail = false
    }

    private static var runner: Runner?

    /// Installs the profile once. CLIEngine calls this immediately after the
    /// did-finish-launching phase and before normal model/window work begins.
    static func installIfRequested() {
        guard ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1",
              ProcessInfo.processInfo.arguments.contains(profileFlag),
              runner == nil else {
            return
        }
        let state = Runner()
        runner = state
        DispatchQueue.main.async {
            discoverSurfaces(state)
        }
    }

    private static func discoverSurfaces(_ state: Runner) {
        guard !state.didFail else { return }
        state.discoveryAttempt += 1
        guard state.discoveryAttempt < discoveryAttempts else {
            fail(state, reason: "foreground tab/list/reader workload absent or unsettled")
            return
        }
        guard let surfaces = collectSurfaces() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                discoverSurfaces(state)
            }
            return
        }
        // Do not count initial active-tab reveal or pending layout as input work.
        let geometry = surfaces.flatMap {
            [$0.scrollView.contentView.bounds, $0.scrollView.documentView?.bounds ?? .zero]
        }
        state.stableGeometryCount = geometry == state.lastGeometry
            ? state.stableGeometryCount + 1 : 0
        state.lastGeometry = geometry
        guard state.stableGeometryCount >= 3 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                discoverSurfaces(state)
            }
            return
        }
        state.surfaces = surfaces.map(SurfaceStats.init)
        QALaunch.log(
            "interaction-profile begin surfaces=tab,list,reader strokes=60x+10px,60x-10px interval_ms=16.667"
        )
        os_signpost(.begin, log: signpostLog, name: "profile")
        runSurface(state)
    }

    private static func collectSurfaces() -> [Surface]? {
        guard NSApp.isActive else { return nil }
        let windows = NSApp.windows.filter {
            $0.isKeyWindow && !$0.isMiniaturized && $0.isVisible && $0.contentView != nil
        }
        var scrollViews: [(NSScrollView, NSWindow)] = []
        for window in windows {
            guard var root = window.contentView else { continue }
            // Native toolbar items live outside the window's content subtree.
            while let parent = root.superview { root = parent }
            collectScrollViews(in: root, window: window, into: &scrollViews)
        }

        let horizontal = scrollViews.first { scrollView, _ in
            // Hidden tab indicators do not disable scrolling. A column table
            // may also overflow horizontally, but is not the tab workload.
            guard !(scrollView.documentView is NSTableView) else { return false }
            guard abs(scrollView.contentView.bounds.height - ReaderTabLayoutPolicy.rowHeight) < 1 else {
                return false
            }
            let contentWidth = scrollView.documentView?.bounds.width ?? 0
            return contentWidth > scrollView.contentView.bounds.width + 20
        }
        let table = scrollViews.first { scrollView, _ in
            guard scrollView.hasVerticalScroller else { return false }
            return scrollView.documentView?.accessibilityIdentifier() == UIIdentifier.messageTable
        }
        let reader = scrollViews.first { scrollView, _ in
            guard scrollView.hasVerticalScroller else { return false }
            if let table, scrollView === table.0 { return false }
            guard !(scrollView.documentView is NSTableView) else { return false }
            let contentHeight = scrollView.documentView?.bounds.height ?? 0
            return contentHeight > scrollView.contentView.bounds.height + 20
        }
        guard let (tabScrollView, tabWindow) = horizontal,
              let (listScrollView, listWindow) = table,
              let (readerScrollView, readerWindow) = reader else {
            return nil
        }
        return [
            Surface(name: "tab", scrollView: tabScrollView, axis: .horizontal, window: tabWindow),
            Surface(name: "list", scrollView: listScrollView, axis: .vertical, window: listWindow),
            Surface(name: "reader", scrollView: readerScrollView, axis: .vertical, window: readerWindow),
        ]
    }

    private static func collectScrollViews(
        in view: NSView,
        window: NSWindow,
        into result: inout [(NSScrollView, NSWindow)]
    ) {
        if let scrollView = view as? NSScrollView,
           !scrollView.isHiddenOrHasHiddenAncestor,
           scrollView.window === window {
            result.append((scrollView, window))
        }
        for child in view.subviews {
            collectScrollViews(in: child, window: window, into: &result)
        }
    }

    private static func runSurface(_ state: Runner) {
        guard state.surfaceIndex < state.surfaces.count else {
            os_signpost(.end, log: signpostLog, name: "profile")
            QALaunch.log("interaction-profile complete surfaces=3")
            return
        }
        let stats = state.surfaces[state.surfaceIndex]
        stats.startOffset = offset(for: stats.surface)
        stats.strokeDirection = strokeDirection(for: stats)
        QALaunch.log("interaction-profile geometry surface=\(stats.surface.name) clip=\(stats.surface.scrollView.contentView.bounds) document=\(stats.surface.scrollView.documentView?.bounds ?? .zero) direction=\(stats.strokeDirection)")
        guard let begin = makeScrollEvent(for: stats.surface, phase: .began) else {
            fail(state, reason: "could not construct gesture begin")
            return
        }
        let began = ProcessInfo.processInfo.systemUptime
        stats.surface.scrollView.scrollWheel(with: begin)
        QALaunch.log(String(
            format: "interaction-profile phase=begin surface=%@ handler_us=%.1f",
            stats.surface.name, (ProcessInfo.processInfo.systemUptime - began) * 1_000_000
        ))
        state.sampleIndex = 0
        state.expectedTick = ProcessInfo.processInfo.systemUptime + sampleInterval
        state.timer?.invalidate()
        let timer = Timer(timeInterval: sampleInterval, repeats: true) { _ in
            MainActor.assumeIsolated { emitEvent(state) }
        }
        state.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func makeScrollEvent(
        for surface: Surface,
        deltaX: CGFloat = 0,
        deltaY: CGFloat = 0,
        phase: CGScrollPhase
    ) -> NSEvent? {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        ) else { return nil }
        event.location = eventLocation(for: surface)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        return NSEvent(cgEvent: event)
    }

    private static func emitEvent(_ state: Runner) {
        guard state.surfaceIndex < state.surfaces.count else { return }
        let stats = state.surfaces[state.surfaceIndex]
        guard NSApp.isActive, stats.surface.window.isKeyWindow else {
            fail(state, reason: "profile window lost foreground")
            return
        }
        let index = state.sampleIndex
        guard index < samplesPerSurface else {
            finishSurface(state)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let jitter = (now - state.expectedTick) * 1_000_000
        state.expectedTick = now + sampleInterval
        let direction = CGFloat(index < strokeLength ? 1 : -1) * stats.strokeDirection
        let deltaX: CGFloat
        let deltaY: CGFloat
        switch stats.surface.axis {
        case .horizontal:
            deltaX = direction * 10
            deltaY = 0
        case .vertical:
            deltaX = 0
            deltaY = direction * 10
        }
        guard let event = makeScrollEvent(
            for: stats.surface, deltaX: deltaX, deltaY: deltaY, phase: .changed
        ) else {
            fail(state, reason: "could not construct scroll-wheel event")
            return
        }

        let currentSurfaceIndex = state.surfaceIndex
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "scrollEvent", signpostID: signpostID)
        let started = ProcessInfo.processInfo.systemUptime
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak state] in
            let completed = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                guard let state, currentSurfaceIndex < state.surfaces.count else { return }
                let caCompletionMicroseconds = (completed - started) * 1_000_000
                state.surfaces[currentSurfaceIndex].recordCACompletion(caCompletionMicroseconds, index: index)
                os_signpost(.end, log: signpostLog, name: "scrollEvent", signpostID: signpostID)
                if state.sampleIndex >= samplesPerSurface {
                    finishSurface(state)
                }
            }
        }
        stats.pendingCACompletions += 1
        stats.surface.scrollView.scrollWheel(with: event)
        let handlerMicroseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000_000
        state.sampleIndex += 1
        _ = stats.recordHandler(handlerMicroseconds, jitter: jitter)
        if index == strokeLength - 1 {
            stats.midOffset = offset(for: stats.surface)
        }
        if index < 2 || index == strokeLength || index == samplesPerSurface - 1 {
            QALaunch.log("interaction-profile checkpoint surface=\(stats.surface.name) index=\(index) offset=\(offset(for: stats.surface))")
        }
        CATransaction.commit()
    }

    private static func finishSurface(_ state: Runner) {
        state.timer?.invalidate()
        state.timer = nil
        guard state.surfaceIndex < state.surfaces.count else { return }
        let stats = state.surfaces[state.surfaceIndex]
        guard stats.pendingCACompletions == 0 else { return }
        if !stats.didEndGesture {
            stats.didEndGesture = true
            guard let end = makeScrollEvent(for: stats.surface, phase: .ended) else {
                fail(state, reason: "could not construct gesture end")
                return
            }
            let ended = ProcessInfo.processInfo.systemUptime
            stats.surface.scrollView.scrollWheel(with: end)
            QALaunch.log(String(
                format: "interaction-profile phase=end surface=%@ handler_us=%.1f",
                stats.surface.name, (ProcessInfo.processInfo.systemUptime - ended) * 1_000_000
            ))
            DispatchQueue.main.asyncAfter(deadline: .now() + sampleInterval) {
                finishSurface(state)
            }
            return
        }
        // AppKit applies scroll deltas asynchronously. A transaction marker
        // alone can precede the final clip-view update by one display tick.
        let currentOffset = offset(for: stats.surface)
        stats.settlingAttempts += 1
        stats.stableOffsetCount = stats.lastSettlingOffset.map {
            abs($0 - currentOffset) < 0.05 ? stats.stableOffsetCount + 1 : 0
        } ?? 0
        stats.lastSettlingOffset = currentOffset
        guard stats.stableOffsetCount >= 3 else {
            guard stats.settlingAttempts < 60 else {
                fail(state, reason: "\(stats.surface.name) scroll geometry did not settle")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + sampleInterval) {
                finishSurface(state)
            }
            return
        }
        stats.endOffset = currentOffset
        let midDisplacement = abs(stats.midOffset - stats.startOffset)
        let endDelta = abs(stats.endOffset - stats.startOffset)
        emitSummary(stats, midDisplacement: midDisplacement, endDelta: endDelta)
        guard midDisplacement > 0.5 else {
            fail(state, reason: "\(stats.surface.name) directional stroke produced no displacement")
            return
        }
        guard endDelta <= 2.0 else {
            fail(state, reason: "\(stats.surface.name) directional stroke did not restore")
            return
        }
        state.surfaceIndex += 1
        DispatchQueue.main.async {
            runSurface(state)
        }
    }
    private static func emitSummary(
        _ stats: SurfaceStats,
        midDisplacement: Double,
        endDelta: Double
    ) {
        let handler = percentileValues(stats.handlerMicroseconds, count: stats.handlerCount)
        let caCompletion = percentileValues(
            stats.caCompletionMicroseconds,
            count: stats.caCompletionCount
        )
        let jitter = percentileValues(stats.jitterMicroseconds, count: stats.jitterCount)
        QALaunch.log(
            String(
                format: "interaction-profile summary surface=%@ n=%d handler_p50_us=%.1f handler_p95_us=%.1f handler_max_us=%.1f ca_completion_p50_us=%.1f ca_completion_p95_us=%.1f ca_completion_max_us=%.1f jitter_p95_us=%.1f mid_displacement_pt=%.1f end_delta_pt=%.1f restored=%@",
                stats.surface.name,
                stats.handlerCount,
                handler.p50,
                handler.p95,
                handler.max,
                caCompletion.p50,
                caCompletion.p95,
                caCompletion.max,
                jitter.p95,
                midDisplacement,
                endDelta,
                endDelta <= 2.0 ? "yes" : "no"
            )
        )
    }

    private static func percentileValues(_ source: [Double], count: Int) -> (p50: Double, p95: Double, max: Double) {
        guard count > 0 else { return (0, 0, 0) }
        var values = Array(source.prefix(count))
        values.sort()

        let p50 = values[(count - 1) / 2]
        let p95 = values[min(count - 1, (count * 95) / 100)]
        return (p50, p95, values[count - 1])
    }
    private static func offset(for surface: Surface) -> Double {
        let origin = surface.scrollView.contentView.bounds.origin
        switch surface.axis {
        case .horizontal:
            return Double(origin.x)
        case .vertical:
            return Double(origin.y)
        }
    }

    private static func strokeDirection(for stats: SurfaceStats) -> CGFloat {
        guard let documentView = stats.surface.scrollView.documentView else {
            return 1
        }
        let documentBounds = documentView.bounds
        let current = offset(for: stats.surface)
        switch stats.surface.axis {
        case .horizontal:
            let lower = Double(documentBounds.minX)
            return current <= lower + 1 ? 1 : -1
        case .vertical:
            let lower = Double(documentBounds.minY)
            return current <= lower + 1 ? -1 : 1
        }
    }

    private static func eventLocation(for surface: Surface) -> NSPoint {
        let local = NSPoint(
            x: surface.scrollView.bounds.midX,
            y: surface.scrollView.bounds.midY
        )
        let windowPoint = surface.scrollView.convert(local, to: nil)
        let screenPoint = surface.window.convertPoint(toScreen: windowPoint)
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        return NSPoint(x: screenPoint.x, y: screenTop - screenPoint.y)
    }

    private static func fail(_ state: Runner, reason: String) {
        guard !state.didFail else { return }
        state.didFail = true
        state.timer?.invalidate()
        state.timer = nil
        os_signpost(.event, log: signpostLog, name: "profileFailed", "%{public}s", reason)
        QALaunch.log("interaction-profile failed reason=\(reason)")
    }
}
