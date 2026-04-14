import Foundation
import ScreenCaptureKit
import AppKit

enum ScreenCaptureError: LocalizedError {
    case noDisplaysFound
    case captureFailedForAllDisplays
    case jpegEncodingFailed
    case screenRecordingNotAllowed

    var errorDescription: String? {
        switch self {
        case .noDisplaysFound: return "No displays found for capture"
        case .captureFailedForAllDisplays: return "Screen capture failed on all displays"
        case .jpegEncodingFailed: return "Failed to encode screenshot as JPEG"
        case .screenRecordingNotAllowed:
            return "Screen Recording permission required. Go to System Settings > Privacy & Security > Screen Recording and enable Handy."
        }
    }
}

enum ScreenCaptureService {
    private static let maxDimension = 1280
    private static let jpegQuality: CGFloat = 0.8

    private static func fetchShareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if isPermissionError(error) {
                throw ScreenCaptureError.screenRecordingNotAllowed
            }
            throw error
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let desc = error.localizedDescription.lowercased()
        let nsError = error as NSError

        if desc.contains("declined") || desc.contains("tcc") || desc.contains("permission") ||
           desc.contains("not authorized") || desc.contains("denied") {
            return true
        }

        // SCStreamError.userDeclined = -3801
        if nsError.domain == "com.apple.screencapturekit.error" || nsError.code == -3801 {
            return true
        }

