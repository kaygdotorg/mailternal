import Foundation
import Testing
import MailternalAutomation
import MailternalInterfaces

struct StateHubLifecycleTests {
    @Test func deferredObserverReceivesLatestSnapshotAfterSuspendedPublication() async throws {
        let hub = AppStateHub()
        let subscription = await hub.subscribeBeforeInitialSnapshot()
        #expect(await hub.subscriberCount == 1)

        _ = await hub.publish(makeState(marker: 1))
        _ = await hub.publish(makeState(marker: 2))
        #expect(await hub.activate(subscription))

        var iterator = subscription.stream.makeAsyncIterator()
        let event = try #require(await iterator.next())
        #expect(event.kind == .snapshot)
        #expect(event.revision == 2)
        #expect(event.state == makeState(marker: 2))

        await hub.cancel(subscription)
        #expect(await hub.subscriberCount == 0)
    }

    @Test func failedInitialRefreshCanReleaseDeferredObserver() async {
        let hub = AppStateHub()
        let subscription = await hub.subscribeBeforeInitialSnapshot()
        #expect(await hub.subscriberCount == 1)

        let activated = await hub.activate(subscription)
        #expect(!activated)
        await hub.cancel(subscription)

        #expect(await hub.subscriberCount == 0)
        let hasSubscribers = await hub.hasSubscribers
        #expect(!hasSubscribers)
    }

    private func makeState(marker: UInt64) -> AppState {
        AppState(
            accounts: [],
            accountStates: [:],
            folders: [],
            selectedFolderID: nil,
            selectedMessageIDs: [],
            selectedMessageID: nil,
            selectionRevision: marker,
            listRows: [],
            listCursor: nil,
            activeListSort: .newest,
            readerTabs: [],
            activeTabID: nil,
            focusedSurface: "mail",
            visibleSearchQuery: nil,
            isSearchPresented: false,
            isFindPresented: false,
            findQuery: nil,
            isRawSourcePresented: false,
            emailReadingMode: nil,
            allowRemoteImages: false,
            syncOnline: false,
            syncMode: "offline",
            listConfiguration: .default
        )
    }
}
