import Foundation

/// Loads and saves snippets as JSON in
/// ~/Library/Application Support/MobaMac/snippets.json. No secrets are ever
/// involved here, so unlike ProfileStore there's no Keychain interaction.
final class SnippetStore: ObservableObject {
    @Published var snippets: [Snippet] = []

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("MobaMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("snippets.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([Snippet].self, from: data) else { return }
        self.snippets = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func upsert(_ snippet: Snippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
        } else {
            snippets.append(snippet)
        }
        save()
    }

    /// Reorders the list and rewrites `buttonBarOrder` from the new
    /// positions, so the button bar follows what the panel shows rather than
    /// keeping a separate order that drifts out of step.
    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        snippets.move(fromOffsets: offsets, toOffset: destination)
        for index in snippets.indices {
            snippets[index].buttonBarOrder = index
        }
        save()
    }

    /// The snippets shown in the button bar, in order, filtered to the
    /// device type of whichever session is in front.
    func buttonBarSnippets(deviceType: String?) -> [Snippet] {
        snippets
            .filter { $0.isInButtonBar && $0.appliesTo(deviceType: deviceType) }
            .sorted { ($0.buttonBarOrder ?? Int.max) < ($1.buttonBarOrder ?? Int.max) }
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        save()
    }
}
