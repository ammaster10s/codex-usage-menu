import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum TokenUsageLogReport {
    static func byModel(_ rows: [DailyTokenModelDay]) -> [DailyTokenModelDay] {
        Dictionary(grouping: rows, by: \.model).map { model, rows in
            DailyTokenModelDay(date: "", model: model,
                totalTokens: rows.reduce(0) { $0 + $1.totalTokens },
                inputTokens: rows.reduce(0) { $0 + $1.inputTokens },
                cachedInputTokens: rows.reduce(0) { $0 + $1.cachedInputTokens },
                outputTokens: rows.reduce(0) { $0 + $1.outputTokens },
                reasoningOutputTokens: rows.reduce(0) { $0 + $1.reasoningOutputTokens })
        }.sorted {
            $0.totalTokens == $1.totalTokens ? $0.model < $1.model : $0.totalTokens > $1.totalTokens
        }
    }

    static func csv(_ rows: [DailyTokenModelDay]) -> String {
        let header = "day,model,input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,total_tokens,estimated_api_usd,estimated_cache_savings_usd,pricing_reviewed,pricing_source"
        let lines = rows.sorted { $0.date == $1.date ? $0.model < $1.model : $0.date > $1.date }.map { row in
            let estimate = TokenCostCatalog.estimate(model: row.model, inputTokens: row.inputTokens,
                cachedInputTokens: row.cachedInputTokens, outputTokens: row.outputTokens)
            let rate = estimate == nil ? nil : TokenCostCatalog.rate(for: row.model)
            let fields = [row.date, row.model, String(row.inputTokens), String(row.cachedInputTokens),
                String(row.outputTokens), String(row.reasoningOutputTokens), String(row.totalTokens),
                estimate.map { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), $0.apiEquivalentUSD) } ?? "",
                estimate.map { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), $0.cacheSavingsUSD) } ?? "",
                rate == nil ? "" : TokenCostCatalog.reviewedOn, rate?.sourceURL ?? ""]
            return fields.map(csvField).joined(separator: ",")
        }
        return ([header] + lines).joined(separator: "\r\n") + "\r\n"
    }

    private static func csvField(_ value: String) -> String {
        // Quoting alone does not stop spreadsheet formula interpretation.
        let safe = value.first.map { "=+-@\t\r\n".contains($0) } == true ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func selfCheck() -> [String] {
        let rows = [
            DailyTokenModelDay(date: "2026-10-03", model: "gpt-5.3-codex", totalTokens: 150,
                inputTokens: 100, cachedInputTokens: 80, outputTokens: 50, reasoningOutputTokens: 20),
            DailyTokenModelDay(date: "2026-10-04", model: "gpt-5.3-codex", totalTokens: 30,
                inputTokens: 20, cachedInputTokens: 10, outputTokens: 10, reasoningOutputTokens: 5),
            DailyTokenModelDay(date: "2026-10-04", model: "=unknown,\"model\"", totalTokens: 10,
                inputTokens: 10, cachedInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0)
        ]
        var failures: [String] = []
        let grouped = byModel(rows)
        if grouped.count != 2 || grouped.first?.totalTokens != 180 || grouped.first?.cachedInputTokens != 90 {
            failures.append("Model report aggregation failed")
        }
        let export = csv(rows)
        if !export.contains("\"'=unknown,\"\"model\"\"\"") {
            failures.append("CSV escaping and formula protection failed")
        }
        if !export.contains("\"10\",\"\",\"\"") {
            failures.append("Unpriced CSV rows must have empty cost fields")
        }
        return failures
    }
}

private enum UsageLogPeriod: String, CaseIterable {
    case all = "All history"
    case month = "This month"
    case week = "Last 7 days"
    case today = "Today"
}

private enum UsageLogGrouping: String, CaseIterable {
    case models = "By model"
    case days = "Daily history"
}

private struct UsageLogRow: Identifiable {
    let usage: DailyTokenModelDay
    var id: String { usage.date + "|" + usage.model }
    var estimate: TokenCostEstimate? {
        TokenCostCatalog.estimate(model: usage.model, inputTokens: usage.inputTokens,
            cachedInputTokens: usage.cachedInputTokens, outputTokens: usage.outputTokens)
    }
}

struct TokenUsageLogView: View {
    @ObservedObject var model: TokenUsageModel
    let refresh: () -> Void
    @State private var period: UsageLogPeriod = .all
    @State private var grouping: UsageLogGrouping = .models
    @State private var selectedModel = ""
    @State private var showComparison = false
    @State private var showAssumptions = false
    @State private var exportError: String?
    @AppStorage("usageLog.monthlySubscriptionUSD") private var subscriptionText = ""

