// Appended to a temporary copy of the app's views by render_tutorial.sh.
// This produces documentation assets; it does not capture or control the desktop.
@main
private enum TutorialRenderer {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let destination = root.appendingPathComponent("assets/tutorial", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .darkAqua)
        app.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("assets/icon.png"))

        let timestamp = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: timestamp)
        let yesterday = formatter.string(from: timestamp.addingTimeInterval(-86400))
        let fixture: [DailyTokenModelDay] = [
            .init(date: today, model: "gpt-6.1-sol", totalTokens: 1_025_000,
                  inputTokens: 1_000_000, cachedInputTokens: 800_000, outputTokens: 25_000, reasoningOutputTokens: 7_000),
            .init(date: today, model: "gpt-6-sol", totalTokens: 515_000,
                  inputTokens: 500_000, cachedInputTokens: 450_000, outputTokens: 15_000, reasoningOutputTokens: 3_000),
            .init(date: today, model: "unknown", totalTokens: 20_000,
                  inputTokens: 19_900, cachedInputTokens: 0, outputTokens: 100, reasoningOutputTokens: 20),
            .init(date: yesterday, model: "gpt-6-sol", totalTokens: 360_000,
                  inputTokens: 350_000, cachedInputTokens: 250_000, outputTokens: 10_000, reasoningOutputTokens: 2_500),
            .init(date: yesterday, model: "gpt-5.3-codex", totalTokens: 1_020_000,
                  inputTokens: 1_000_000, cachedInputTokens: 700_000, outputTokens: 20_000, reasoningOutputTokens: 5_000)
        ]
        let groups = Dictionary(grouping: fixture, by: \.date)
        var days: [DailyTokenDay] = []
        for (date, rows) in groups {
            let total = rows.reduce(Int64(0)) { $0 + $1.totalTokens }
            let input = rows.reduce(Int64(0)) { $0 + $1.inputTokens }
            let cached = rows.reduce(Int64(0)) { $0 + $1.cachedInputTokens }
            let output = rows.reduce(Int64(0)) { $0 + $1.outputTokens }
            let reasoning = rows.reduce(Int64(0)) { $0 + $1.reasoningOutputTokens }
            days.append(DailyTokenDay(date: date, totalTokens: total, inputTokens: input,
                cachedInputTokens: cached, outputTokens: output, reasoningOutputTokens: reasoning))
        }
        days.sort { $0.date > $1.date }
        let usage = UsageModel()
        usage.snapshot = UsageSnapshot(windows: [
            LimitWindow(name: "5-hour window", remainingPercent: 73, resetsAt: timestamp.addingTimeInterval(7200)),
            LimitWindow(name: "Weekly window", remainingPercent: 61, resetsAt: timestamp.addingTimeInterval(172800))
        ], checkedAt: timestamp)
        let tokens = TokenUsageModel()
        tokens.snapshot = DailyTokenUsageSnapshot(days: days, checkedAt: timestamp, sourceFileCount: 5,
            unreadableFileCount: 0, skippedRecordCount: 0, retainedFileCount: 0, persistenceWarning: false,
            coverageSummary: "5 local session files", logURL: URL(fileURLWithPath: "/example/daily-token-usage.json"),
            modelDays: fixture)
        tokens.accountSnapshot = AccountTokenUsageSnapshot(
            lifetimeTokens: 42_000_000, peakDailyTokens: 6_250_000,
            days: [AccountTokenDay(startDate: today, tokens: 2_100_000),
                   AccountTokenDay(startDate: yesterday, tokens: 3_250_000)], checkedAt: timestamp)
        let clicker = AutoClickController()
        let presser = AutoPressController()
        // These defaults belong to this temporary renderer process, not the app.
        presser.intervalText = "1.0"
        presser.repeatText = "10"
        presser.delayText = "3.0"

        for (name, page) in [("allowance", PopoverPage.allowance), ("daily-tokens", .tokens), ("keyboard", .input)] {
            let view = UsagePopover(model: usage, tokens: tokens, autoClick: clicker, autoPress: presser,
                refresh: {}, startClicking: {}, startPressing: {}, openFullLog: {}, quit: {}, page: page)
            try render(labelled(view), width: 390, height: nil,
                       to: destination.appendingPathComponent(name + ".png"))
        }
        try render(labelled(TokenUsageLogView(model: tokens, refresh: {})), width: 1140, height: 760,
                   to: destination.appendingPathComponent("account-full-log.png"))
        try render(labelled(TokenUsageLogView(model: tokens, refresh: {}, source: .local)), width: 1140, height: 760,
                   to: destination.appendingPathComponent("full-log.png"))
        print("Rendered five tutorial images with synthetic data")
    }

    private static func labelled<V: View>(_ view: V) -> some View {
        VStack(spacing: 0) {
            view
            Text("Tutorial example · synthetic data")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Palette.background)
        }
        .background(Palette.background)
        .environment(\.colorScheme, .dark)
    }

    private static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat?, to url: URL) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let measuredHeight = height ?? hosting.fittingSize.height
        let bounds = NSRect(x: 0, y: 0, width: width, height: measuredHeight)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.frame = bounds
        hosting.layoutSubtreeIfNeeded()
        // Give AppKit-backed tables and controls a turn to finish their layout.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url, options: .atomic)
        window.contentView = nil
    }
}
