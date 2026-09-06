#if os(watchOS)
import SwiftUI

@main
struct MailternalWatchApp: App {
    @StateObject private var companion: WatchCompanionSession

    init() {
        _companion = StateObject(wrappedValue: WatchCompanionSession())
    }

    var body: some Scene {
        WindowGroup {
            WatchContentView(companion: companion)
                .task {
                    companion.activate()
                }
        }
    }
}
#endif
