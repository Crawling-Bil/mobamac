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

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        save()
    }
}
