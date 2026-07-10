import Foundation

/// Post-processing filter that runs on every AI-enhanced transcript before it
/// reaches the user. Two jobs:
///
/// 1. Strip reasoning-model scaffolding (`<thinking>`, `<reasoning>`) — those
///    tags leak from the model when it thinks out loud.
/// 2. Strip conversational preambles ("Okay, here's the polished text:", etc.)
///    that small local LLMs like `gemma3:4b` insert even when the prompt says
///    "no preamble". This is the belt-and-suspenders fix — prompt improvements
///    catch it at the source, this catches whatever slips through.
struct AIEnhancementOutputFilter {
    static func filter(_ text: String) -> String {
        var processedText = text

        // 1. Strip inline reasoning/thinking blocks.
        let blockPatterns = [
            #"(?s)<thinking>(.*?)</thinking>"#,
            #"(?s)<think>(.*?)</think>"#,
            #"(?s)<reasoning>(.*?)</reasoning>"#
        ]
        for pattern in blockPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(processedText.startIndex..., in: processedText)
                processedText = regex.stringByReplacingMatches(
                    in: processedText, options: [], range: range, withTemplate: ""
                )
            }
        }

        processedText = processedText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 2. Strip a leading conversational preamble.
        processedText = stripLeadingPreamble(processedText)

        // 3. If the whole response is wrapped in matched quotes, unwrap it.
        processedText = unwrapEnclosingQuotes(processedText)

        return processedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Preamble stripping

    /// Patterns that match a whole "preamble line" produced by chatty LLMs.
    /// Each pattern must be anchored to the start (`^`) and match the entire
    /// first sentence / line up to (and including) a colon or period, plus any
    /// trailing whitespace and newlines.
    ///
    /// The list is intentionally conservative — we only strip clearly
    /// meta-commentary phrases that could not plausibly be the intended output.
    /// (Not `Here I am` — that could be a real sentence. But `Here's the
    /// polished text:` obviously is not.)
    private static let preamblePatterns: [String] = [
        // "Okay, here's the polished text based on your dictation:"
        // "Sure! Here's the cleaned-up version:"
        // "Here's your text:"
        // "Here is the polished version:"
        #"^(?:okay|ok|sure|alright|got it|understood)[,!.]?\s*(?:here(?:'s| is|s)?|below is)\b[^\n]{0,120}:\s*\n+"#,
        #"^here(?:'s| is|s)?\s+(?:the|your|a|an)\s+[^\n]{0,120}:\s*\n+"#,
        #"^below\s+is\s+(?:the|your|a|an)\s+[^\n]{0,120}:\s*\n+"#,
        // "Polished text:" / "Cleaned up:" / "Result:" as a standalone label line.
        #"^(?:polished(?:\s+text)?|cleaned(?:\s+up|-up)?(?:\s+version)?|final(?:\s+text)?|output|result|response)\s*:\s*\n+"#,
        // Softer stand-alone opener: "Okay," / "Sure!" / "Alright," on its own line.
        #"^(?:okay|ok|sure|alright)[,!.]\s*\n+"#
    ]

    private static func stripLeadingPreamble(_ text: String) -> String {
        var result = text
        var iterations = 0
        // Loop so we strip "Okay,\nHere's the text:\n" as two peels.
        while iterations < 3 {
            var didStrip = false
            for pattern in preamblePatterns {
                guard let regex = try? NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive, .anchorsMatchLines]
                ) else { continue }
                let range = NSRange(result.startIndex..., in: result)
                guard let match = regex.firstMatch(in: result, options: [.anchored], range: range) else { continue }
                if let matchRange = Range(match.range, in: result) {
                    result = String(result[matchRange.upperBound...])
                    didStrip = true
                    break
                }
            }
            if !didStrip { break }
            iterations += 1
        }
        return result
    }

    // MARK: - Quote unwrapping

    /// If the entire response is wrapped in a matched pair of quotes and the
    /// content doesn't itself contain that quote, strip them. Common failure
    /// mode when the model treats "return only the text" as "return the text
    /// as a quoted string".
    private static func unwrapEnclosingQuotes(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return text }
        let pairs: [(Character, Character)] = [
            ("\"", "\""),
            ("'", "'"),
            ("\u{201C}", "\u{201D}"), // curly double
            ("\u{2018}", "\u{2019}")  // curly single
        ]
        for (open, close) in pairs where trimmed.first == open && trimmed.last == close {
            let inner = String(trimmed.dropFirst().dropLast())
            // Only unwrap if the inner text doesn't contain the same quote —
            // otherwise we'd be corrupting legitimate content.
            if !inner.contains(open) && !inner.contains(close) {
                return inner
            }
        }
        return text
    }
}
