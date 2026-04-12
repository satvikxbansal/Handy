import SwiftUI

@main
struct HandyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            VStack(spacing: 8) {
                Button("Open Handy") {
                    appDelegate.openChat()
                }
                .keyboardShortcut("o")

                Divider()

                Button("Quit Handy") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(4)
        } label: {
            Image(systemName: "hand.raised.fill")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var chatPanelManager: ChatPanelManager?
    private let handyManager = HandyManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        chatPanelManager = ChatPanelManager(statusItem: nil)
        handyManager.chatPanelManager = chatPanelManager
        handyManager.start()

        let logMsg = """
        Handy launched successfully
          Accessibility: \(AXIsProcessTrusted() ? "GRANTED" : "NOT GRANTED")
        """
        print(logMsg)
        writeLog(logMsg)
    }

    func openChat() {
        chatPanelManager?.show()
    }

    private func writeLog(_ msg: String) {
        let entry = "\(Date()): \(msg)\n"
        let path = "/tmp/handy_launch.log"
        if let data = entry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path) {
                if let handle = FileHandle(forWritingAtPath: path) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
    }
}
