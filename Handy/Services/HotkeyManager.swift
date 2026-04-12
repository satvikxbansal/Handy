import Cocoa
import Carbon.HIToolbox

enum HotkeyAction {
    case openChat        // Shift + Space + O
    case voiceInput      // Shift + Space
}

protocol HotkeyManagerDelegate: AnyObject {
    func hotkeyTriggered(_ action: HotkeyAction)
}

/// Global hotkey listener using CGEvent tap.
/// Default triggers: Shift+Space = voice input, Shift+Space+O = open chat.
/// Architecture supports future custom hotkey configuration.
final class HotkeyManager {
    weak var delegate: HotkeyManagerDelegate?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var shiftHeld = false
    private var spacePressed = false
    private var waitingForO = false
    private var spaceTimestamp: Date?

    private let oKeyTimeout: TimeInterval = 0.4

    deinit {
        stop()
    }

    func start() {
        guard eventTap == nil else { return }

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
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
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

        switch type {
        case .flagsChanged:
            let flags = event.flags
            shiftHeld = flags.contains(.maskShift)
            if !shiftHeld {
                resetState()
            }

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            // Space = 49
            if keyCode == 49 && shiftHeld && !spacePressed {
                spacePressed = true
                spaceTimestamp = Date()
                waitingForO = true

                DispatchQueue.main.asyncAfter(deadline: .now() + oKeyTimeout) { [weak self] in
                    guard let self, self.waitingForO, self.spacePressed else { return }
                    self.waitingForO = false
                    self.delegate?.hotkeyTriggered(.voiceInput)
                    self.resetState()
                }
            }

            // O = 31
            if keyCode == 31 && waitingForO && spacePressed && shiftHeld {
                waitingForO = false
                spacePressed = false
                delegate?.hotkeyTriggered(.openChat)
                resetState()
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

    private func resetState() {
        spacePressed = false
        waitingForO = false
        spaceTimestamp = nil
    }
}
