import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

private struct LimitWindow {
    let name: String
    let remainingPercent: Int
    let resetsAt: Date?
}

private struct UsageSnapshot {
    let windows: [LimitWindow]
    let checkedAt: Date

    var remainingPercent: Int {
        windows.map(\.remainingPercent).min() ?? 0
    }
}

private enum UsageError: LocalizedError {
    case codexNotFound
    case noResponse
    case server(String)
    case noLimits

    var errorDescription: String? {
        switch self {
        case .codexNotFound: return "Codex CLI was not found."
        case .noResponse: return "Codex did not respond within 15 seconds."
        case .server(let message): return message
        case .noLimits: return "No Codex allowance was returned."
        }
    }
}

private enum UsageFetcher {
    static func fetch() throws -> UsageSnapshot {
        let process = Process()
        process.executableURL = try codexExecutable()
        process.arguments = ["app-server"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeout)
        defer {
            timeout.cancel()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }

        var buffer = Data()
        func response(for id: Int) throws -> [String: Any] {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: 0..<newline)
                    buffer.removeSubrange(0...newline)
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          (message["id"] as? Int) == id else { continue }
                    if let error = message["error"] as? [String: Any] {
                        throw UsageError.server(error["message"] as? String ?? "Codex returned an error.")
                    }
                    return message["result"] as? [String: Any] ?? [:]
                }
                var chunk = [UInt8](repeating: 0, count: 4096)
                let count = chunk.withUnsafeMutableBytes {
                    Darwin.read(output.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count)
                }
                if count < 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard count > 0 else { throw UsageError.noResponse }
                buffer.append(contentsOf: chunk.prefix(count))
            }
        }

        try send([
            "method": "initialize", "id": 1,
            "params": ["clientInfo": [
                "name": "codex_usage_menu",
                "title": "Codex Usage Menu",
                "version": "1.0.0"
            ]]
        ])
        _ = try response(for: 1)
        try send(["method": "initialized"])
        try send(["method": "account/rateLimits/read", "id": 2])
        let result = try response(for: 2)

        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        let codex = (buckets?["codex"] as? [String: Any])
            ?? (result["rateLimits"] as? [String: Any])
        guard let codex else { throw UsageError.noLimits }

        var windows: [LimitWindow] = []
        for key in ["primary", "secondary"] {
            guard let raw = codex[key] as? [String: Any],
                  let used = (raw["usedPercent"] as? NSNumber)?.doubleValue else { continue }
            let duration = (raw["windowDurationMins"] as? NSNumber)?.intValue ?? 0
            let name: String
            switch duration {
            case 300: name = "5-hour window"
            case 10080: name = "Weekly window"
            default:
                if duration > 0 && duration % 1440 == 0 {
                    name = "\(duration / 1440)-day window"
                } else if duration > 0 && duration % 60 == 0 {
                    name = "\(duration / 60)-hour window"
                } else {
                    name = key.capitalized + " window"
                }
            }
            let reset = (raw["resetsAt"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue)
            }
            windows.append(LimitWindow(
                name: name,
                remainingPercent: Int((100 - used).clamped(to: 0...100).rounded()),
                resetsAt: reset
            ))
        }
        guard !windows.isEmpty else { throw UsageError.noLimits }
        return UsageSnapshot(windows: windows, checkedAt: Date())
    }

    private static func codexExecutable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/codex" }
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw UsageError.codexNotFound
        }
        return URL(fileURLWithPath: path)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private enum Palette {
    static let background = Color(red: 0.12, green: 0.23, blue: 0.36)
    static let card = Color(red: 0.17, green: 0.30, blue: 0.44)
    static let track = Color(red: 0.25, green: 0.39, blue: 0.53)
    static let accent = Color(red: 0.34, green: 0.29, blue: 0.84)
    static let secondary = Color(red: 0.70, green: 0.81, blue: 0.92)
    static let highlight = Color(red: 0.46, green: 0.70, blue: 0.98)
}

