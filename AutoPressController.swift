import AppKit
import ApplicationServices
import Carbon
import Combine

struct KeyOption {
    let name: String
    let keyCode: CGKeyCode
}

let keyOptions: [KeyOption] = [
    KeyOption(name: "Enter", keyCode: CGKeyCode(kVK_Return)),
    KeyOption(name: "Space", keyCode: CGKeyCode(kVK_Space)),
    KeyOption(name: "Tab", keyCode: CGKeyCode(kVK_Tab)),
    KeyOption(name: "Escape", keyCode: CGKeyCode(kVK_Escape)),
    KeyOption(name: "Backspace", keyCode: CGKeyCode(kVK_Delete)),
    KeyOption(name: "Left Arrow", keyCode: CGKeyCode(kVK_LeftArrow)),
    KeyOption(name: "Right Arrow", keyCode: CGKeyCode(kVK_RightArrow)),
    KeyOption(name: "Up Arrow", keyCode: CGKeyCode(kVK_UpArrow)),
    KeyOption(name: "Down Arrow", keyCode: CGKeyCode(kVK_DownArrow)),
    KeyOption(name: "A", keyCode: CGKeyCode(kVK_ANSI_A)),
    KeyOption(name: "B", keyCode: CGKeyCode(kVK_ANSI_B)),
    KeyOption(name: "C", keyCode: CGKeyCode(kVK_ANSI_C)),
    KeyOption(name: "D", keyCode: CGKeyCode(kVK_ANSI_D)),
    KeyOption(name: "E", keyCode: CGKeyCode(kVK_ANSI_E)),
    KeyOption(name: "F", keyCode: CGKeyCode(kVK_ANSI_F)),
    KeyOption(name: "G", keyCode: CGKeyCode(kVK_ANSI_G)),
    KeyOption(name: "H", keyCode: CGKeyCode(kVK_ANSI_H)),
    KeyOption(name: "I", keyCode: CGKeyCode(kVK_ANSI_I)),
    KeyOption(name: "J", keyCode: CGKeyCode(kVK_ANSI_J)),
    KeyOption(name: "K", keyCode: CGKeyCode(kVK_ANSI_K)),
    KeyOption(name: "L", keyCode: CGKeyCode(kVK_ANSI_L)),
    KeyOption(name: "M", keyCode: CGKeyCode(kVK_ANSI_M)),
    KeyOption(name: "N", keyCode: CGKeyCode(kVK_ANSI_N)),
    KeyOption(name: "O", keyCode: CGKeyCode(kVK_ANSI_O)),
    KeyOption(name: "P", keyCode: CGKeyCode(kVK_ANSI_P)),
    KeyOption(name: "Q", keyCode: CGKeyCode(kVK_ANSI_Q)),
    KeyOption(name: "R", keyCode: CGKeyCode(kVK_ANSI_R)),
    KeyOption(name: "S", keyCode: CGKeyCode(kVK_ANSI_S)),
    KeyOption(name: "T", keyCode: CGKeyCode(kVK_ANSI_T)),
    KeyOption(name: "U", keyCode: CGKeyCode(kVK_ANSI_U)),
    KeyOption(name: "V", keyCode: CGKeyCode(kVK_ANSI_V)),
    KeyOption(name: "W", keyCode: CGKeyCode(kVK_ANSI_W)),
    KeyOption(name: "X", keyCode: CGKeyCode(kVK_ANSI_X)),
    KeyOption(name: "Y", keyCode: CGKeyCode(kVK_ANSI_Y)),
    KeyOption(name: "Z", keyCode: CGKeyCode(kVK_ANSI_Z)),
    KeyOption(name: "0", keyCode: CGKeyCode(kVK_ANSI_0)),
    KeyOption(name: "1", keyCode: CGKeyCode(kVK_ANSI_1)),
    KeyOption(name: "2", keyCode: CGKeyCode(kVK_ANSI_2)),
    KeyOption(name: "3", keyCode: CGKeyCode(kVK_ANSI_3)),
    KeyOption(name: "4", keyCode: CGKeyCode(kVK_ANSI_4)),
    KeyOption(name: "5", keyCode: CGKeyCode(kVK_ANSI_5)),
    KeyOption(name: "6", keyCode: CGKeyCode(kVK_ANSI_6)),
    KeyOption(name: "7", keyCode: CGKeyCode(kVK_ANSI_7)),
    KeyOption(name: "8", keyCode: CGKeyCode(kVK_ANSI_8)),
    KeyOption(name: "9", keyCode: CGKeyCode(kVK_ANSI_9))
]

