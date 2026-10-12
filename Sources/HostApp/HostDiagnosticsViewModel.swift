import Foundation
import Diagnostics
import SharedModels

@MainActor
final class HostDiagnosticsViewModel: ObservableObject {
    @Published private(set) var items: [EventLogItem] = []

    private let eventLogStore: any EventLogStoreProtocol

    init(eventLogStore: any EventLogStoreProtocol) {
        self.eventLogStore = eventLogStore
    }

    func refresh() async {
        items = await eventLogStore.recentItems(limit: 100)
    }

    func clear() async {
        await eventLogStore.removeAll()
        await refresh()
    }
}
