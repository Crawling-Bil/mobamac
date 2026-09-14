import Foundation

struct SFTPEntry: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modifiedAt: Date?
}