enum AutoPressPhase {
    case ready
    case waiting
    case running
}

final class AutoPressController: ObservableObject {
    @Published var selectedKeyName: String
    @Published var intervalText: String
    @Published var repeatText: String
    @Published var delayText: String
    @Published private(set) var phase: AutoPressPhase = .ready
    @Published private(set) var statusText = "Ready. ⌘⌥S stops from anywhere."
    @Published private(set) var pressedCount = 0
    @Published private(set) var permissionGranted = false

    private var timer: Timer?
    private var pendingStart: DispatchWorkItem?
    private var targetCount = 0
    private var selectedKeyCode = CGKeyCode(kVK_Return)
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hotkeyMonitoringStarted = false

    init() {
        let defaults = UserDefaults.standard
        let savedKey = defaults.string(forKey: "autoPress.key") ?? "Enter"
        selectedKeyName = keyOptions.contains { $0.name == savedKey } ? savedKey : "Enter"
        intervalText = defaults.string(forKey: "autoPress.interval") ?? "1.0"
        repeatText = defaults.string(forKey: "autoPress.repeats") ?? "0"
        delayText = defaults.string(forKey: "autoPress.delay") ?? "3.0"
        refreshPermission()
    }

    func refreshPermission() {
        let granted = AXIsProcessTrusted()
        if granted && !permissionGranted && hotkeyMonitoringStarted {
            removeStopHotkey()
            installStopHotkey()
        }
        permissionGranted = granted
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshPermission()
    }

    func openAccessibilitySettings() {
        requestPermission()
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    func start() -> Bool {
        guard phase == .ready else { return false }
        guard let interval = Double(intervalText), interval.isFinite, interval >= 0.02 else {
            statusText = "Interval must be at least 0.02 seconds."
            return false
        }
        guard let repeats = Int(repeatText), repeats >= 0 else {
            statusText = "Repeats must be 0 or a positive whole number."
            return false
        }
        guard let delay = Double(delayText), delay.isFinite, delay >= 0 else {
            statusText = "Delay must be zero or more seconds."
            return false
        }
        guard let key = keyOptions.first(where: { $0.name == selectedKeyName }) else {
            statusText = "Choose a key."
            return false
        }
        let defaults = UserDefaults.standard
        defaults.set(selectedKeyName, forKey: "autoPress.key")
        defaults.set(intervalText, forKey: "autoPress.interval")
        defaults.set(repeatText, forKey: "autoPress.repeats")
        defaults.set(delayText, forKey: "autoPress.delay")
        refreshPermission()
        guard permissionGranted else {
            statusText = "Allow Accessibility access, then try Start again."
            requestPermission()
            return false
        }

        selectedKeyCode = key.keyCode
        targetCount = repeats
        pressedCount = 0
        phase = .waiting
        statusText = delay > 0 ? "Starting in \(String(format: "%.2f", delay)) seconds…" : "Starting…"
        let work = DispatchWorkItem { [weak self] in self?.beginPressing(interval: interval) }
        pendingStart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.15), execute: work)
        return true
    }

    func stop() {
        guard phase != .ready else { return }
        finish(completed: false)
    }

    private func beginPressing(interval: Double) {
        guard phase == .waiting else { return }
        pendingStart = nil
        phase = .running
        statusText = "Pressing \(selectedKeyName). ⌘⌥S stops."
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        timer.fire()
    }

    private func tick() {
        guard phase == .running else { return }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: selectedKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: selectedKeyCode, keyDown: false) else {
            finish(completed: false)
            statusText = "Could not create a keyboard event."
            return
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        pressedCount += 1
        if targetCount > 0 && pressedCount >= targetCount {
            finish(completed: true)
        }
    }

    private func finish(completed: Bool) {
        pendingStart?.cancel()
        pendingStart = nil
        timer?.invalidate()
        timer = nil
        phase = .ready
        statusText = completed
            ? "Completed \(pressedCount) key presses."
            : "Stopped after \(pressedCount) key presses."
    }

    func installStopHotkey() {
        guard !hotkeyMonitoringStarted else { return }
        hotkeyMonitoringStarted = true
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.isStopShortcut(event) {
                DispatchQueue.main.async { self?.stop() }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.isStopShortcut(event) {
                self?.stop()
                return nil
            }
            return event
        }
    }

    func removeStopHotkey() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        hotkeyMonitoringStarted = false
    }

    private static func isStopShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.command)
            && flags.contains(.option)
            && event.charactersIgnoringModifiers?.lowercased() == "s"
    }
}
