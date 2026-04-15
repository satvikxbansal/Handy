import AppKit

/// Sits above the SwiftUI `NSHostingView` and handles drag vs tap.
/// `mouseDownCanMoveWindow` + overridden `mouseDown` without `super` breaks system drag; we use `performDrag(with:)` instead.
final class FloatingAccessoryInteractionNSView: NSView {
    private var dragStart: NSPoint = .zero
    private var dragSessionActive = false
    private var pointerInside = false
    private var mouseDownActive = false

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .activeAlways,
            .inVisibleRect,
        ]
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        syncHighlight()
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        syncHighlight()
    }

    private func syncHighlight() {
        let on = pointerInside || mouseDownActive
        HandyManager.shared.setFloatingAccessoryInteractionHighlighted(on)
    }

    override func mouseDown(with event: NSEvent) {
        HandyManager.shared.captureAccessoryChatOpenToolSnapshot()
        dragStart = event.locationInWindow
        dragSessionActive = false
        mouseDownActive = true
        syncHighlight()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = event.locationInWindow
        let dist = hypot(p.x - dragStart.x, p.y - dragStart.y)
        if !dragSessionActive {
            guard dist > 6 else { return }
            dragSessionActive = true
            HandyManager.shared.setCompanionSuppressedForFloatingAccessoryDrag(true)
        }
        window?.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let didDrag = dragSessionActive
        HandyManager.shared.setCompanionSuppressedForFloatingAccessoryDrag(false)
        if !didDrag {
            HandyManager.shared.chatPanelManager?.show()
        }
        dragSessionActive = false
        mouseDownActive = false
        syncHighlight()
    }
}