    private var availableModels: [String] {
        Array(Set(model.snapshot?.modelDays.map(\.model) ?? [])).sorted()
    }

    private var filtered: [DailyTokenModelDay] {
        let lowerBound: String?
        switch period {
        case .all: lowerBound = nil
        case .today: lowerBound = Self.dayKey(Date())
        case .month: lowerBound = String(Self.dayKey(Date()).prefix(7)) + "-01"
        case .week:
            lowerBound = Self.dayKey(Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date())
        }
        return (model.snapshot?.modelDays ?? []).filter {
            (selectedModel.isEmpty || $0.model == selectedModel) && (lowerBound == nil || $0.date >= lowerBound!)
        }
    }

    private var rows: [UsageLogRow] {
        let usage = grouping == .models ? TokenUsageLogReport.byModel(filtered) : filtered
        return usage.map { UsageLogRow(usage: $0) }
    }

    private var summary: TokenCostSummary { TokenCostCatalog.estimate(rows: filtered) }
    private var totalTokens: Int64 { filtered.reduce(0) { $0 + $1.totalTokens } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let error = model.error { warning("Refresh failed: \(error). Showing last recorded usage.") }
            if let error = exportError { warning("CSV export failed: \(error)") }
            if let snapshot = model.snapshot {
                totals
                HStack(spacing: 14) {
                    Picker("Grouping", selection: $grouping) {
                        ForEach(UsageLogGrouping.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                    Spacer()
                    Picker("Model", selection: $selectedModel) {
                        Text("All models").tag("")
                        ForEach(availableModels, id: \.self) { Text(Self.modelName($0)).tag($0) }
                    }
                    .frame(width: 270)
                }
                if rows.isEmpty {
                    VStack(spacing: 8) {
                        Text("No token records in this selection").font(.headline)
                        Text("Choose another period or use Codex on this Mac, then refresh.")
                            .foregroundStyle(Palette.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    usageTable
                }
                if summary.unpricedTokens > 0 || summary.invalidTokens > 0 {
                    warning("\((summary.unpricedTokens + summary.invalidTokens).formatted()) tokens excluded from cost estimates: model pricing is unavailable or counters are invalid.")
                }
                DisclosureGroup("Compare this month with a subscription", isExpanded: $showComparison) {
                    subscriptionComparison.padding(.top, 8)
                }
                .font(.system(size: 12))
                DisclosureGroup("Estimate assumptions", isExpanded: $showAssumptions) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(TokenCostCatalog.disclaimer).fixedSize(horizontal: false, vertical: true)
                        Text("Cached input is included in input; reasoning is included in output. Unknown models are kept in the token totals and excluded from the dollar estimate.")
                            .fixedSize(horizontal: false, vertical: true)
                        Link("OpenAI pricing · reviewed \(TokenCostCatalog.reviewedOn)", destination: URL(string: TokenCostCatalog.pricingURL)!)
                    }
                    .foregroundStyle(Palette.secondary).padding(.top, 8)
                }
                .font(.system(size: 12))
                footer(snapshot)
            } else {
                VStack(spacing: 12) {
                    if model.refreshing {
                        ProgressView()
                        Text("Indexing local Codex records and model names…")
                    } else {
                        Text("Usage log unavailable").font(.headline)
                        Button("Try again", action: refresh)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(24)
        .foregroundStyle(.white)
        .background(Palette.background)
        .frame(minWidth: 940, minHeight: 540)
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Usage log").font(.system(size: 24, weight: .semibold))
                Text("Local Codex history · \(TimeZone.autoupdatingCurrent.identifier)")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            Spacer()
            Picker("Period", selection: $period) {
                ForEach(UsageLogPeriod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 190)
            Button(action: refresh) { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(model.refreshing)
            Button("Export CSV", action: exportCSV).disabled(filtered.isEmpty)
        }
    }

    private var totals: some View {
        HStack(alignment: .firstTextBaseline, spacing: 32) {
            total("Recorded tokens", value: totalTokens.formatted())
            total(summary.isPartial || model.snapshot?.hasCoverageWarning == true ? "API equivalent · partial" : "Estimated API equivalent",
                  value: summary.pricedTokens > 0 ? Self.usd(summary.apiEquivalentUSD) : "Unavailable")
            total("Estimated cache savings", value: summary.pricedTokens > 0 ? Self.usd(summary.cacheSavingsUSD) : "Unavailable")
            Spacer()
            if model.refreshing { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 6)
    }

    private func total(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.secondary)
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit()
        }
    }

    private var usageTable: some View {
        Table(rows) {
            TableColumn("Model") { row in
                Text(Self.modelName(row.usage.model)).help(row.usage.model)
            }.width(min: 140, ideal: 160)
            TableColumn("Day") { row in Text(row.usage.date.isEmpty ? "All selected" : row.usage.date) }
                .width(86)
            TableColumn("Input") { row in number(row.usage.inputTokens) }.width(min: 84, ideal: 94)
            TableColumn("Cached input") { row in number(row.usage.cachedInputTokens) }.width(min: 84, ideal: 94)
            TableColumn("Output") { row in number(row.usage.outputTokens) }.width(min: 70, ideal: 75)
            TableColumn("Reasoning") { row in number(row.usage.reasoningOutputTokens) }.width(min: 70, ideal: 75)
            TableColumn("Total") { row in number(row.usage.totalTokens) }.width(min: 84, ideal: 94)
            TableColumn("API estimate") { row in
                Text(row.estimate.map { Self.usd($0.apiEquivalentUSD) } ?? "Unpriced")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.width(90)
            TableColumn("Cache savings") { row in
                Text(row.estimate.map { Self.usd($0.cacheSavingsUSD) } ?? "Unpriced")
                    .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                    .help("Estimated cache-read discount compared with uncached input; cache-write premiums are excluded.")
            }.width(90)
        }
        .font(.system(size: 12))
    }

    private func number(_ count: Int64) -> some View {
        Text(count.formatted()).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var subscriptionComparison: some View {
        let month = String(Self.dayKey(Date()).prefix(7))
        let monthRows = (model.snapshot?.modelDays ?? []).filter { $0.date.hasPrefix(month + "-") }
        let cost = TokenCostCatalog.estimate(rows: monthRows)
        let partial = cost.isPartial || model.snapshot?.hasCoverageWarning == true || model.error != nil
        let price = Double(subscriptionText.trimmingCharacters(in: .whitespacesAndNewlines))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Monthly subscription (USD)")
                TextField("e.g. 20.00", text: $subscriptionText)
                    .textFieldStyle(.roundedBorder).frame(width: 110)
                    .accessibilityLabel("Monthly subscription price in USD")
                Spacer()
                Text("\(month) · all models").foregroundStyle(Palette.secondary)
            }
            if let price, price.isFinite, price >= 0, cost.pricedTokens > 0 {
                let difference = cost.apiEquivalentUSD - price
                Text(difference >= 0
                     ? "Estimated API cost less subscription: \(Self.usd(difference))"
                     : "Subscription exceeds the API estimate by \(Self.usd(-difference))")
                    .fontWeight(.medium)
                Text("Month-to-date API equivalent: \(Self.usd(cost.apiEquivalentUSD)). Compared with the full monthly price you entered; other subscription benefits are not valued.\(partial ? " The comparison is partial because pricing or source coverage is incomplete." : "")")
                    .foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            } else if !subscriptionText.isEmpty {
                Text("Enter a nonnegative USD amount. Priced usage is needed for a comparison.")
                    .foregroundStyle(Palette.secondary)
            } else {
                Text("Enter your monthly price to compare this month's recorded usage. This is a hypothetical API comparison, not money actually paid or saved.")
                    .foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func footer(_ snapshot: DailyTokenUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(snapshot.coverageSummary)
                    .foregroundStyle(snapshot.hasCoverageWarning ? Color(red: 1, green: 0.75, blue: 0.72) : Palette.secondary)
                Spacer()
                Button("Reveal JSON log") { NSWorkspace.shared.activateFileViewerSelecting([snapshot.logURL]) }
                Text("Updated " + snapshot.checkedAt.formatted(date: .omitted, time: .shortened))
                    .foregroundStyle(Palette.secondary)
            }
            Text("Estimated USD at current standard API rates; cache savings exclude cache-write premiums. ChatGPT chats, other devices, actual bills, and subscription charges are not included.")
                .foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
    }

    private func warning(_ message: String) -> some View {
        Text(message).font(.system(size: 12))
            .foregroundStyle(Color(red: 1, green: 0.75, blue: 0.72))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func exportCSV() {
        let exportedRows = filtered
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "codex-token-usage.csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try TokenUsageLogReport.csv(exportedRows).write(to: url, atomically: true, encoding: .utf8)
                exportError = nil
            } catch { exportError = error.localizedDescription }
        }
    }

    private static func modelName(_ model: String) -> String { model == "unknown" ? "Unknown model" : model }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func usd(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: NSNumber(value: amount)) ?? "$0.00"
    }
}
