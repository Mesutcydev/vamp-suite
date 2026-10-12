import Foundation

struct Display: Identifiable, Hashable {
    let id: Int
    let label: String
    let width: Int
    let height: Int
    let originX: Int
    let originY: Int
    let isPrimary: Bool
    let refreshHz: Int
    let hdr: String?
}
