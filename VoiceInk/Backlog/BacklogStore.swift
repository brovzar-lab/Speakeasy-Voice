import AppKit
import Combine
import Foundation

enum BacklogFileLocator {
    static func defaultURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("CODE", isDirectory: true)
            .appendingPathComponent("SPEAKEASY-VOICE", isDirectory: true)
            .appendingPathComponent("BACKLOG.md", isDirectory: false)
    }
}

enum FeatureBacklogSubmission {
    static func normalized(_ draft: String) -> String? {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

@MainActor
final class BacklogStore: ObservableObject {
    static let bookmarkDefaultsKey = "featureBacklog.securityScopedBookmark"

    @Published private(set) var entries: [BacklogEntry] = []
    @Published private(set) var fileURL: URL
    @Published var errorMessage: String?
    @Published var successMessage: String?

    private let fileManager: FileManager
    private let defaults: UserDefaults

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.fileURL = fileURL
            ?? Self.resolveBookmarkedURL(defaults: defaults)
            ?? BacklogFileLocator.defaultURL(homeDirectory: fileManager.homeDirectoryForCurrentUser)
    }

    var pendingEntries: [BacklogEntry] {
        entries.filter { !$0.isCompleted }.sorted { $0.createdAt > $1.createdAt }
    }

    func load() async {
        do {
            let document = try readDocument(createIfMissing: true)
            entries = document.entries
            errorMessage = nil
        } catch {
            errorMessage = "Could not load the backlog: \(error.localizedDescription)"
        }
    }

    func add(text: String) async throws {
        guard let normalized = FeatureBacklogSubmission.normalized(text) else { return }
        try mutate { document in
            document.entries.append(BacklogEntry(
                id: UUID(),
                text: normalized,
                createdAt: Date(),
                completedAt: nil
            ))
        }
        successMessage = "Added to the backlog."
    }

    func edit(id: UUID, text: String) async throws {
        guard let normalized = FeatureBacklogSubmission.normalized(text) else { return }
        try mutate { document in
            guard let index = document.entries.firstIndex(where: { $0.id == id }) else {
                throw BacklogStoreError.entryNotFound
            }
            document.entries[index].text = normalized
        }
        successMessage = "Backlog item updated."
    }

    func complete(id: UUID) async throws {
        try mutate { document in
            guard let index = document.entries.firstIndex(where: { $0.id == id }) else {
                throw BacklogStoreError.entryNotFound
            }
            document.entries[index].completedAt = Date()
        }
        successMessage = "Backlog item completed."
    }

    func delete(id: UUID) async throws {
        try mutate { document in
            guard let index = document.entries.firstIndex(where: { $0.id == id }) else {
                throw BacklogStoreError.entryNotFound
            }
            document.entries.remove(at: index)
        }
        successMessage = "Backlog item deleted."
    }

    func chooseFile() async {
        let panel = NSSavePanel()
        panel.title = "Choose Feature Backlog"
        panel.nameFieldStringValue = fileURL.lastPathComponent
        panel.directoryURL = fileURL.deletingLastPathComponent()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        fileURL = selectedURL
        persistBookmark(for: selectedURL)
        await load()
    }

    func openFile() {
        do {
            _ = try readDocument(createIfMissing: true)
            NSWorkspace.shared.open(fileURL)
        } catch {
            errorMessage = "Could not open the backlog: \(error.localizedDescription)"
        }
    }

    private func mutate(_ update: (inout BacklogDocument) throws -> Void) throws {
        var document = try readDocument(createIfMissing: true)
        try update(&document)
        try write(document)
        entries = document.entries
        errorMessage = nil
    }

    private func readDocument(createIfMissing: Bool) throws -> BacklogDocument {
        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { fileURL.stopAccessingSecurityScopedResource() }
        }

        if !fileManager.fileExists(atPath: fileURL.path) {
            guard createIfMissing else { throw CocoaError(.fileNoSuchFile) }
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let document = BacklogDocument()
            try Data(document.render().utf8).write(to: fileURL, options: .atomic)
            return document
        }

        return try BacklogDocument.parse(String(contentsOf: fileURL, encoding: .utf8))
    }

    private func write(_ document: BacklogDocument) throws {
        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { fileURL.stopAccessingSecurityScopedResource() }
        }
        try Data(document.render().utf8).write(to: fileURL, options: .atomic)
    }

    private func persistBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: Self.bookmarkDefaultsKey)
        } catch {
            errorMessage = "The backlog works, but its custom location could not be remembered."
        }
    }

    private static func resolveBookmarkedURL(defaults: UserDefaults) -> URL? {
        guard let data = defaults.data(forKey: bookmarkDefaultsKey) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        return url
    }
}

private enum BacklogStoreError: LocalizedError {
    case entryNotFound

    var errorDescription: String? {
        "That backlog item changed outside the app. Reload and try again."
    }
}
