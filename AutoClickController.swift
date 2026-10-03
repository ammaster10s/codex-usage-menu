import AppKit
import ApplicationServices
import Combine

enum AutoClickPhase {
    case ready
    case waiting
    case running
}

enum MouseClickButton: String, CaseIterable {
    case left = "Left"
    case right = "Right"
}

final class AutoClickController: ObservableObject {
    @Published var selectedButton: MouseClickButton
    @Published var intervalText: String
    @Published var repeatText: String
    @Published var delayText: String
    @Published private(set) var phase: AutoClickPhase = .ready
    @Published private(set) var statusText = "Ready. ⌘⌥S stops from anywhere."
    @Published private(set) var clickedCount = 0
    @Published private(set) var permissionGranted = false

    private var startTimer: Timer?
    private var clickTimer: Timer?
    private var targetCount = 0
    private var activeButton: MouseClickButton = .left
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hotkeyMonitoringStarted = false

    init() {
        let defaults = UserDefaults.standard
        selectedButton = MouseClickButton(rawValue: defaults.string(forKey: "autoClick.button") ?? "") ?? .left
        intervalText = defaults.string(forKey: "autoClick.interval") ?? "1.0"
        repeatText = defaults.string(forKey: "autoClick.repeats") ?? "0"
        delayText = defaults.string(forKey: "autoClick.delay") ?? "3.0"
        refreshPermission()
    }

