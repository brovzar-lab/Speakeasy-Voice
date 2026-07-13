import Foundation

struct ReadAloudSegment: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    let characterRange: Range<Int>
}

struct ReadAloudSegmentPlan: Equatable, Sendable {
    let originalText: String
    let segments: [ReadAloudSegment]

    var reconstructedText: String {
        segments.map(\.text).joined()
    }

    func text(fromSegment index: Int) -> String {
        guard index >= 0, index < segments.count else { return "" }
        return segments[index...].map(\.text).joined()
    }
}

enum ReadAloudSegmentPlanner {
    static let singleRequestThreshold = 200
    static let targetCharacters = 600
    static let maximumCharacters = 750
    private static let preferredMinimumCharacters = 400

    static func plan(
        text: String,
        maxCharacters: Int = maximumCharacters
    ) -> ReadAloudSegmentPlan {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ReadAloudSegmentPlan(originalText: "", segments: [])
        }

        let characters = Array(trimmed)
        let cap = max(1, maxCharacters)
        var segments: [ReadAloudSegment] = []
        var start = 0

        while start < characters.count {
            let remaining = characters.count - start
            let end: Int
            if remaining <= cap {
                end = characters.count
            } else {
                let maximumEnd = min(characters.count, start + cap)
                let minimumEnd = min(maximumEnd, start + min(preferredMinimumCharacters, cap))
                let targetEnd = min(maximumEnd, start + min(targetCharacters, cap))
                end = paragraphBoundary(
                    in: characters,
                    start: start,
                    minimumEnd: minimumEnd,
                    maximumEnd: maximumEnd
                ) ?? preferredBoundary(
                    in: characters,
                    start: start,
                    minimumEnd: minimumEnd,
                    maximumEnd: targetEnd
                ) ?? preferredBoundary(
                    in: characters,
                    start: start,
                    minimumEnd: minimumEnd,
                    maximumEnd: maximumEnd
                ) ?? maximumEnd
            }

            let segmentText = String(characters[start..<end])
            segments.append(ReadAloudSegment(
                id: segments.count,
                text: segmentText,
                characterRange: start..<end
            ))
            start = end
        }

        return ReadAloudSegmentPlan(originalText: trimmed, segments: segments)
    }

    private static func preferredBoundary(
        in characters: [Character],
        start: Int,
        minimumEnd: Int,
        maximumEnd: Int
    ) -> Int? {
        let candidates = Array(minimumEnd...maximumEnd)

        if let sentence = candidates.last(where: { end in
            guard end > start else { return false }
            let previous = characters[end - 1]
            guard previous == "." || previous == "?" || previous == "!" else { return false }
            return end == characters.count || characters[end].isWhitespace
        }) {
            return consumeWhitespace(after: sentence, characters: characters, maximumEnd: maximumEnd)
        }

        if let whitespace = candidates.last(where: { characters[$0 - 1].isWhitespace }) {
            return whitespace
        }

        return nil
    }

    private static func paragraphBoundary(
        in characters: [Character],
        start: Int,
        minimumEnd: Int,
        maximumEnd: Int
    ) -> Int? {
        (minimumEnd...maximumEnd).last(where: { end in
            guard end - start >= 2 else { return false }
            var cursor = end - 1
            var newlineCount = 0
            while cursor >= start, characters[cursor].isWhitespace {
                if characters[cursor].isNewline { newlineCount += 1 }
                if newlineCount >= 2 { return true }
                if cursor == start { break }
                cursor -= 1
            }
            return false
        })
    }

    private static func consumeWhitespace(
        after boundary: Int,
        characters: [Character],
        maximumEnd: Int
    ) -> Int {
        var end = boundary
        while end < maximumEnd, characters[end].isWhitespace {
            end += 1
        }
        return end
    }
}

private extension Character {
    var isNewline: Bool {
        self == "\n" || self == "\r"
    }
}
