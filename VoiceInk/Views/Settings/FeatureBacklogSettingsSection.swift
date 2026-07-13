import SwiftUI

struct FeatureBacklogSettingsSection: View {
    @StateObject private var store = BacklogStore()
    @State private var draft = ""
    @State private var editingEntry: BacklogEntry?
    @State private var deletingEntry: BacklogEntry?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(minHeight: 76)
                    .padding(6)
                    .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.separator.opacity(0.7), lineWidth: 1)
                    }
                    .accessibilityLabel("New backlog item")

                HStack {
                    Text("Write a change in plain language. It will be saved for a future Codex session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add to Backlog") {
                        addDraft()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(FeatureBacklogSubmission.normalized(draft) == nil)
                }
            }
            .padding(.vertical, 4)

            if store.pendingEntries.isEmpty {
                ContentUnavailableView(
                    "No Pending Changes",
                    systemImage: "checkmark.circle",
                    description: Text("Ideas you add above will appear here.")
                )
                .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                ForEach(store.pendingEntries) { entry in
                    backlogRow(entry)
                }
            }

            HStack(spacing: 12) {
                Button("Open BACKLOG.md") {
                    store.openFile()
                }

                Button("Choose File…") {
                    Task { await store.chooseFile() }
                }

                Spacer()

                Text(store.fileURL.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(store.fileURL.path)
            }

            if let message = store.successMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } header: {
            HStack {
                Text("Feature Backlog")
                Spacer()
                Text("\(store.pendingEntries.count) pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("When you tell Codex “execute backlog,” it will show the pending items and ask which one you want built.")
        }
        .task {
            await store.load()
        }
        .sheet(item: $editingEntry) { entry in
            FeatureBacklogEditSheet(entry: entry) { text in
                Task {
                    do {
                        try await store.edit(id: entry.id, text: text)
                        editingEntry = nil
                    } catch {
                        store.errorMessage = error.localizedDescription
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete this backlog item?",
            isPresented: Binding(
                get: { deletingEntry != nil },
                set: { if !$0 { deletingEntry = nil } }
            ),
            presenting: deletingEntry
        ) { entry in
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await store.delete(id: entry.id)
                        deletingEntry = nil
                    } catch {
                        store.errorMessage = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                deletingEntry = nil
            }
        } message: { _ in
            Text("This removes it from BACKLOG.md.")
        }
    }

    @ViewBuilder
    private func backlogRow(_ entry: BacklogEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                Task {
                    do {
                        try await store.complete(id: entry.id)
                    } catch {
                        store.errorMessage = error.localizedDescription
                    }
                }
            } label: {
                Image(systemName: "circle")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help("Mark complete")

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Text(entry.createdAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Button {
                editingEntry = entry
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")

            Button(role: .destructive) {
                deletingEntry = entry
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
        .padding(.vertical, 3)
    }

    private func addDraft() {
        guard let normalized = FeatureBacklogSubmission.normalized(draft) else { return }
        Task {
            do {
                try await store.add(text: normalized)
                draft = ""
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct FeatureBacklogEditSheet: View {
    let entry: BacklogEntry
    let save: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(entry: BacklogEntry, save: @escaping (String) -> Void) {
        self.entry = entry
        self.save = save
        _text = State(initialValue: entry.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Backlog Item")
                .font(.title2.bold())

            TextEditor(text: $text)
                .frame(width: 460, height: 150)
                .padding(6)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 1)
                }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(text) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(FeatureBacklogSubmission.normalized(text) == nil)
            }
        }
        .padding(24)
    }
}
