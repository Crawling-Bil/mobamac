import Foundation

/// A folder-like grouping for organizing session profiles in the sidebar,
/// similar to MobaXterm's session folders. Supports nesting via parentID.
struct SessionGroup: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var parentID: UUID?

    init(id: UUID = UUID(), name: String, parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }
}
