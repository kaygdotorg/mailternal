import Foundation

/// One live scheme-handler fetch, keyed by `WKURLSchemeTask` identity plus a
/// generation so a cancelled task's `defer` cannot drop a replacement fetch
/// that reused the same identity.
public struct SchemeTaskHandle: Equatable, Sendable {
    public let id: ObjectIdentifier
    public let generation: UInt64
}

/// Tracks one unstructured `WKURLSchemeHandler` provider `Task` per scheme-task
/// identity. `stop()` cancels that task; every completion path (success, error,
/// cancel) removes the matching generation so the map cannot leak and a recycled
/// `ObjectIdentifier` cannot inherit a stale "stopped" flag.
public final class SchemeTaskRegistry: @unchecked Sendable {
    private struct Entry {
        var task: Task<Void, Never>
        var generation: UInt64
    }

    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Entry] = [:]
    private var generation: UInt64 = 0

    public init() {}

    /// Adopt `task` for `id`. A leftover task for the same identity is cancelled
    /// first (identifier reuse while a fetch is still live).
    @discardableResult
    public func register(_ id: ObjectIdentifier, task: Task<Void, Never>) -> SchemeTaskHandle {
        lock.lock()
        generation += 1
        let handle = SchemeTaskHandle(id: id, generation: generation)
        let previous = tasks.updateValue(Entry(task: task, generation: generation), forKey: id)
        lock.unlock()
        previous?.task.cancel()
        return handle
    }

    /// Cancel and forget the live task for `id`. Returns whether a task was live.
    @discardableResult
    public func stop(_ id: ObjectIdentifier) -> Bool {
        lock.lock()
        let entry = tasks.removeValue(forKey: id)
        lock.unlock()
        guard let entry else { return false }
        entry.task.cancel()
        return true
    }

    /// Drop this generation without cancelling. Call from the task's `defer`.
    /// A newer generation for the same identity is left alone.
    public func remove(_ handle: SchemeTaskHandle) {
        lock.lock()
        if tasks[handle.id]?.generation == handle.generation {
            tasks.removeValue(forKey: handle.id)
        }
        lock.unlock()
    }

    public var liveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return tasks.count
    }

    public func isLive(_ id: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tasks[id] != nil
    }
}
