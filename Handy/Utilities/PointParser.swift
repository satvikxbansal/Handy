import Foundation
import CoreGraphics

struct PointingResult {
    let coordinate: CGPoint?
    let label: String?
    let screenNumber: Int?
    let cleanedText: String
}

enum PointParser {
    /// Tag must be the last thing in the assistant string (strict; fastest path).
    private static let pointPatternEndAnchored = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#
    /// Same tag may appear with trailing punctuation/newlines from the model — take the **last** match.
    private static let pointPatternLastInText = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]"#

    static func parse(from text: String) -> PointingResult {
        let cleaned = stripPointTags(from: text)

        if let result = parseUsingRegex(text, pattern: pointPatternEndAnchored, requireFullStringMatch: true) {
            return PointingResult(
                coordinate: result.coord,
                label: result.label,
                screenNumber: result.screenNumber,
                cleanedText: cleaned
            )
        }

        if let result = parseUsingRegex(text, pattern: pointPatternLastInText, requireFullStringMatch: false) {
            return PointingResult(
                coordinate: result.coord,
                label: result.label,
                screenNumber: result.screenNumber,
                cleanedText: cleaned
            )
        }

        return PointingResult(coordinate: nil, label: nil, screenNumber: nil, cleanedText: cleaned)
    }

    private static func parseUsingRegex(
        _ text: String,
        pattern: String,
        requireFullStringMatch: Bool
    ) -> (coord: CGPoint?, label: String?, screenNumber: Int?)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let match: NSTextCheckingResult?
        if requireFullStringMatch {
            match = regex.firstMatch(in: text, range: range)
        } else {
            let all = regex.matches(in: text, range: range)
            match = all.last
        }
        guard let m = match else { return nil }

        if let fullR = Range(m.range, in: text) {
            let tag = String(text[fullR]).replacingOccurrences(of: " ", with: "").lowercased()
            if tag == "[point:none]" {
                return (coord: nil, label: nil, screenNumber: nil)
            }
        }

        let xRange = Range(m.range(at: 1), in: text)
        let yRange = Range(m.range(at: 2), in: text)
        let labelRange = Range(m.range(at: 3), in: text)
        let screenRange = Range(m.range(at: 4), in: text)

        guard let xRange, let yRange,
              let x = Double(text[xRange]),
              let y = Double(text[yRange]) else {
            return nil
        }

        let label = labelRange.map { String(text[$0]) }
        let screenNumber = screenRange.flatMap { Int(text[$0]) }
        return (coord: CGPoint(x: x, y: y), label: label, screenNumber: screenNumber)
    }

    /// Removes every `[POINT:…]` tag from assistant text (chat display). Point tags must not appear in the UI.
    static func stripPointTags(from text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[POINT:[^\]]*\]"#) else {
            return text
        }
        var result = regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extracts the [SPOKEN]...[/SPOKEN] portion from a voice response.
    /// Returns (spokenText, fullDisplayText) where:
    ///   - spokenText: the content inside SPOKEN tags (for TTS)
    ///   - fullDisplayText: the entire response with SPOKEN tags removed (for chat UI)
    /// If no SPOKEN tags are found, returns the full text as both spoken and display.
    static func extractSpokenPart(from text: String) -> (spoken: String, display: String) {
        let pattern = #"\[SPOKEN\](.*?)\[/SPOKEN\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let spokenRange = Range(match.range(at: 1), in: text) else {
            return (spoken: text, display: text)
        }

        let spokenText = String(text[spokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)

        let display = regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let cleanDisplay: String
        if display.isEmpty {
            cleanDisplay = spokenText
        } else {
            cleanDisplay = spokenText + "\n\n" + display
        }

        return (spoken: spokenText, display: cleanDisplay)
    }

    /// Caps TTS length when the model ignores `[SPOKEN]` discipline or omits tags (fallback = full body).
    static func clampVoiceSpokenForTTS(_ text: String, maxChars: Int = 420) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > maxChars else { return t }
        return truncateAtSentenceBoundary(t, maxChars: maxChars) ?? (String(t.prefix(maxChars)).trimmingCharacters(in: .whitespaces) + "…")
    }

    /// Shorter cap for the green companion bubble so it stays glanceable.
    static func clampVoiceSpokenForOverlay(_ text: String, maxChars: Int = 110) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > maxChars else { return t }
        if let clipped = truncateAtSentenceBoundary(t, maxChars: maxChars), clipped.count <= maxChars {
            return clipped
        }
        return String(t.prefix(maxChars)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Returns a substring ending at the last sentence boundary at or before `maxChars`, or nil if none.
    private static func truncateAtSentenceBoundary(_ text: String, maxChars: Int) -> String? {
        guard text.count > maxChars else { return text }
        let prefix = String(text.prefix(maxChars))
        let delims = [". ", "! ", "? ", ".\n", "!\n", "?\n"]
        var bestUpper: String.Index?
        for d in delims {
            var start = prefix.startIndex
            while let r = prefix.range(of: d, range: start..<prefix.endIndex) {
                bestUpper = r.upperBound
                start = r.upperBound
            }
        }
        guard let end = bestUpper, end > prefix.startIndex else { return nil }
        let s = String(prefix[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Maps POINT coordinates from screenshot pixel space to AppKit global screen coordinates.
    static func mapToScreenCoordinates(
        point: CGPoint,
        capture: HandyScreenCapture
    ) -> CGPoint {
        let screenshotW = CGFloat(capture.screenshotWidthPx)
        let screenshotH = CGFloat(capture.screenshotHeightPx)
        let displayW = capture.displayWidthPts
        let displayH = capture.displayHeightPts
        let displayFrame = capture.displayFrame

        let clampedX = max(0, min(point.x, screenshotW))
        let clampedY = max(0, min(point.y, screenshotH))

        let displayLocalX = clampedX * (displayW / screenshotW)
        let displayLocalY = clampedY * (displayH / screenshotH)

        // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
        let appKitY = displayH - displayLocalY

        return CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )
    }
}
