# In-App Feature Backlog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Settings editor that safely maintains the repository’s `BACKLOG.md`, plus an agent rule for reviewing selected items when Billy says “execute backlog.”

**Architecture:** Pure Markdown parsing and rendering live in `BacklogDocument`; file resolution and atomic persistence live in `BacklogStore`; SwiftUI only binds to published store state. The store reloads before every mutation so terminal edits are preserved.

**Tech Stack:** Swift 5, SwiftUI, Foundation file APIs, security-scoped bookmarks, Swift Testing.

## Global Constraints

- Default file is `~/CODE/SPEAKEASY-VOICE/BACKLOG.md`, derived from the current home directory.
- Never discard the draft after a file error.
- Preserve prose outside the managed Pending and Completed sections.
- “Execute backlog” lists pending items and asks which to implement; it never executes all automatically.
- New Swift files under `VoiceInk/` are added automatically by the synchronized Xcode group.

---

### Task 1: Markdown backlog domain model

**Files:**
- Create: `VoiceInk/Backlog/BacklogDocument.swift`
- Modify: `VoiceInkTests/VoiceInkTests.swift`

**Interfaces:**
- Produces: `BacklogEntry`, `BacklogDocument.parse(_:)`, and `BacklogDocument.render()`.

- [ ] **Step 1: Write failing round-trip tests**

```swift
@Test func backlogDocumentRoundTripsPendingCompletedAndMultilineEntries() throws {
    let entry = BacklogEntry(id: UUID(), text: "Make the button red.\nKeep contrast accessible.", createdAt: Date(timeIntervalSince1970: 1), completedAt: nil)
    let rendered = BacklogDocument(preamble: "# Speakeasy-Voice Feature Backlog\n", entries: [entry], trailingContent: "").render()
    #expect(try BacklogDocument.parse(rendered).entries == [entry])
}

@Test func backlogDocumentPreservesUnknownProse() throws {
    let source = "# Notes\nKeep this sentence.\n\n## Pending\n\n- [ ] Change the icon.\n"
    #expect(try BacklogDocument.parse(source).render().contains("Keep this sentence."))
}
```

- [ ] **Step 2: Run `make test` and verify a compile failure for the missing types.**

- [ ] **Step 3: Implement the model and parser**

```swift
struct BacklogEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    let createdAt: Date
    var completedAt: Date?
}

struct BacklogDocument: Equatable, Sendable {
    var preamble: String
    var entries: [BacklogEntry]
    var trailingContent: String
    static func parse(_ source: String) throws -> BacklogDocument
    func render() -> String
}
```

Accept metadata-free checkboxes, continuation lines, and ISO 8601 comments. Render deterministic Pending and Completed sections with exactly one final newline.

- [ ] **Step 4: Run `make test`, then commit**

```bash
git add VoiceInk/Backlog/BacklogDocument.swift VoiceInkTests/VoiceInkTests.swift
git commit -m "Add Markdown feature backlog model"
```

---

### Task 2: File location and atomic store

**Files:**
- Create: `VoiceInk/Backlog/BacklogStore.swift`
- Modify: `VoiceInkTests/VoiceInkTests.swift`

**Interfaces:**
- Consumes: `BacklogDocument` and `BacklogEntry`.
- Produces: `BacklogFileLocator.defaultURL(homeDirectory:)` and `BacklogStore.load/add/edit/complete/delete`.

- [ ] **Step 1: Add failing path and reload-before-write tests**

```swift
@Test func backlogDefaultPathUsesProvidedHomeDirectory() {
    let home = URL(fileURLWithPath: "/Users/example")
    #expect(BacklogFileLocator.defaultURL(homeDirectory: home).path == "/Users/example/CODE/SPEAKEASY-VOICE/BACKLOG.md")
}
```

- [ ] **Step 2: Run `make test` and verify the locator is missing.**

- [ ] **Step 3: Implement the locator and store**

```swift
enum BacklogFileLocator {
    static func defaultURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL
}

@MainActor final class BacklogStore: ObservableObject {
    @Published private(set) var entries: [BacklogEntry] = []
    @Published private(set) var fileURL: URL
    @Published var errorMessage: String?
    func load() async
    func add(text: String) async throws
    func edit(id: UUID, text: String) async throws
    func complete(id: UUID) async throws
    func delete(id: UUID) async throws
    func chooseFile() async
    func openFile()
}
```

Every mutation reloads the latest file, changes one UUID, writes atomically, and reloads published state. Persist selected-file access under `featureBacklog.securityScopedBookmark`.

- [ ] **Step 4: Run `make test`, then commit**

```bash
git add VoiceInk/Backlog/BacklogStore.swift VoiceInkTests/VoiceInkTests.swift
git commit -m "Add atomic feature backlog storage"
```

---

### Task 3: Settings UI and agent workflow

**Files:**
- Create: `VoiceInk/Views/Settings/FeatureBacklogSettingsSection.swift`
- Create: `BACKLOG.md`
- Modify: `VoiceInk/Views/Settings/SettingsView.swift`
- Modify: `AGENTS.md`
- Modify: `VoiceInkTests/VoiceInkTests.swift`

- [ ] **Step 1: Add a failing submission-policy test**

```swift
@Test func backlogSubmissionTrimsTextAndRejectsEmptyDrafts() {
    #expect(FeatureBacklogSubmission.normalized("   ") == nil)
    #expect(FeatureBacklogSubmission.normalized("  Make it red. \n") == "Make it red.")
}
```

- [ ] **Step 2: Implement the focused Settings section**

```swift
enum FeatureBacklogSubmission {
    static func normalized(_ draft: String) -> String? {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct FeatureBacklogSettingsSection: View {
    @StateObject private var store = BacklogStore()
    @State private var draft = ""
    var body: some View
}
```

Include the editor, Add button, pending rows, edit/complete/delete controls, delete confirmation, count, file controls, success feedback, and persistent error state. Mount it above Diagnostics in `SettingsView`.

- [ ] **Step 3: Add the initial document and `AGENTS.md` contract**

```markdown
# Speakeasy-Voice Feature Backlog

## Pending

## Completed
```

The agent contract reads the file, numbers pending items, asks which to execute, implements only selected items, and completes them only after proof.

- [ ] **Step 4: Run `make test`, then commit**

```bash
git add VoiceInk/Views/Settings/FeatureBacklogSettingsSection.swift VoiceInk/Views/Settings/SettingsView.swift VoiceInkTests/VoiceInkTests.swift BACKLOG.md AGENTS.md
git commit -m "Add feature backlog to Settings"
```

---

### Task 4: Backlog verification

- [ ] Run `make local` and launch `~/Downloads/Speakeasy-Voice.app`.
- [ ] In Settings, add, edit, complete, and delete a temporary item; verify each operation in `BACKLOG.md`.
- [ ] Remove only the temporary verification entry.
- [ ] Run `git diff --check`, `make test`, and `git status --short`.
