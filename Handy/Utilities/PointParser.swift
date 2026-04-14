import Foundation
import CoreGraphics

struct PointingResult {
    let coordinate: CGPoint?
    let label: String?
    let screenNumber: Int?
    let cleanedText: String
}

enum PointParser {
    private static let pointPattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

    static func parse(from text: String) -> PointingResult {
        let cleaned = stripPointTags(from: text)

        guard let regex = try? NSRegularExpression(pattern: pointPattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return PointingResult(coordinate: nil, label: nil, screenNumber: nil, cleanedText: cleaned)
        }

        let xRange = Range(match.range(at: 1), in: text)
        let yRange = Range(match.range(at: 2), in: text)
        let labelRange = Range(match.range(at: 3), in: text)
        let screenRange = Range(match.range(at: 4), in: text)

        guard let xRange, let yRange,
              let x = Double(text[xRange]),
              let y = Double(text[yRange]) else {
            return PointingResult(coordinate: nil, label: nil, screenNumber: nil, cleanedText: cleaned)
        }

        let label = labelRange.map { String(text[$0]) }
        let screenNumber = screenRange.flatMap { Int(text[$0]) }

        return PointingResult(
            coordinate: CGPoint(x: x, y: y),
            label: label,
            screenNumber: screenNumber,
            cleanedText: cleaned
        )
    }

    static func stripPointTags(from text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[POINT:[^\]]*\]\s*$"#) else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
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
