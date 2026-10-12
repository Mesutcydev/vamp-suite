import Foundation
import SharedModels

public actor InMemoryEventLogStore: EventLogStoreProtocol {
    private var items: [EventLogItem] = []
    private let limit: Int

    public init(limit: Int = 500) {
        self.limit = limit
    }

    public func append(_ item: EventLogItem) async {
        items.append(item)
        if items.count > limit {
            items.removeFirst(items.count - limit)
        }
    }

    public func recentItems(limit: Int) async -> [EventLogItem] {
        Array(items.suffix(limit)).reversed()
    }

    public func removeAll() async {
        items.removeAll()
    }
}