private enum BrandIcon {
    static func status(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 19, height: 19), flipped: false) { _ in
            NSColor.white.setStroke()
            let keycap = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 16, height: 16), xRadius: 4, yRadius: 4)
            keycap.lineWidth = 1.8
            keycap.stroke()

            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 9.5, y: 8), radius: 4.4,
                          startAngle: 200, endAngle: -20, clockwise: true)
            arc.lineWidth = 1.8
            arc.lineCapStyle = .round
            arc.stroke()

            let needle = NSBezierPath()
            needle.move(to: NSPoint(x: 9.5, y: 8))
            needle.line(to: NSPoint(x: 12.1, y: 11.5))
            needle.lineWidth = 1.5
            needle.lineCapStyle = .round
            needle.stroke()

            if active {
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: 14, y: 2, width: 3, height: 3)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

private final class UsageModel: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var error: String?
    @Published var refreshing = false
}

private struct WindowRow: View {
    let window: LimitWindow
    let now: Date

    private var shortName: String {
        switch window.name {
        case "5-hour window": return "5h"
        case "Weekly window": return "Week"
        default: return window.name.replacingOccurrences(of: " window", with: "")
        }
    }

    private var resetText: String {
        guard let reset = window.resetsAt else { return "Reset unknown" }
        let minutes = max(0, Int(ceil(reset.timeIntervalSince(now) / 60)))
        if minutes == 0 { return "Resetting" }
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let remainder = minutes % 60
        if days > 0 { return "\(days)d \(hours)h \(remainder)m" }
        if hours > 0 { return "\(hours)h \(remainder)m" }
        return "\(remainder)m"
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "clock")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
                    .frame(width: 18)
                Text(shortName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(100 - window.remainingPercent)% used")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text(resetText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 74, alignment: .trailing)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track)
                    Capsule().fill(Palette.accent)
                        .frame(width: max(4, geometry.size.width * CGFloat(100 - window.remainingPercent) / 100))
                }
            }
            .frame(height: 7)
            .accessibilityLabel("\(window.name), \(window.remainingPercent) percent remaining, resets in \(resetText)")
        }
    }
}

private struct UsagePopover: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var autoPress: AutoPressController
    let refresh: () -> Void
    let startPressing: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack(spacing: 11) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                Text("Codex")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                if let snapshot = model.snapshot {
                    Text(model.error == nil
                         ? "\(snapshot.remainingPercent)% to spare"
                         : "Last known: \(snapshot.remainingPercent)%")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.highlight)
                        .monospacedDigit()
                }
            }

            if let error = model.error {
                Text("Refresh failed: \(error)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 1, green: 0.75, blue: 0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let snapshot = model.snapshot {
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    VStack(spacing: 20) {
                        ForEach(snapshot.windows, id: \.name) { window in
                            WindowRow(window: window, now: timeline.date)
                        }
                    }
                }
                .padding(18)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
            } else if model.error == nil {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking your allowance…")
                }
                .font(.system(size: 14))
                .foregroundStyle(Palette.secondary)
                .frame(maxWidth: .infinity, minHeight: 88)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
            }

            AutoPressCard(autoPress: autoPress, startPressing: startPressing)

            HStack {
                if let snapshot = model.snapshot {
                    Text("Updated \(snapshot.checkedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                } else {
                    Text("Codex allowance")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                }
                Spacer()
                if model.refreshing {
                    ProgressView().controlSize(.small)
                        .frame(width: 28, height: 28)
                } else {
                    Button(action: refresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.secondary)
                    .help("Refresh now")
                    .accessibilityLabel("Refresh now")
                }
                Button(action: quit) {
                    Image(systemName: "power")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.secondary)
                .help("Quit Codex Usage")
                .accessibilityLabel("Quit Codex Usage")
            }
        }
        .padding(20)
        .frame(width: 390)
        .background(Palette.background)
    }
}

