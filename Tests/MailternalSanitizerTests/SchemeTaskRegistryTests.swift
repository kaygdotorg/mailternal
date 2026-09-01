import Foundation
import Testing
@testable import MailternalSanitizer

private final class SchemeTaskIdentity: NSObject {}

@Test("stop cancels the live provider task and forgets it")
func schemeStopCancelsLiveTask() async {
    let registry = SchemeTaskRegistry()
    let identity = SchemeTaskIdentity()
    let id = ObjectIdentifier(identity)
    let task = Task {
        try? await Task.sleep(for: .seconds(30))
    }
    _ = registry.register(id, task: task)
    #expect(registry.liveCount == 1)
    #expect(registry.isLive(id))
    #expect(registry.stop(id))
    #expect(registry.liveCount == 0)
    #expect(!registry.isLive(id))
    await task.value
    #expect(task.isCancelled)
}

@Test("completion removes the entry so the map cannot leak")
func schemeCompletionPrunesEntry() async {
    let registry = SchemeTaskRegistry()
    let identity = SchemeTaskIdentity()
    let id = ObjectIdentifier(identity)
    let slot = HandleSlot()
    let task = Task {
        defer {
            if let handle = slot.handle { registry.remove(handle) }
        }
    }
    slot.handle = registry.register(id, task: task)
    await task.value
    #expect(registry.liveCount == 0)
    #expect(!registry.stop(id))
}

@Test("recycled identity is not auto-stopped after a prior completion")
func schemeIdentifierReuseAfterCompletionIsFresh() async {
    let registry = SchemeTaskRegistry()
    let identity = SchemeTaskIdentity()
    let id = ObjectIdentifier(identity)

    let slot = HandleSlot()
    let first = Task {
        defer {
            if let handle = slot.handle { registry.remove(handle) }
        }
    }
    slot.handle = registry.register(id, task: first)
    await first.value
    #expect(registry.liveCount == 0)

    let second = Task {
        try? await Task.sleep(for: .seconds(30))
    }
    _ = registry.register(id, task: second)
    #expect(registry.liveCount == 1)
    #expect(!second.isCancelled)
    registry.stop(id)
    await second.value
    #expect(second.isCancelled)
    #expect(registry.liveCount == 0)
}

@Test("recycled identity after stop starts a new live task")
func schemeIdentifierReuseAfterStopIsFresh() async {
    let registry = SchemeTaskRegistry()
    let identity = SchemeTaskIdentity()
    let id = ObjectIdentifier(identity)

    let first = Task {
        try? await Task.sleep(for: .seconds(30))
    }
    _ = registry.register(id, task: first)
    registry.stop(id)
    await first.value
    #expect(first.isCancelled)
    #expect(registry.liveCount == 0)

    let second = Task {
        try? await Task.sleep(for: .seconds(30))
    }
    _ = registry.register(id, task: second)
    #expect(registry.isLive(id))
    #expect(!second.isCancelled)
    registry.stop(id)
    await second.value
}

@Test("stop of an unknown identity is a no-op")
func schemeStopUnknownIsNoop() {
    let registry = SchemeTaskRegistry()
    let id = ObjectIdentifier(SchemeTaskIdentity())
    #expect(!registry.stop(id))
    #expect(registry.liveCount == 0)
}

@Test("registering a second task for the same identity cancels the first without dropping the second")
func schemeReregisterCancelsPrevious() async {
    let registry = SchemeTaskRegistry()
    let id = ObjectIdentifier(SchemeTaskIdentity())
    let slot = HandleSlot()
    let first = Task {
        defer {
            if let handle = slot.handle { registry.remove(handle) }
        }
        try? await Task.sleep(for: .seconds(30))
    }
    slot.handle = registry.register(id, task: first)
    let second = Task {
        try? await Task.sleep(for: .seconds(30))
    }
    _ = registry.register(id, task: second)
    await first.value
    #expect(first.isCancelled)
    #expect(registry.liveCount == 1)
    #expect(!second.isCancelled)
    registry.stop(id)
    await second.value
}

private final class HandleSlot: @unchecked Sendable {
    var handle: SchemeTaskHandle?
}
