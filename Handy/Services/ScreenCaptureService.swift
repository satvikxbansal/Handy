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
}
