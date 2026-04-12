import AppKit
import SwiftUI

/// Manages per-screen transparent overlay windows for the pointing cursor.
final class OverlayManager {
    private var overlayWindows: [NSWindow] = []
    private var overlayViews: [OverlayContentView] = []
    private var hideTimer: Timer?

    func pointAt(_ screenPoint: CGPoint, label: String, duration: TimeInterval = 4.0) {
        DispatchQueue.main.async { [weak self] in
            self?.showOverlay(at: screenPoint, label: label, duration: duration)
        }
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in
            self?.hideTimer?.invalidate()
            self?.overlayWindows.forEach { $0.orderOut(nil) }
        }
    }

    private func showOverlay(at point: CGPoint, label: String, duration: TimeInterval) {
        hideTimer?.invalidate()
        rebuildWindowsIfNeeded()

        let targetScreen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main!

        for (window, view) in zip(overlayWindows, overlayViews) {
            window.setFrame(window.screen?.frame ?? targetScreen.frame, display: true)
            if window.screen == targetScreen || window.frame.contains(point) {
                window.orderFrontRegardless()
                let localPoint = CGPoint(
                    x: point.x - window.frame.origin.x,
                    y: point.y - window.frame.origin.y
                )
                view.animateTo(point: localPoint, label: label)
            } else {
                window.orderOut(nil)
            }
        }

        hideTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    private func rebuildWindowsIfNeeded() {
        let screens = NSScreen.screens
        guard overlayWindows.count != screens.count else { return }

        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        overlayViews.removeAll()

        for screen in screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = .statusBar + 1
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.hasShadow = false

            let contentView = OverlayContentView(frame: screen.frame)
            window.contentView = contentView

            overlayWindows.append(window)
            overlayViews.append(contentView)
        }
    }
}

/// Custom NSView that draws the pointing cursor indicator.
final class OverlayContentView: NSView {
    private var targetPoint: CGPoint = .zero
    private var currentPoint: CGPoint = .zero
    private var labelText = ""
    private var animationProgress: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func animateTo(point: CGPoint, label: String) {
        targetPoint = point
        labelText = label
        animationProgress = 0

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.animationProgress += 0.05
            if self.animationProgress >= 1.0 {
                self.animationProgress = 1.0
                timer.invalidate()
            }

            let eased = self.easeOutCubic(self.animationProgress)
            let startPoint = self.currentPoint == .zero ? CGPoint(x: self.bounds.midX, y: self.bounds.midY) : self.currentPoint
            self.currentPoint = CGPoint(
                x: startPoint.x + (self.targetPoint.x - startPoint.x) * eased,
                y: startPoint.y + (self.targetPoint.y - startPoint.y) * eased
            )
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard animationProgress > 0 else { return }

        let ctx = NSGraphicsContext.current!.cgContext

        let blue = NSColor(red: 0.231, green: 0.510, blue: 0.965, alpha: 1.0)

        // Pulsing ring
        let pulseRadius: CGFloat = 16 + sin(animationProgress * .pi * 2) * 4
        ctx.setStrokeColor(blue.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(2)
        ctx.addEllipse(in: CGRect(
            x: currentPoint.x - pulseRadius,
            y: currentPoint.y - pulseRadius,
            width: pulseRadius * 2,
            height: pulseRadius * 2
        ))
        ctx.strokePath()

        // Inner filled circle
        ctx.setFillColor(blue.withAlphaComponent(0.8).cgColor)
        let innerRadius: CGFloat = 6
        ctx.addEllipse(in: CGRect(
            x: currentPoint.x - innerRadius,
            y: currentPoint.y - innerRadius,
            width: innerRadius * 2,
            height: innerRadius * 2
        ))
        ctx.fillPath()

        // Triangle pointer
        let triSize: CGFloat = 10
        ctx.setFillColor(blue.cgColor)
        ctx.move(to: CGPoint(x: currentPoint.x, y: currentPoint.y - triSize))
        ctx.addLine(to: CGPoint(x: currentPoint.x - triSize * 0.6, y: currentPoint.y + triSize * 0.4))
        ctx.addLine(to: CGPoint(x: currentPoint.x + triSize * 0.6, y: currentPoint.y + triSize * 0.4))
        ctx.closePath()
        ctx.fillPath()

        // Label
        if !labelText.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.7)
            ]
            let str = NSAttributedString(string: " \(labelText) ", attributes: attrs)
            let labelSize = str.size()
            let labelOrigin = CGPoint(
                x: currentPoint.x - labelSize.width / 2,
                y: currentPoint.y + 20
            )
            str.draw(at: labelOrigin)
        }
    }

    private func easeOutCubic(_ t: CGFloat) -> CGFloat {
        let f = t - 1
        return f * f * f + 1
    }
}
