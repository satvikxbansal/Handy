import Cocoa
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var chatPanelManager: ChatPanelManager?
    private let handyManager = HandyManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        handyManager.start()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            let image = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: "Handy")
            button.image = image?.withSymbolConfiguration(config)
            button.action = #selector(togglePanel)
            button.target = self
        }

        chatPanelManager = ChatPanelManager(statusItem: statusItem)
    }

    @objc private func togglePanel() {
        chatPanelManager?.toggle()
    }
}
