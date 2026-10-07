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
    private static func request(_ method: String) throws -> [String: Any] {
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
                "version": "1.4.0"
            ]]
        ])
        _ = try response(for: 1)
        try send(["method": "initialized"])
        try send(["method": method, "id": 2])
        return try response(for: 2)
    }

    static func fetchAccountTokens() throws -> AccountTokenUsageSnapshot {
        try AccountTokenUsageSnapshot.parse(request("account/usage/read"))
    }

    static func fetch() throws -> UsageSnapshot {
        let result = try request("account/rateLimits/read")
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

enum Palette {
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

final class TokenUsageModel: ObservableObject {
    @Published var accountSnapshot: AccountTokenUsageSnapshot?
    @Published var accountError: String?
    @Published var accountRefreshing = false
    @Published var snapshot: DailyTokenUsageSnapshot?
    @Published var error: String?
    @Published var refreshing = false
}

private enum PopoverPage: String, CaseIterable {
    case allowance = "Allowance"
    case tokens = "Tokens"
    case input = "Auto input"
}

private struct UsagePopover: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var tokens: TokenUsageModel
    @ObservedObject var autoClick: AutoClickController
    @ObservedObject var autoPress: AutoPressController
    let refresh: () -> Void
    let startClicking: () -> Void
    let startPressing: () -> Void
    let openFullLog: () -> Void
    let quit: () -> Void
    @State private var page: PopoverPage = .allowance

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 26, height: 26)
                Text("Codex Usage")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if let snapshot = model.snapshot {
                    Text(model.error == nil
                         ? "\(snapshot.remainingPercent)% left"
                         : "\(snapshot.remainingPercent)% last known")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                        .monospacedDigit()
                }
            }

            Picker("View", selection: $page) {
                ForEach(PopoverPage.allCases, id: \.self) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("App section")

            switch page {
            case .allowance:
                allowance
            case .tokens:
                AccountTokensPanel(model: tokens, openFullLog: openFullLog)
            case .input:
                AutoInputPanel(autoClick: autoClick, autoPress: autoPress,
                               startClicking: startClicking, startPressing: startPressing)
            }

            HStack(spacing: 12) {
                Text(updatedText)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                Spacer()
                if model.refreshing || tokens.refreshing || tokens.accountRefreshing {
                    ProgressView().controlSize(.small)
                        .frame(width: 24, height: 24)
                }
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 24, height: 24)
                }
                .disabled(page == .tokens ? tokens.accountRefreshing : model.refreshing)
                .help("Refresh allowance and token usage")
                .accessibilityLabel("Refresh usage")
                Button(action: quit) {
                    Image(systemName: "power").frame(width: 24, height: 24)
                }
                .help("Quit Codex Usage")
                .accessibilityLabel("Quit Codex Usage")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.secondary)
        }
        .padding(18)
        .frame(width: 390)
        .background(Palette.background)
    }

    private var updatedText: String {
        let date = page == .tokens ? tokens.accountSnapshot?.checkedAt : model.snapshot?.checkedAt
        return date.map { "Updated " + $0.formatted(date: .omitted, time: .shortened) } ?? "Codex usage"
    }

    @ViewBuilder private var allowance: some View {
        if let error = model.error {
            Text("Refresh failed: \(error)")
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 1, green: 0.75, blue: 0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        if let snapshot = model.snapshot {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                VStack(spacing: 18) {
                    ForEach(snapshot.windows, id: \.name) { window in
                        WindowRow(window: window, now: timeline.date)
                    }
                }
            }
            Text("Your signed-in Codex account. Profile token activity is in the next tab.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.error == nil {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking your allowance…")
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.secondary)
        }
    }
}

private struct AccountTokensPanel: View {
    @ObservedObject var model: TokenUsageModel
    let openFullLog: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Account token activity").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            if let error = model.accountError {
                Text("Account refresh failed: \(error)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 1, green: 0.75, blue: 0.72))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Use a recent Codex CLI signed in to the same ChatGPT account as Profile.")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let snapshot = model.accountSnapshot {
                if model.accountError != nil {
                    Text("Last fetched account values").font(.system(size: 11))
                        .foregroundStyle(Palette.secondary)
                }
                metric("Lifetime tokens", snapshot.lifetimeTokens)
                metric("Peak daily tokens", snapshot.peakDailyTokens)
                if let days = snapshot.days {
                    Divider().overlay(Palette.track)
                    Text("Recent account days").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    ForEach(Array(days.prefix(7)), id: \.startDate) { day in
                        HStack {
                            Text(day.startDate)
                            Spacer()
                            Text(day.tokens.formatted()).monospacedDigit()
                        }
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                    if days.isEmpty { note("No daily activity returned by the account service.") }
                } else {
                    note("Daily account activity is unavailable.")
                }
            } else if model.accountError == nil {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Fetching account token activity…")
                }
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            Button("Open full log", action: openFullLog)
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.plain).foregroundStyle(Palette.highlight)
            note("From the signed-in account’s token-activity service used by Profile. Dates are returned by the service; updates may be delayed. Local model and cost details are available in the full log.")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func metric(_ label: String, _ count: Int64?) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(Palette.secondary)
            Spacer(minLength: 4)
            Text(count.map { $0.formatted() } ?? "Unavailable")
                .foregroundStyle(.white).monospacedDigit()
        }
        .font(.system(size: 13))
    }
}

