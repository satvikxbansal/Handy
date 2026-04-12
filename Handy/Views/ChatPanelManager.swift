import AppKit
import SwiftUI

/// Manages the floating, draggable chat panel window.
@MainActor
final class ChatPanelManager: NSObject {
    private var panel: KeyablePanel?
    private var statusItem: NSStatusItem?
    private var isVisible = false
    private var clickOutsideMonitor: Any?

    init(statusItem: NSStatusItem?) {
        self.statusItem = statusItem
        super.init()
        HandyManager.shared.chatPanelManager = self
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        guard !isVisible else { return }

        if panel == nil {
            createPanel()
        }

        guard let panel else { return }
        positionPanel(panel)
        HandyManager.shared.onChatPanelOpened()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isVisible = true

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return }
            let clickLocation = NSEvent.mouseLocation
            if !panel.frame.contains(clickLocation) {
                self.hide()
            }
        }
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    private func createPanel() {
        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
        let panelWidth: CGFloat = min(420, screenSize.width * 0.28)
        let panelHeight: CGFloat = min(600, screenSize.height * 0.65)

        let chatView = ChatInterfaceView()
            .environmentObject(HandyManager.shared)
            .environmentObject(AppSettings.shared)
            .preferredColorScheme(.dark)

        let hostingView = NSHostingView(rootView: chatView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = NSColor(DS.Colors.background)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.contentView = hostingView
        p.hasShadow = true
        p.minSize = NSSize(width: 360, height: 400)
        p.maxSize = NSSize(width: 600, height: 900)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.appearance = NSAppearance(named: .darkAqua)

        panel = p
    }

    private func positionPanel(_ panel: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size

        let x = screenFrame.maxX - panelSize.width - 16
        let y = screenFrame.maxY - panelSize.height - 8
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }
}

/// NSPanel subclass that accepts key input (for text fields).
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
