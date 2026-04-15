import AppKit
import SwiftUI

/// `NSHostingView` defaults to `isOpaque == true`; AppKit then composites a light **control** fill in light mode,
/// which reads as a sharp-corner grey rectangle behind rounded SwiftUI content. Force a truly transparent backing.
final class TranslucentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTransparentBacking()
    }

    override func layout() {
        super.layout()
        applyTransparentBacking()
    }

    private func applyTransparentBacking() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }
}

/// Same rationale as hosting view: plain `NSView` can still participate in the default opaque chrome path.
final class TranslucentContainerView: NSView {
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTransparentBacking()
    }

    override func layout() {
        super.layout()
        applyTransparentBacking()
    }

    private func applyTransparentBacking() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }
}