private enum AutoInputMode: String, CaseIterable {
    case mouse = "Mouse"
    case keyboard = "Keyboard"
}

private struct AutoInputPanel: View {
    @ObservedObject var autoClick: AutoClickController
    @ObservedObject var autoPress: AutoPressController
    let startClicking: () -> Void
    let startPressing: () -> Void
    @State private var mode: AutoInputMode = .mouse
    @State private var showOptions = false

    private var isMouse: Bool { mode == .mouse }
    private var isReady: Bool { autoClick.phase == .ready && autoPress.phase == .ready }
    private var hasPermission: Bool { isMouse ? autoClick.permissionGranted : autoPress.permissionGranted }
    private var interval: Binding<String> { isMouse ? $autoClick.intervalText : $autoPress.intervalText }
    private var repeats: Binding<String> { isMouse ? $autoClick.repeatText : $autoPress.repeatText }
    private var delay: Binding<String> { isMouse ? $autoClick.delayText : $autoPress.delayText }
    private var status: String { isMouse ? autoClick.statusText : autoPress.statusText }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Input type", selection: $mode) {
                ForEach(AutoInputMode.allCases, id: \.self) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!isReady)
            .accessibilityLabel("Automation type")

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel(isMouse ? "Mouse button" : "Key")
                    Menu {
                        if isMouse {
                            ForEach(MouseClickButton.allCases, id: \.self) { button in
                                Button(button.rawValue) { autoClick.selectedButton = button }
                            }
                        } else {
                            ForEach(keyOptions, id: \.name) { key in
                                Button(key.name) { autoPress.selectedKeyName = key.name }
                            }
                        }
                    } label: {
                        Text(isMouse ? autoClick.selectedButton.rawValue : autoPress.selectedKeyName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .menuStyle(.borderlessButton)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Palette.track, in: RoundedRectangle(cornerRadius: 8))
                    .disabled(!isReady)
                }
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Interval (sec)")
                    numberField("Interval seconds", text: interval)
                }
            }

            DisclosureGroup("Delay and repeat count", isExpanded: $showOptions) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Repeats · 0 = unlimited")
                        numberField("Repeat count", text: repeats)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Start delay (sec)")
                        numberField("Start delay seconds", text: delay)
                    }
                }
                .padding(.top, 8)
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.secondary)

            Button(action: performAction) {
                Label(isReady ? (isMouse ? "Start clicking" : "Start pressing") : "Stop",
                      systemImage: isReady ? "play.fill" : "stop.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .background(isReady ? Palette.accent : Color(red: 0.64, green: 0.29, blue: 0.39),
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            if !status.hasPrefix("Ready.") {
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(isMouse
                 ? "Clicks at the pointer. ⌘⌥S or reopening this menu stops."
                 : "Presses in the focused app. ⌘⌥S or reopening this menu stops.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !hasPermission {
                Button("Enable Accessibility") {
                    if isMouse { autoClick.openAccessibilitySettings() }
                    else { autoPress.openAccessibilitySettings() }
                }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(Palette.highlight)
            }
        }
    }

    private func performAction() {
        if isReady {
            if isMouse { startClicking() } else { startPressing() }
        } else {
            autoClick.stop()
            autoPress.stop()
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 11)).foregroundStyle(Palette.secondary)
    }

    private func numberField(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Palette.track, in: RoundedRectangle(cornerRadius: 8))
            .disabled(!isReady)
            .accessibilityLabel(label)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem: NSStatusItem
    private let model = UsageModel()
    private let tokens = TokenUsageModel()
    private let autoClick = AutoClickController()
    private let autoPress = AutoPressController()
    private let popover = NSPopover()
    private var timer: Timer?
    private var previewWindow: NSWindow?
    private var tokenLogWindow: NSWindow?
    private var phaseCancellables: [AnyCancellable] = []

    override init() {
        let name = "CodexUsage"
        let positionKey = "NSStatusItem Preferred Position \(name)"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(0, forKey: positionKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = name
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isPreview = CommandLine.arguments.contains("--preview")
        let isLogPreview = CommandLine.arguments.contains("--preview-log")
        NSApp.setActivationPolicy(isPreview || isLogPreview ? .regular : .accessory)
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentSize = NSSize(width: 390, height: 230)
        let content = UsagePopover(
            model: model,
            tokens: tokens,
            autoClick: autoClick,
            autoPress: autoPress,
            refresh: { [weak self] in self?.refresh() },
            startClicking: { [weak self] in self?.startClicking() },
            startPressing: { [weak self] in self?.startPressing() },
            openFullLog: { [weak self] in self?.openTokenLog() },
            quit: { NSApp.terminate(nil) }
        )
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            button.setAccessibilityIdentifier("CodexUsageMenu.statusItem")
        }
        renderStatus()
        autoClick.installStopHotkey()
        autoPress.installStopHotkey()
        phaseCancellables = [
            autoClick.$phase.sink { [weak self] _ in
                DispatchQueue.main.async { self?.renderStatus() }
            },
            autoPress.$phase.sink { [weak self] _ in
                DispatchQueue.main.async { self?.renderStatus() }
            }
        ]
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if isPreview {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 390, height: 680),
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
        if isLogPreview { openTokenLog() }
    }

    private func openTokenLog() {
        autoClick.stop()
        autoPress.stop()
        popover.performClose(nil)
        if tokenLogWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1140, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "Codex Usage Log"
            window.appearance = NSAppearance(named: .darkAqua)
            window.minSize = NSSize(width: 980, height: 580)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: TokenUsageLogView(
                model: tokens, refresh: { [weak self] in self?.refreshTokens(); self?.refreshAccountTokens() }
            ))
            window.center()
            tokenLogWindow = window
        }
        tokenLogWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            autoClick.stop()
            autoPress.stop()
            autoClick.refreshPermission()
            autoPress.refreshPermission()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        autoClick.stop()
        autoClick.removeStopHotkey()
        autoPress.stop()
        autoPress.removeStopHotkey()
    }

    private func startClicking() {
        autoPress.stop()
        if autoClick.start() {
            popover.performClose(nil)
        }
    }

    private func startPressing() {
        autoClick.stop()
        if autoPress.start() { popover.performClose(nil) }
    }

    private func refreshAccountTokens() {
        guard !tokens.accountRefreshing else { return }
        tokens.accountRefreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try UsageFetcher.fetchAccountTokens() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.tokens.accountRefreshing = false
                switch result {
                case .success(let snapshot):
                    self.tokens.accountSnapshot = snapshot
                    self.tokens.accountError = nil
                case .failure(let error):
                    self.tokens.accountError = error.localizedDescription
                }
            }
        }
    }

    private func refreshTokens() {
        guard !tokens.refreshing else { return }
        tokens.refreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try DailyTokenUsageReader.read() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.tokens.refreshing = false
                switch result {
                case .success(let snapshot):
                    self.tokens.snapshot = snapshot
                    self.tokens.error = nil
                case .failure(let error):
                    self.tokens.error = error.localizedDescription
                }
            }
        }
    }

    private func refresh() {
        refreshAccountTokens()
        refreshTokens()
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
        statusItem.button?.title = remaining.map { "\($0)%" } ?? "—"
        statusItem.button?.toolTip = remaining.map { "Codex: \($0)% remaining" }
            ?? "Codex allowance unavailable"
        statusItem.button?.image = BrandIcon.status(active: autoClick.phase != .ready || autoPress.phase != .ready)
        statusItem.button?.imagePosition = .imageLeading
    }
}

