import AppKit
import ApplicationServices

/// Result of a resolution attempt.
struct ResolvedElement {
    /// Global AppKit rect (bottom-left origin coordinate space).
    let globalRect: CGRect
    /// The AX role of the chosen element (for debugging).
    let role: String
    /// The AX title/description used to match.
    let matchedLabel: String
}

/// Resolves a workflow step's `label` + `expectedRole` to an on-screen rect using the
/// macOS Accessibility tree of the **current frontmost app** (excluding Handy itself).
///
/// Key rules (per spec):
///   - Try visible Accessibility elements first.
///   - If multiple matches, prefer the one nearest the previously resolved step.
///   - Optionally use x/y hint only as a weak fallback when AX fails entirely.
///   - Never call Claude during local step resolution.
@MainActor
final class SemanticElementResolver {

    // Deep web AX trees (Google Sheets / Docs / Figma in Chrome) need more headroom —
    // the old 2500/30 values were finding the Chrome tab bar but not the page's toolbar.
    private let maxDepth: Int = 40
    private let maxNodesVisited: Int = 6000

    /// Resolve the given step. Returns nil if nothing suitable is found on-screen.
    /// `previousRect` biases the match toward the geometrically nearest candidate.
    ///
    /// If `fallbackPID` is provided (e.g. the last-non-Handy app tracked by HandyManager),
    /// we use it instead of the frontmost process when Handy itself is frontmost —
    /// this is the common case when the user triggers a workflow by typing from the chat panel
    /// (chat panel focus = Handy is frontmost, but the user wants to drive the app behind it).
    func resolve(
        step: GuidedWorkflowStep,
        previousRect: CGRect? = nil,
        fallbackPID: pid_t? = nil
    ) -> ResolvedElement? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let ownBundleID = Bundle.main.bundleIdentifier
        let targetPID: pid_t?

        if let front = frontmost, front.bundleIdentifier != ownBundleID {
            targetPID = front.processIdentifier
        } else if let fallback = fallbackPID {
            print("🧭 Resolver — Handy is frontmost, using fallback PID \(fallback)")
            targetPID = fallback
        } else {
            print("🧭 Resolver — no usable target app (frontmost=\(frontmost?.bundleIdentifier ?? "nil"), no fallback)")
            return nil
        }

        guard let pid = targetPID else { return nil }
        let appRef = AXUIElementCreateApplication(pid)

        // BFS through windows → descendants. Collect candidates that match.
        var candidates: [ResolvedElement] = []
        var visited = 0
        var queue: [(AXUIElement, Int)] = []

        // Seed points (in order of specificity):
        //  1. focused window — most common case
        //  2. all windows — covers secondary windows
        //  3. app's direct children — CRUCIAL: popup menus (AXMenu) open as children of the app,
        //     not of any window. Without this seed, clicking e.g. Xcode's device selector and then
        //     looking for "iPhone 15 Pro" menu item ALWAYS fails.
        //  4. focused UI element — often the newly-opened menu item after a popup activates
        //  5. menu bar — app-level menus
        if let focusedAny = copyAttribute(appRef, kAXFocusedWindowAttribute as CFString) {
            let focused = focusedAny as! AXUIElement
            queue.append((focused, 0))
        }
        if let windows = copyAttribute(appRef, kAXWindowsAttribute as CFString) as? [AXUIElement] {
            for w in windows { queue.append((w, 0)) }
        }
        if let appChildren = copyAttribute(appRef, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            for child in appChildren { queue.append((child, 0)) }
        }
        if let focusedElAny = copyAttribute(appRef, kAXFocusedUIElementAttribute as CFString) {
            let focusedEl = focusedElAny as! AXUIElement
            queue.append((focusedEl, 0))
        }
        if let menuBarAny = copyAttribute(appRef, kAXMenuBarAttribute as CFString) {
            let menuBar = menuBarAny as! AXUIElement
            queue.append((menuBar, 0))
        }

        let targetLabel = step.label.lowercased()
        let expectedRole = step.expectedRole?.lowercased()

