import Foundation
import SharedModels

public protocol EventLogStoreProtocol {
    func append(_ item: EventLogItem) async
    func recentItems(limit: Int) async -> [EventLogItem]
    func removeAll() async
}