private struct AutoPressCard: View {
    @ObservedObject var autoPress: AutoPressController
    let startPressing: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "keyboard.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.highlight)
                Text("Auto Press")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                if autoPress.phase != .ready {
                    Text(autoPress.phase == .waiting ? "STARTING" : "RUNNING")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Palette.accent, in: Capsule())
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Key")
                    Menu {
                        ForEach(keyOptions, id: \.name) { option in
                            Button(option.name) { autoPress.selectedKeyName = option.name }
                        }
                    } label: {
                        HStack {
                            Text(autoPress.selectedKeyName)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 31)
                        .background(Palette.track, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(autoPress.phase != .ready)
                }
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Interval (sec)")
                    numberField("Interval seconds", text: $autoPress.intervalText)
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Repeats · 0 = ∞")
                    numberField("Repeat count", text: $autoPress.repeatText)
                }
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Start delay (sec)")
                    numberField("Start delay seconds", text: $autoPress.delayText)
                }
            }

            Button(action: autoPress.phase == .ready ? startPressing : autoPress.stop) {
                HStack(spacing: 8) {
                    Image(systemName: autoPress.phase == .ready ? "play.fill" : "stop.fill")
                    Text(autoPress.phase == .ready ? "Start pressing" : "Stop pressing")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(autoPress.phase == .ready ? Palette.accent : Color(red: 0.64, green: 0.29, blue: 0.39),
                            in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)

            HStack(alignment: .top, spacing: 8) {
                Text(autoPress.statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if autoPress.pressedCount > 0 {
                    Text("\(autoPress.pressedCount) sent")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                        .monospacedDigit()
                }
            }

            if !autoPress.permissionGranted {
                Button("Enable Accessibility") { autoPress.openAccessibilitySettings() }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.highlight)
                    .buttonStyle(.plain)
            }
        }
        .padding(18)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.secondary)
    }

    private func numberField(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 31)
            .background(Palette.track, in: RoundedRectangle(cornerRadius: 8))
            .disabled(autoPress.phase != .ready)
            .accessibilityLabel(label)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model = UsageModel()
    private let autoPress = AutoPressController()
    private let popover = NSPopover()
    private var timer: Timer?
    private var previewWindow: NSWindow?
    private var phaseCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isPreview = CommandLine.arguments.contains("--preview")
        NSApp.setActivationPolicy(isPreview ? .regular : .accessory)
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentSize = NSSize(width: 390, height: 230)
        let content = UsagePopover(
            model: model,
            autoPress: autoPress,
            refresh: { [weak self] in self?.refresh() },
            startPressing: { [weak self] in self?.startPressing() },
            quit: { NSApp.terminate(nil) }
        )
        popover.contentViewController = NSHostingController(rootView: content)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor(red: 0.32, green: 0.27, blue: 0.80, alpha: 1).cgColor
            button.layer?.cornerRadius = 11
        }
        renderStatus()
        autoPress.installStopHotkey()
        phaseCancellable = autoPress.$phase.sink { [weak self] _ in
            DispatchQueue.main.async { self?.renderStatus() }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if isPreview {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 390, height: 550),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Codex Usage Preview"
            window.contentView = NSHostingView(rootView: content)
            window.center()
            window.makeKeyAndOrderFront(nil)
            previewWindow = window
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            autoPress.refreshPermission()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        autoPress.stop()
        autoPress.removeStopHotkey()
    }

    private func startPressing() {
        if autoPress.start() {
            popover.performClose(nil)
        }
    }

    private func refresh() {
        guard !model.refreshing else { return }
        model.refreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try UsageFetcher.fetch() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.refreshing = false
                switch result {
                case .success(let snapshot):
                    self.model.snapshot = snapshot
                    self.model.error = nil
                case .failure(let error):
                    self.model.error = error.localizedDescription
                }
                self.renderStatus()
            }
        }
    }

    private func renderStatus() {
        let remaining = model.error == nil ? model.snapshot?.remainingPercent : nil
        let title = "Cx " + (remaining.map { "+\($0)%" } ?? "—")
        statusItem.button?.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.white
        ])
        statusItem.button?.toolTip = remaining.map { "Codex: \($0)% remaining" }
            ?? "Codex allowance unavailable"
        statusItem.button?.image = BrandIcon.status(active: autoPress.phase != .ready)
        statusItem.button?.imagePosition = .imageLeading
        let extraRows = max(0, (model.snapshot?.windows.count ?? 1) - 1)
        popover.contentSize = NSSize(
            width: 390,
            height: 535 + CGFloat(extraRows * 78) + (model.error == nil ? 0 : 34)
        )
    }
}

@main
private enum CodexUsageMenu {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains("--check") {
            do {
                let snapshot = try UsageFetcher.fetch()
                for window in snapshot.windows {
                    print("\(window.name): \(window.remainingPercent)% remaining")
                }
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