        // Collect scored candidates rather than returning first-match-wins — that was matching
        // Chrome's browser tab (AXRadioButton whose title contains "data") instead of Google
        // Sheets' Data menu button.
        var scored: [ScoredCandidate] = []
        while !queue.isEmpty, visited < maxNodesVisited {
            let (el, depth) = queue.removeFirst()
            visited += 1
            if depth >= maxDepth { continue }

            if let match = scoreElement(el, targetLabel: targetLabel, expectedRole: expectedRole) {
                scored.append(match)
            }

            if let kids = copyAttribute(el, kAXChildrenAttribute as CFString) as? [AXUIElement] {
                for k in kids { queue.append((k, depth + 1)) }
            }
        }

        if scored.isEmpty { return nil }
        let best = pickBest(scored, previousRect: previousRect)
        return best?.element
    }

    // MARK: - Scored matching

    private struct ScoredCandidate {
        let element: ResolvedElement
        /// Match quality:
        ///   3 = exact label equals target
        ///   2 = whole-word match (all target tokens appear as words in the label)
        ///   1 = prefix or suffix match
        ///   0 = substring match (only allowed for long targets to avoid "data" matching tab titles)
        let matchQuality: Int
        /// Role specificity: 1 if we matched an explicitly-expected role, 0 otherwise.
        /// Breaks ties between e.g. an AXMenuButton and an AXRadioButton that both have the label.
        let roleSpecificity: Int
    }

    private func scoreElement(_ el: AXUIElement, targetLabel: String, expectedRole: String?) -> ScoredCandidate? {
        // Only consider elements that have a frame (visible geometry).
        guard let rect = frame(of: el) else { return nil }
        if rect.width < 4 || rect.height < 4 { return nil }

        let role = (copyAttribute(el, kAXRoleAttribute as CFString) as? String)?.lowercased() ?? ""
        let roleOk: Bool
        let roleScore: Int
        if let expected = expectedRole, !expected.isEmpty {
            roleOk = role.contains(expected) || mapRoleSynonyms(expected).contains(where: { role.contains($0) })
            roleScore = roleOk ? 1 : 0
        } else {
            roleOk = isClickableRole(role)
            roleScore = 0
        }
        guard roleOk else { return nil }

        // Gather all candidate label attributes.
        let rawCandidates: [String] = [
            (copyAttribute(el, kAXTitleAttribute as CFString) as? String) ?? "",
            (copyAttribute(el, kAXDescriptionAttribute as CFString) as? String) ?? "",
            (copyAttribute(el, kAXHelpAttribute as CFString) as? String) ?? "",
            (copyAttribute(el, kAXValueAttribute as CFString) as? String) ?? "",
            (copyAttribute(el, kAXRoleDescriptionAttribute as CFString) as? String) ?? ""
        ]
        var identifier = ""
        var idValue: AnyObject?
        if AXUIElementCopyAttributeValue(el, "AXIdentifier" as CFString, &idValue) == .success,
           let s = idValue as? String { identifier = s }
        let allLabels = (rawCandidates + [identifier])
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if allLabels.isEmpty { return nil }

        let target = targetLabel.lowercased()
        let targetTokens = Set(
            target.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
        )

        var bestQuality = -1
        var bestMatchLabel = ""

        // Tier 3: exact.
        for label in allLabels where label == target {
            bestQuality = 3
            bestMatchLabel = label
            break
        }

        // Tier 2: whole-word match — every target token appears as a word in the label.
        if bestQuality < 2, !targetTokens.isEmpty {
            for label in allLabels {
                let labelTokens = Set(
                    label.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
                )
                if targetTokens.isSubset(of: labelTokens) {
                    bestQuality = 2
                    bestMatchLabel = label
                    break
                }
            }
        }

        // Tier 1: prefix or suffix match.
        if bestQuality < 1 {
            for label in allLabels {
                if label.hasPrefix(target) || label.hasSuffix(target) {
                    bestQuality = 1
                    bestMatchLabel = label
                    break
                }
            }
        }

        // Tier 0: plain substring — but ONLY for long targets, so a 4-char target like "data"
        // cannot match a Chrome tab title "latest non-aff ordered catalog data ...".
        //
        // Intent: a short target is probably a button label (Data, Send, Compose); those should
        // match exactly or as a word, never as a substring of a long sentence.
        if bestQuality < 0 && target.count >= 8 {
            for label in allLabels where label.contains(target) {
                bestQuality = 0
                bestMatchLabel = label
                break
            }
        }

        guard bestQuality >= 0 else { return nil }
        return ScoredCandidate(
            element: ResolvedElement(globalRect: rect, role: role, matchedLabel: bestMatchLabel),
            matchQuality: bestQuality,
            roleSpecificity: roleScore
        )
    }

    private func pickBest(_ scored: [ScoredCandidate], previousRect: CGRect?) -> ScoredCandidate? {
        let sorted = scored.sorted { a, b in
            // 1. Higher match quality wins.
            if a.matchQuality != b.matchQuality { return a.matchQuality > b.matchQuality }
            // 2. More specific role wins.
            if a.roleSpecificity != b.roleSpecificity { return a.roleSpecificity > b.roleSpecificity }
            // 3. Closest to previous resolved rect wins (geometric continuity).
            if let previous = previousRect {
                return distance(a.element.globalRect, previous) < distance(b.element.globalRect, previous)
            }
            // 4. Smallest area wins (a tight control beats a huge container).
            return score(rect: a.element.globalRect) < score(rect: b.element.globalRect)
        }
        if let top = sorted.first {
            print("🧭   pick — quality=\(top.matchQuality) role=\(top.element.role) rect=\(top.element.globalRect) matched=\"\(top.element.matchedLabel)\" (from \(sorted.count) candidates)")
        }
        return sorted.first
    }

    private func mapRoleSynonyms(_ expected: String) -> [String] {
        switch expected {
        case "button": return ["axbutton", "axmenubutton"]
        case "menu": return ["axmenu", "axmenuitem", "axmenubaritem"]
        case "item": return ["axmenuitem", "axrow", "axcell", "axlistitem"]
        case "tab": return ["axtab", "axradiobutton"]
        case "field": return ["axtextfield", "axsearchfield", "axcombobox", "axtextarea"]
        case "toolbaritem": return ["axtoolbaritem", "axbutton"]
        case "link": return ["axlink"]
        case "checkbox": return ["axcheckbox"]
        default: return []
        }
    }

    private func isClickableRole(_ role: String) -> Bool {
        let clickable: Set<String> = [
            "axbutton", "axmenubutton", "axmenu", "axmenuitem", "axmenubaritem",
            "axtab", "axtabgroup", "axcheckbox", "axradiobutton", "axlink",
            "axtoolbaritem", "axcell", "axrow", "axlistitem",
            "axtextfield", "axsearchfield", "axcombobox", "axtextarea",
            "axpopupbutton"
        ]
        return clickable.contains(role)
    }

    // MARK: - AX helpers

    private func copyAttribute(_ el: AXUIElement, _ attr: CFString) -> AnyObject? {
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(el, attr, &value)
        return status == .success ? value : nil
    }

    /// Returns the element's global AppKit rect, if it has AXPosition + AXSize.
    private func frame(of el: AXUIElement) -> CGRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posRef = posValue, let sizeRef = sizeValue else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable:next force_cast
        let axPos = posRef as! AXValue
        // swiftlint:disable:next force_cast
        let axSize = sizeRef as! AXValue
        guard AXValueGetValue(axPos, .cgPoint, &origin),
              AXValueGetValue(axSize, .cgSize, &size) else {
            return nil
        }

        // AX positions use CG coordinates (top-left origin). Convert to AppKit (bottom-left origin).
        let totalHeight = NSScreen.screens.first?.frame.height ?? size.height
        let appKitY = totalHeight - origin.y - size.height
        return CGRect(x: origin.x, y: appKitY, width: size.width, height: size.height)
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = a.midX - b.midX
        let dy = a.midY - b.midY
        return sqrt(dx * dx + dy * dy)
    }

    /// Prefer small-ish controls to the whole window; huge rects score worse.
    private func score(rect: CGRect) -> CGFloat {
        let area = rect.width * rect.height
        if area <= 0 { return .greatestFiniteMagnitude }
        return area
    }
}
