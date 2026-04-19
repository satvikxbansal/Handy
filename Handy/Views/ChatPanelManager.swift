import AppKit
import SwiftUI

/// Manages the floating, draggable chat panel window.
@MainActor
final class ChatPanelManager: NSObject, NSWindowDelegate {
    private(set) var panel: KeyablePanel?
    private var statusItem: NSStatusItem?
    private var isVisible = false

    init(statusItem: NSStatusItem?) {
        self.statusItem = statusItem
        super.init()
        HandyManager.shared.chatPanelManager = self
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        if isVisible {
            FloatingAccessWidgetController.shared.setChatPanelVisible(true)
            return
        }

        if panel == nil {
            createPanel()
        }

        guard let panel else { return }
        positionPanel(panel)
        HandyManager.shared.noteChatPanelPresentedForMainConversation()
        HandyManager.shared.onChatPanelOpened()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isVisible = true
        FloatingAccessWidgetController.shared.setChatPanelVisible(true)
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
        FloatingAccessWidgetController.shared.setChatPanelVisible(false)
    }

    private func createPanel() {
        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
        let panelWidth: CGFloat = min(420, screenSize.width * 0.28)
        let panelHeight: CGFloat = min(600, screenSize.height * 0.65)

        let colorScheme: ColorScheme = AppSettings.shared.isLightMode ? .light : .dark
        let chatView = ChatInterfaceView()
            .environmentObject(HandyManager.shared)
            .environmentObject(AppSettings.shared)
            .preferredColorScheme(colorScheme)

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
        p.appearance = NSAppearance(named: AppSettings.shared.isLightMode ? .aqua : .darkAqua)
        p.delegate = self

        panel = p
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
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