@main
private enum CodexUsageMenu {
    private static let delegate = AppDelegate()

    static func main() {
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains("--check-account-parser") {
            let failures = AccountTokenUsageSnapshot.selfCheck()
            for failure in failures { fputs("\(failure)\n", stderr) }
            guard failures.isEmpty else { exit(1) }
            print("Account token parser checks passed")
            return
        }
        if CommandLine.arguments.contains("--check-account-tokens") {
            do {
                let snapshot = try UsageFetcher.fetchAccountTokens()
                print("Lifetime tokens: \(snapshot.lifetimeTokens.map { String($0) } ?? "unavailable")")
                print("Peak daily tokens: \(snapshot.peakDailyTokens.map { String($0) } ?? "unavailable")")
                for day in (snapshot.days ?? []).prefix(7) {
                    print("\(day.startDate): \(day.tokens) tokens")
                }
                if snapshot.days == nil { print("Daily account activity unavailable") }
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--check-token-costs") {
            let failures = TokenCostCatalog.selfCheck() + TokenUsageLogReport.selfCheck()
            for failure in failures { fputs("\(failure)\n", stderr) }
            guard failures.isEmpty else { exit(1) }
            print("Token cost and log report checks passed")
            return
        }
        if CommandLine.arguments.contains("--check-input") {
            let failures = AutoClickController.selfCheck() + AutoPressController.selfCheck()
            for failure in failures { fputs("\(failure)\n", stderr) }
            guard failures.isEmpty else { exit(1) }
            print("Mouse and keyboard checks passed (no input sent)")
            return
        }
        if CommandLine.arguments.contains("--check-token-parser") {
            let failures = DailyTokenUsageReader.selfCheck()
            for failure in failures { fputs("\(failure)\n", stderr) }
            guard failures.isEmpty else { exit(1) }
            print("Daily token parser checks passed")
            return
        }
        if CommandLine.arguments.contains("--check-tokens") {
            do {
                let snapshot = try DailyTokenUsageReader.read()
                for day in snapshot.days.prefix(7) {
                    print("\(day.date): \(day.totalTokens) tokens")
                }
                print(snapshot.coverageSummary)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--check-clicker") {
            let failures = AutoClickController.selfCheck()
            for failure in failures { fputs("\(failure)\n", stderr) }
            guard failures.isEmpty else { exit(1) }
            print("Mouse clicker checks passed (no clicks sent)")
            return
        }
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
        app.delegate = delegate
        app.run()
    }
}
