import AppKit
import Combine
import SwiftUI

/// Owns the small floating pill window. Visible only when the user enables it in Settings **and** the chat panel is hidden.
@MainActor
final class FloatingAccessWidgetController: NSObject {
    static let shared = FloatingAccessWidgetController()

    private var window: NSPanel?
    private var moveObserver: NSObjectProtocol?
    private var settingsCancellable: AnyCancellable?

    /// True while the chat panel is on-screen (including when key window is chat).
    private var chatPanelIsVisible = false

    private let originUserDefaultsKey = "handy_floatingWidgetOrigin"

    private override init() {
        super.init()
    }

    func configure() {
        guard settingsCancellable == nil else {
            applyVisibility()
            return
        }
        settingsCancellable = AppSettings.shared.$showFloatingAccessWidget
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyVisibility()
            }

        applyVisibility()
    }

    /// Called from `ChatPanelManager` whenever the chat panel is shown or hidden.
    func setChatPanelVisible(_ visible: Bool) {
        chatPanelIsVisible = visible
        applyVisibility()
    }

    private func applyVisibility() {
        let shouldShow = AppSettings.shared.showFloatingAccessWidget && !chatPanelIsVisible
        if shouldShow {
            ensureWindow()
            syncWidgetWindowFrame()
            window?.setFrameOrigin(clampedOrigin())
            window?.orderFrontRegardless()
        } else {
            window?.orderOut(nil)
            HandyManager.shared.setFloatingAccessoryInteractionHighlighted(false)
            HandyManager.shared.setCompanionSuppressedForFloatingAccessoryDrag(false)
        }
    }

    private func syncWidgetWindowFrame() {
        guard let panel = window else { return }
        let s = NSSize(width: FloatingAccessWidgetMetrics.width, height: FloatingAccessWidgetMetrics.height)
        guard panel.frame.size != s else { return }
        var f = panel.frame
        f.size = s
        panel.setFrame(f, display: true)
        panel.contentView?.frame = CGRect(origin: .zero, size: s)
    }

    private func ensureWindow() {
        guard window == nil else { return }

        let size = NSSize(
            width: FloatingAccessWidgetMetrics.width,
            height: FloatingAccessWidgetMetrics.height
        )
        let initialFrame = CGRect(origin: clampedOrigin(), size: size)

        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = true

        let rootView = FloatingAccessWidgetView()
            .environmentObject(HandyManager.shared)

        let hosting = TranslucentHostingView(rootView: rootView)
        let container = TranslucentContainerView(frame: NSRect(origin: .zero, size: initialFrame.size))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]

        let dragSurface = FloatingAccessoryInteractionNSView()
        dragSurface.frame = container.bounds
        dragSurface.autoresizingMask = [.width, .height]

        container.addSubview(hosting)
        container.addSubview(dragSurface)
        panel.contentView = container

        window = panel

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] note in
            guard let self, let win = note.object as? NSWindow else { return }
            Task { @MainActor in
                self.saveOrigin(win.frame.origin)
            }
        }
    }

    private func defaultOrigin() -> CGPoint {
        guard let screen = NSScreen.main else {
            return CGPoint(x: 100, y: 100)
        }
        let vf = screen.visibleFrame
        let w = FloatingAccessWidgetMetrics.width
        let x = vf.maxX - w - 16
        let y = vf.minY + 24
        return CGPoint(x: x, y: y)
    }

    private func clampedOrigin() -> CGPoint {
        if let saved = loadSavedOrigin(), isOriginOnAnyScreen(saved) {
            return saved
        }
        return defaultOrigin()
    }

    private func loadSavedOrigin() -> CGPoint? {
        guard let d = UserDefaults.standard.dictionary(forKey: originUserDefaultsKey),
              let x = (d["x"] as? NSNumber)?.doubleValue,
              let y = (d["y"] as? NSNumber)?.doubleValue else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func saveOrigin(_ origin: CGPoint) {
        UserDefaults.standard.set(
            ["x": Double(origin.x), "y": Double(origin.y)],
            forKey: originUserDefaultsKey
        )
    }

    private func isOriginOnAnyScreen(_ origin: CGPoint) -> Bool {
        let w = FloatingAccessWidgetMetrics.width
        let h = FloatingAccessWidgetMetrics.height
        let rect = CGRect(origin: origin, size: CGSize(width: w, height: h)).insetBy(dx: -8, dy: -8)
        return NSScreen.screens.contains { $0.frame.intersects(rect) }
    }
}
