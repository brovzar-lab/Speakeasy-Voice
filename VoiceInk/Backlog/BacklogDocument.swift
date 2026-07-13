import Foundation

struct BacklogEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    let createdAt: Date
    var completedAt: Date?

    var isCompleted: Bool { completedAt != nil }
}

struct BacklogDocument: Sendable {
    static let title = "# Speakeasy-Voice Feature Backlog"
    static let pendingHeader = "## Pending"
    static let completedHeader = "## Completed"

    var entries: [BacklogEntry]
    private var preservedPrefix: String
    private var preservedSuffix: String

    init(entries: [BacklogEntry] = []) {
        self.entries = entries
        self.preservedPrefix = Self.title
        self.preservedSuffix = ""
    }

    private init(entries: [BacklogEntry], preservedPrefix: String, preservedSuffix: String) {
        self.entries = entries
        self.preservedPrefix = preservedPrefix
        self.preservedSuffix = preservedSuffix
    }

    static func parse(_ source: String) throws -> BacklogDocument {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard let pendingIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == pendingHeader }),
              let completedIndex = lines[(pendingIndex + 1)...].firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == completedHeader
              }) else {
            return BacklogDocument(
                entries: [],
                preservedPrefix: normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? title
                    : normalized.trimmingCharacters(in: .whitespacesAndNewlines),
                preservedSuffix: ""
            )
        }

        let suffixStart = lines.indices.first(where: { index in
            index > completedIndex && lines[index].hasPrefix("## ")
        }) ?? lines.count

        let pendingLines = Array(lines[(pendingIndex + 1)..<completedIndex])
        let completedLines = Array(lines[(completedIndex + 1)..<suffixStart])
        let prefix = lines[..<pendingIndex].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = suffixStart < lines.count
            ? lines[suffixStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        return BacklogDocument(
            entries: parseEntries(pendingLines, completed: false) + parseEntries(completedLines, completed: true),
            preservedPrefix: prefix.isEmpty ? title : prefix,
            preservedSuffix: suffix
        )
    }

    func render() -> String {
        var sections = [preservedPrefix.trimmingCharacters(in: .whitespacesAndNewlines)]
        sections.append(Self.pendingHeader + renderEntries(entries.filter { !$0.isCompleted }))
        sections.append(Self.completedHeader + renderEntries(entries.filter(\.isCompleted)))
        if !preservedSuffix.isEmpty {
            sections.append(preservedSuffix.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }

    private static func parseEntries(_ lines: [String], completed: Bool) -> [BacklogEntry] {
        var result: [BacklogEntry] = []
        var index = 0

        while index < lines.count {
            guard let checkbox = parseCheckbox(lines[index]) else {
                index += 1
                continue
            }

            var textLines = [checkbox.text]
            var metadata: Metadata?
            index += 1

            while index < lines.count, parseCheckbox(lines[index]) == nil {
                let line = lines[index]
                if let parsedMetadata = parseMetadata(line) {
                    metadata = parsedMetadata
                } else if line.hasPrefix("  "), !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    textLines.append(String(line.dropFirst(2)))
                }
                index += 1
            }

            let createdAt = metadata?.createdAt ?? Date()
            let completedAt = completed || checkbox.checked
                ? metadata?.completedAt ?? createdAt
                : nil
            result.append(BacklogEntry(
                id: metadata?.id ?? UUID(),
                text: textLines.joined(separator: "\n"),
                createdAt: createdAt,
                completedAt: completedAt
            ))
        }
        return result
    }

    private func renderEntries(_ entries: [BacklogEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let rows = entries.map { entry -> String in
            let textLines = entry.text.components(separatedBy: .newlines)
            let first = textLines.first ?? ""
            var lines = ["- [\(entry.isCompleted ? "x" : " ")] \(first)"]
            lines.append(contentsOf: textLines.dropFirst().map { "  \($0)" })

            var metadata = "  <!-- backlog-id: \(entry.id.uuidString); added: \(formatter.string(from: entry.createdAt))"
            if let completedAt = entry.completedAt {
                metadata += "; completed: \(formatter.string(from: completedAt))"
            }
            metadata += " -->"
            lines.append(metadata)
            return lines.joined(separator: "\n")
        }
        return "\n\n" + rows.joined(separator: "\n\n")
    }

    private struct Metadata {
        let id: UUID
        let createdAt: Date
        let completedAt: Date?
    }

    private static func parseCheckbox(_ line: String) -> (checked: Bool, text: String)? {
        guard line.hasPrefix("- ["), line.count >= 6 else { return nil }
        let markerIndex = line.index(line.startIndex, offsetBy: 3)
        let marker = line[markerIndex]
        guard marker == " " || marker == "x" || marker == "X" else { return nil }
        let closeIndex = line.index(line.startIndex, offsetBy: 4)
        guard line[closeIndex] == "]" else { return nil }
        let textStart = line.index(line.startIndex, offsetBy: min(6, line.count))
        return (marker != " ", String(line[textStart...]))
    }

    private static func parseMetadata(_ line: String) -> Metadata? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<!-- backlog-id: "), trimmed.hasSuffix(" -->") else { return nil }
        let content = trimmed
            .dropFirst("<!-- ".count)
            .dropLast(" -->".count)
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var id: UUID?
        var createdAt: Date?
        var completedAt: Date?
        let formatter = ISO8601DateFormatter()
        for field in content {
            if field.hasPrefix("backlog-id: ") {
                id = UUID(uuidString: String(field.dropFirst("backlog-id: ".count)))
            } else if field.hasPrefix("added: ") {
                createdAt = formatter.date(from: String(field.dropFirst("added: ".count)))
            } else if field.hasPrefix("completed: ") {
                completedAt = formatter.date(from: String(field.dropFirst("completed: ".count)))
            }
        }
        guard let id, let createdAt else { return nil }
        return Metadata(id: id, createdAt: createdAt, completedAt: completedAt)
    }
}