        return false
    }

    /// Captures all connected screens, cursor screen first.
    static func captureAllScreens() async throws -> [HandyScreenCapture] {
        let content = try await fetchShareableContent()

        guard !content.displays.isEmpty else {
            throw ScreenCaptureError.noDisplaysFound
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleID }

        let mouseLocation = NSEvent.mouseLocation
        let cursorDisplayIndex = content.displays.firstIndex { display in
            let frame = CGRect(
                x: CGFloat(display.frame.origin.x),
                y: CGFloat(display.frame.origin.y),
                width: CGFloat(display.width),
                height: CGFloat(display.height)
            )
            let flippedY = NSScreen.screens.first.map { $0.frame.height - mouseLocation.y } ?? mouseLocation.y
            return frame.contains(CGPoint(x: mouseLocation.x, y: flippedY))
        } ?? 0

        var sorted = Array(content.displays.enumerated())
        if let idx = sorted.firstIndex(where: { $0.offset == cursorDisplayIndex }) {
            let item = sorted.remove(at: idx)
            sorted.insert(item, at: 0)
        }

        var results: [HandyScreenCapture] = []

        for (displayIndex, display) in sorted {
            do {
                let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
                let config = SCStreamConfiguration()

                let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
                if display.width > display.height {
                    config.width = maxDimension
                    config.height = Int(CGFloat(maxDimension) / aspectRatio)
                } else {
                    config.height = maxDimension
                    config.width = Int(CGFloat(maxDimension) * aspectRatio)
                }

                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                guard let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality]) else {
                    continue
                }

                let isCursor = displayIndex == cursorDisplayIndex
                let screenLabel: String
                if sorted.count == 1 {
                    screenLabel = "user's screen (cursor is here)"
                } else if isCursor {
                    screenLabel = "screen \(displayIndex + 1) of \(sorted.count) — cursor is on this screen (primary focus)"
                } else {
                    screenLabel = "screen \(displayIndex + 1) of \(sorted.count) — secondary screen"
                }

                let nsScreen = NSScreen.screens.first { screen in
                    Int(screen.frame.origin.x) == Int(display.frame.origin.x) &&
                    Int(screen.frame.origin.y) == Int(display.frame.origin.y)
                }
                let displayFrame = nsScreen?.frame ?? CGRect(
                    x: CGFloat(display.frame.origin.x),
                    y: CGFloat(display.frame.origin.y),
                    width: CGFloat(display.width),
                    height: CGFloat(display.height)
                )
                let displayPtsWidth = nsScreen?.frame.width ?? CGFloat(display.width)
                let displayPtsHeight = nsScreen?.frame.height ?? CGFloat(display.height)

                results.append(HandyScreenCapture(
                    imageData: jpegData,
                    label: screenLabel,
                    isCursorScreen: isCursor,
                    screenshotWidthPx: config.width,
                    screenshotHeightPx: config.height,
                    displayWidthPts: displayPtsWidth,
                    displayHeightPts: displayPtsHeight,
                    displayFrame: displayFrame
                ))
            } catch {
                continue
            }
        }

        guard !results.isEmpty else {
            throw ScreenCaptureError.captureFailedForAllDisplays
        }

        return results
    }

    /// Captures only the focused window of the frontmost application.
    static func captureFocusedWindow() async throws -> [HandyScreenCapture] {
        let content = try await fetchShareableContent()
        let ownBundleID = Bundle.main.bundleIdentifier

        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return try await captureAllScreens()
        }

        let focusedWindow = content.windows.first { window in
            guard let appBundleID = window.owningApplication?.bundleIdentifier else { return false }
            guard appBundleID != ownBundleID else { return false }
            guard appBundleID == frontmostApp.bundleIdentifier else { return false }
            return window.isOnScreen && window.frame.width > 100 && window.frame.height > 100
        }

        guard let targetWindow = focusedWindow else {
            return try await captureAllScreens()
        }

        let filter = SCContentFilter(desktopIndependentWindow: targetWindow)
        let config = SCStreamConfiguration()

        let windowWidth = Int(targetWindow.frame.width)
        let windowHeight = Int(targetWindow.frame.height)
        let aspectRatio = CGFloat(windowWidth) / CGFloat(windowHeight)

        if windowWidth > windowHeight {
            config.width = min(windowWidth, maxDimension)
            config.height = Int(CGFloat(config.width) / aspectRatio)
        } else {
            config.height = min(windowHeight, maxDimension)
            config.width = Int(CGFloat(config.height) * aspectRatio)
        }

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality]) else {
            throw ScreenCaptureError.jpegEncodingFailed
        }

        let appName = frontmostApp.localizedName ?? "Unknown"
        let windowTitle = targetWindow.title ?? ""
        let windowLabel = windowTitle.isEmpty
            ? "focused window (\(appName))"
            : "focused window (\(appName) — \(windowTitle))"

        let mouseLocation = NSEvent.mouseLocation
        let isCursorScreen = targetWindow.frame.contains(CGPoint(
            x: mouseLocation.x,
            y: NSScreen.screens.first.map { $0.frame.height - mouseLocation.y } ?? mouseLocation.y
        ))

        let totalScreenHeight = NSScreen.screens.first?.frame.height ?? CGFloat(windowHeight)
        let windowAppKitOriginY = totalScreenHeight - targetWindow.frame.origin.y - targetWindow.frame.height
        let windowFrame = CGRect(
            x: targetWindow.frame.origin.x,
            y: windowAppKitOriginY,
            width: CGFloat(windowWidth),
            height: CGFloat(windowHeight)
        )

        let nsScreen = NSScreen.screens.first { screen in
            screen.frame.contains(CGPoint(
                x: targetWindow.frame.midX,
                y: NSScreen.screens.first.map { $0.frame.height - targetWindow.frame.midY } ?? targetWindow.frame.midY
            ))
        }
        let displayPtsWidth = nsScreen?.frame.width ?? CGFloat(windowWidth)
        let displayPtsHeight = nsScreen?.frame.height ?? CGFloat(windowHeight)

        return [HandyScreenCapture(
            imageData: jpegData,
            label: windowLabel,
            isCursorScreen: isCursorScreen,
            screenshotWidthPx: config.width,
            screenshotHeightPx: config.height,
            displayWidthPts: displayPtsWidth,
            displayHeightPts: displayPtsHeight,
            displayFrame: windowFrame
        )]
    }

    /// Returns the name of the currently focused app/window.
    static func focusedAppInfo() -> (appName: String, windowTitle: String, bundleID: String?) {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return ("Unknown", "", nil)
        }
        let appName = frontmost.localizedName ?? "Unknown"
        let bundleID = frontmost.bundleIdentifier

        var windowTitle = ""
        let appRef = AXUIElementCreateApplication(frontmost.processIdentifier)
        var windowValue: AnyObject?
        if AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &windowValue) == .success {
            var titleValue: AnyObject?
            if AXUIElementCopyAttributeValue(windowValue as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success {
                windowTitle = titleValue as? String ?? ""
            }
        }

        return (appName, windowTitle, bundleID)
    }

    /// Whether the given bundle ID belongs to a web browser.
    static func isBrowserBundleID(_ bundleID: String?) -> Bool {
        guard let bid = bundleID?.lowercased() else { return false }
        return bid.contains("com.google.chrome") ||
               bid.contains("com.apple.safari") ||
               bid.contains("org.mozilla.firefox") ||
               bid.contains("com.brave.browser") ||
               bid.contains("com.microsoft.edgemac") ||
               bid.contains("company.thebrowser.browser") ||  // Arc
               bid.contains("com.operasoftware.opera")
    }

    /// Attempts to read the current URL from a browser's address bar via the Accessibility tree.
    /// Works for Chrome, Safari, Arc, and most Chromium-based browsers.
    /// Returns nil if AX access fails or the browser isn't supported.
    static func browserURL() -> String? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              isBrowserBundleID(frontmost.bundleIdentifier) else { return nil }

        let appRef = AXUIElementCreateApplication(frontmost.processIdentifier)
        let bid = frontmost.bundleIdentifier ?? ""

        if bid.lowercased().contains("com.apple.safari") {
            return safariURL(appRef: appRef)
        } else {
            return chromiumURL(appRef: appRef)
        }
    }

    /// Reads the URL from Chromium-based browsers (Chrome, Edge, Brave, Arc).
    /// The address bar is typically an AXTextField with AXRoleDescription "address and search bar"
    /// or similar, whose AXValue contains the URL.
    private static func chromiumURL(appRef: AXUIElement) -> String? {
        var windowValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &windowValue) == .success else {
            return nil
        }

        if let url = findAXElement(root: windowValue as! AXUIElement, role: "AXTextField", descriptionContains: "address") {
            return url
        }

        return findAXElement(root: windowValue as! AXUIElement, role: "AXTextField", descriptionContains: "url")
    }

    /// Reads the URL from Safari via its AXTextField address bar.
    private static func safariURL(appRef: AXUIElement) -> String? {
        var windowValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &windowValue) == .success else {
            return nil
        }

        if let url = findAXElement(root: windowValue as! AXUIElement, role: "AXTextField", descriptionContains: "address") {
            return url
        }
        return findAXElement(root: windowValue as! AXUIElement, role: "AXComboBox", descriptionContains: nil)
    }

    /// BFS through the AX tree to find a text field matching role + description.
    /// Returns its AXValue (the URL string). Depth-limited to avoid runaway traversal.
    private static func findAXElement(root: AXUIElement, role: String, descriptionContains: String?, maxDepth: Int = 8) -> String? {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]

        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
            guard depth < maxDepth else { continue }

            var roleValue: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
            let currentRole = roleValue as? String ?? ""

            if currentRole == role {
                if let keyword = descriptionContains {
                    var descValue: AnyObject?
                    AXUIElementCopyAttributeValue(element, kAXRoleDescriptionAttribute as CFString, &descValue)
                    let desc = (descValue as? String ?? "").lowercased()
                    if desc.contains(keyword.lowercased()) {
                        var value: AnyObject?
                        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
                        if let urlString = value as? String, !urlString.isEmpty {
                            return urlString
                        }
                    }
                } else {
                    var value: AnyObject?
                    AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
                    if let urlString = value as? String, !urlString.isEmpty {
                        return urlString
                    }
                }
            }

            var children: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            if let childArray = children as? [AXUIElement] {
                for child in childArray {
                    queue.append((child, depth + 1))
                }
            }
        }
        return nil
    }

    /// Extracts a clean domain/site name from a URL string.
    /// "https://github.com/user/repo/pull/42" → "github.com"
    /// "docs.google.com/document/d/123" → "docs.google.com"
    static func domainFromURL(_ urlString: String) -> String? {
        let cleaned = urlString.hasPrefix("http") ? urlString : "https://\(urlString)"
        guard let url = URL(string: cleaned), let host = url.host else { return nil }
        return host
    }
}
