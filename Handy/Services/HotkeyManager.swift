import Cocoa
import Carbon.HIToolbox

enum HotkeyAction {
    case openChat        // Shift + Space + O
    case voiceInput      // Control + Z
}

protocol HotkeyManagerDelegate: AnyObject {
    func hotkeyTriggered(_ action: HotkeyAction)
}

/// Global hotkey listener using CGEvent tap.
/// Triggers: Shift+Space+O = open chat, Control+Z = voice input (help cursor).
final class HotkeyManager {
    weak var delegate: HotkeyManagerDelegate?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Shift+Space+O state tracking
    private var shiftHeld = false
    private var spacePressed = false
    private var waitingForO = false
    private var oKeyTimer: DispatchWorkItem?
    private let oKeyTimeout: TimeInterval = 0.5

    deinit {
        stop()
    }

    func start() {
        guard eventTap == nil else {
            print("🔑 HotkeyManager: event tap already running")
            return
        }

        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.handleEvent(type: type, event: event)
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("❌ HotkeyManager: CGEvent.tapCreate FAILED — Accessibility permission not granted?")
            print("   Go to System Settings > Privacy & Security > Accessibility and add this app")
            print("   If already granted, toggle OFF then ON (code signature changes on rebuild)")
            return
        }
        print("✅ HotkeyManager: event tap created successfully")

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        oKeyTimer?.cancel()
        oKeyTimer = nil
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.runLoopSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            self.eventTap = nil
        }
    }

    private func handleEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        let flags = event.flags

        switch type {
        case .flagsChanged:
            shiftHeld = flags.contains(.maskShift)
            if !shiftHeld {
                resetShiftSpaceState()
            }

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            // Control+Z → voice input (help cursor)
            // Z = keycode 6, check Control is held and Shift is NOT held
            if keyCode == 6
                && flags.contains(.maskControl)
                && !flags.contains(.maskShift)
                && !flags.contains(.maskCommand)
                && !flags.contains(.maskAlternate)
            {
                print("🔑 HotkeyManager: Control+Z detected → voiceInput")
                delegate?.hotkeyTriggered(.voiceInput)
                return
            }

            // Shift+Space → start waiting for O
            // Space = keycode 49
            if keyCode == 49 && shiftHeld && !spacePressed {
                spacePressed = true
                waitingForO = true

                oKeyTimer?.cancel()
                let timer = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.resetShiftSpaceState()
                }
                oKeyTimer = timer
                DispatchQueue.main.asyncAfter(deadline: .now() + oKeyTimeout, execute: timer)
            }

            // O = keycode 31 — complete Shift+Space+O
            if keyCode == 31 && waitingForO && spacePressed && shiftHeld {
                oKeyTimer?.cancel()
                oKeyTimer = nil
                print("🔑 HotkeyManager: Shift+Space+O detected → openChat")
                delegate?.hotkeyTriggered(.openChat)
                resetShiftSpaceState()
            }

        case .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 49 {
                spacePressed = false
            }

        default:
            break
        }
    }

    private func resetShiftSpaceState() {
        spacePressed = false
        waitingForO = false
        oKeyTimer?.cancel()
        oKeyTimer = nil
    }
}