    func refreshPermission() {
        let granted = AXIsProcessTrusted()
        if granted && !permissionGranted && hotkeyMonitoringStarted {
            removeStopHotkey()
            installStopHotkey()
        }
        permissionGranted = granted
        if !granted && phase != .ready {
            finish(completed: false)
            statusText = "Accessibility access was removed. Clicking stopped."
        }
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
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
        let configuration: Configuration
        switch Self.parseConfiguration(interval: intervalText, repeats: repeatText, delay: delayText) {
        case .success(let parsed):
            configuration = parsed
        case .failure(let error):
            statusText = error.rawValue
            return false
        }
        refreshPermission()
        guard permissionGranted else {
            statusText = "Allow Accessibility access, then try Start again."
            requestPermission()
            return false
        }

        let defaults = UserDefaults.standard
        defaults.set(selectedButton.rawValue, forKey: "autoClick.button")
        defaults.set(intervalText, forKey: "autoClick.interval")
        defaults.set(repeatText, forKey: "autoClick.repeats")
        defaults.set(delayText, forKey: "autoClick.delay")
        activeButton = selectedButton
        targetCount = configuration.repeats
        clickedCount = 0
        phase = .waiting
        statusText = configuration.delay > 0
            ? "Starting in \(String(format: "%.2f", configuration.delay)) seconds…"
            : "Starting…"
        // Let the menu close before the first click, even with no requested delay.
        let timer = Timer(timeInterval: max(configuration.delay, 0.15), repeats: false) { [weak self] _ in
            self?.beginClicking(interval: configuration.interval)
        }
        startTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    func stop() {
        guard phase != .ready else { return }
        finish(completed: false)
    }

    private func beginClicking(interval: TimeInterval) {
        refreshPermission()
        guard phase == .waiting && permissionGranted else { return }
        startTimer = nil
        phase = .running
        statusText = "\(activeButton.rawValue) clicking at the pointer. ⌘⌥S stops."
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        clickTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        timer.fire()
    }

    private func tick() {
        refreshPermission()
        guard phase == .running && permissionGranted else { return }
        guard let cursor = CGEvent(source: nil),
              let events = Self.mouseEvents(button: activeButton, location: cursor.location) else {
            finish(completed: false)
            statusText = "Could not create a mouse click event."
            return
        }
        events.down.post(tap: .cghidEventTap)
        events.up.post(tap: .cghidEventTap)
        clickedCount += 1
        if targetCount > 0 && clickedCount >= targetCount {
            finish(completed: true)
        }
    }

    private func finish(completed: Bool) {
        startTimer?.invalidate()
        startTimer = nil
        clickTimer?.invalidate()
        clickTimer = nil
        phase = .ready
        statusText = completed
            ? "Completed \(clickedCount) clicks."
            : "Stopped after \(clickedCount) clicks."
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
            if Self.isStopShortcut(event), let self, self.phase != .ready {
                self.stop()
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

    private struct Configuration {
        let interval: TimeInterval
        let repeats: Int
        let delay: TimeInterval
    }

    private enum ValidationError: String, Error {
        case interval = "Interval must be at least 0.02 seconds."
        case repeats = "Click count must be 0 or a positive whole number."
        case delay = "Delay must be zero or more seconds."
    }

    private static func parseConfiguration(interval: String, repeats: String, delay: String) -> Result<Configuration, ValidationError> {
        guard let intervalValue = Double(interval.trimmingCharacters(in: .whitespacesAndNewlines)),
              intervalValue.isFinite, intervalValue >= 0.02 else { return .failure(.interval) }
        guard let repeatValue = Int(repeats.trimmingCharacters(in: .whitespacesAndNewlines)),
              repeatValue >= 0 else { return .failure(.repeats) }
        guard let delayValue = Double(delay.trimmingCharacters(in: .whitespacesAndNewlines)),
              delayValue.isFinite, delayValue >= 0 else { return .failure(.delay) }
        return .success(Configuration(interval: intervalValue, repeats: repeatValue, delay: delayValue))
    }

    private static func mouseEvents(button: MouseClickButton, location: CGPoint) -> (down: CGEvent, up: CGEvent)? {
        let mouseButton: CGMouseButton = button == .left ? .left : .right
        let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: location, mouseButton: mouseButton),
              let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: location, mouseButton: mouseButton) else { return nil }
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        return (down, up)
    }

    // Validation and event inspection only: never requests permission or posts input.
    static func selfCheck() -> [String] {
        var failures: [String] = []
        for input in ["0", "0.019", "-1", "nan", "inf", "1e309", "invalid", ""] {
            if case .success = parseConfiguration(interval: input, repeats: "0", delay: "0") {
                failures.append("Accepted invalid interval: \(input)")
            }
        }
        for input in ["-1", "1.5", "nan", "9999999999999999999999999", "invalid", ""] {
            if case .success = parseConfiguration(interval: "1", repeats: input, delay: "0") {
                failures.append("Accepted invalid repeat count: \(input)")
            }
        }
        for input in ["-1", "nan", "inf", "1e309", "invalid", ""] {
            if case .success = parseConfiguration(interval: "1", repeats: "0", delay: input) {
                failures.append("Accepted invalid delay: \(input)")
            }
        }
        for (interval, repeats, delay) in [("1.0", "0", "3.0"), ("0.02", "1", "0"), (" 0.5 ", " 5 ", " 0 ")] {
            switch parseConfiguration(interval: interval, repeats: repeats, delay: delay) {
            case .failure:
                failures.append("Rejected valid click settings: \(interval), \(repeats), \(delay)")
            case .success(let parsed):
                if parsed.interval != Double(interval.trimmingCharacters(in: .whitespaces))
                    || parsed.repeats != Int(repeats.trimmingCharacters(in: .whitespaces))
                    || parsed.delay != Double(delay.trimmingCharacters(in: .whitespaces)) {
                    failures.append("Parsed click settings incorrectly.")
                }
            }
        }
        let location = CGPoint(x: 144, y: 233)
        for button in MouseClickButton.allCases {
            guard let events = mouseEvents(button: button, location: location) else {
                failures.append("Could not construct \(button.rawValue.lowercased()) click events.")
                continue
            }
            let expectedButton: CGMouseButton = button == .left ? .left : .right
            let expectedTypes: [CGEventType] = button == .left ? [.leftMouseDown, .leftMouseUp] : [.rightMouseDown, .rightMouseUp]
            for (event, expectedType) in zip([events.down, events.up], expectedTypes) {
                if event.type != expectedType || event.location != location
                    || event.getIntegerValueField(.mouseEventButtonNumber) != Int64(expectedButton.rawValue)
                    || event.getIntegerValueField(.mouseEventClickState) != 1 || !event.flags.isEmpty {
                    failures.append("Incorrect \(button.rawValue.lowercased()) click event.")
                }
            }
        }
        return failures
    }
}
