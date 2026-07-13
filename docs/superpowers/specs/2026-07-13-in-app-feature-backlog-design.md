# In-App Feature Backlog Design

**Date:** 2026-07-13
**Status:** Approved design

## Purpose

Speakeasy-Voice will provide a small, low-friction place for Billy to capture product changes without leaving the app. Entries are written immediately to a Markdown backlog in the repository. Later, Billy can tell Codex “execute backlog”; Codex will show the pending entries and ask which ones to implement.

This feature captures requests. It does not automatically edit code, invoke an agent, or execute backlog items from inside the app.

## User Experience

Settings gains a **Feature Backlog** section containing:

- A multi-line text editor with the placeholder “Describe something you want changed…”
- An **Add to Backlog** button, enabled only when the trimmed text is non-empty
- A compact list of pending entries, newest first
- Per-entry controls for edit, mark complete, and delete
- The pending-item count
- **Open Backlog File** and **Choose Backlog File** buttons
- A short explanation: “Tell Codex ‘execute backlog’ to review and build selected items.”

After an entry is added, the editor clears and a brief confirmation appears. File errors remain visible in the section and never discard the text currently being edited.

Deleting an entry requires confirmation. Completing an entry does not delete it; it moves it to the completed section of the Markdown file. Editing preserves the entry identifier and original creation date.

## Storage Location

The default file is:

```text
~/CODE/SPEAKEASY-VOICE/BACKLOG.md
```

The path is derived from `FileManager.default.homeDirectoryForCurrentUser`; the absolute username is never hardcoded. If the default repository is unavailable, the UI explains the problem and offers **Choose Backlog File** rather than silently writing elsewhere.

The selected file location is persisted in UserDefaults. A user-selected location uses a security-scoped bookmark so the file remains available if a future signed build enables tighter sandboxing. **Choose Backlog File** may select an existing Markdown file or create `BACKLOG.md` in a chosen folder.

## Markdown Format

The file is human-readable and agent-readable:

```markdown
# Speakeasy-Voice Feature Backlog

## Pending

- [ ] Make the recording button red.
  <!-- backlog-id: 7B9C...; added: 2026-07-13T15:20:00Z -->

## Completed

- [x] Add a version number to the sidebar.
  <!-- backlog-id: 42A1...; added: 2026-07-11T19:00:00Z; completed: 2026-07-11T22:00:00Z -->
```

Multi-line descriptions are stored as indented continuation lines beneath the checkbox. Metadata stays in an HTML comment so normal Markdown viewers remain clean. Identifiers use UUID strings; timestamps use ISO 8601 UTC.

The parser accepts checkboxes without metadata and assigns missing identifiers in memory, writing them on the next mutation. Unknown prose outside the managed `Pending` and `Completed` sections is preserved. Writes are atomic: render to a sibling temporary file, then replace the destination. The store reloads before each mutation so edits made by Codex or a text editor are not overwritten by stale app state.

## Components

### `BacklogEntry`

A value type with:

- `id: UUID`
- `text: String`
- `createdAt: Date`
- `completedAt: Date?`
- Derived `isCompleted: Bool`

### `BacklogDocument`

Owns parsing and rendering of the Markdown document. It separates managed entries from preserved surrounding prose and provides deterministic output for tests.

### `BacklogFileLocator`

Resolves the default repository file, persists a chosen file bookmark, and returns actionable errors when access is unavailable.

### `BacklogStore`

An `@MainActor ObservableObject` used by SwiftUI. It loads entries, adds, edits, completes, and deletes entries. File parsing and writing run away from the main actor; published UI state is updated on the main actor.

### `FeatureBacklogSettingsSection`

A focused SwiftUI view embedded near the bottom of `SettingsView`, above Diagnostics. Keeping the UI in its own file prevents the already-large general settings view from gaining storage and parsing responsibilities.

## “Execute Backlog” Agent Contract

`AGENTS.md` gains a project workflow rule for the exact natural-language instruction **execute backlog**:

1. Read `BACKLOG.md`.
2. Present the pending entries as a numbered list.
3. Ask Billy which entries to execute.
4. Plan and implement only the selected entries, following the repository’s existing approval and verification workflow.
5. Mark an entry complete only after implementation, tests, and proof succeed.
6. Preserve unselected pending entries and all completed history.

The command never interprets “execute backlog” as authorization to build every pending entry.

## Error Handling

- Missing file: create the standard document when its parent repository exists.
- Missing repository: keep the draft text and offer file selection.
- Malformed managed entry: preserve its source text and show a non-destructive warning.
- Concurrent external edit: reload immediately before mutation, then apply the requested change by UUID.
- Write failure: leave the on-disk file unchanged and retain the editor or entry state in the UI.
- Lost bookmark permission: prompt the user to choose the file again.

## Testing

Unit tests cover:

- Empty document creation
- Pending and completed round trips
- Multi-line entry round trips
- Unknown prose preservation
- Importing checkboxes without metadata
- Edit, complete, and delete by UUID
- Reload-before-write behavior after an external edit
- Atomic-write failure leaving the original file intact
- Default path derivation without a hardcoded username

UI-level tests cover disabled empty submission, successful submission, draft preservation after a write error, delete confirmation, and pending-count updates.

## Out of Scope

- Running Codex from inside Speakeasy-Voice
- Automatic prioritization or AI rewriting of requests
- Attachments, screenshots, labels, estimates, and due dates
- Cloud synchronization beyond whatever synchronization the chosen Markdown file already receives
