import Foundation

/// USD per million text tokens at the reviewed Standard, short-context rate.
struct TokenCostRate: Equatable {
    let model: String
    let inputUSDPerMillion: Double
    let cachedInputUSDPerMillion: Double
    let outputUSDPerMillion: Double
    let sourceURL: String
}

struct TokenCostEstimate: Equatable {
    let apiEquivalentUSD: Double
    /// Cache-read discount compared with charging the same input uncached.
    /// This excludes cache-write premiums; it is not net caching savings.
    let cacheSavingsUSD: Double
    let uncachedInputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
}

struct TokenCostSummary: Equatable {
    let apiEquivalentUSD: Double
    let cacheSavingsUSD: Double
    let pricedTokens: Int64
    let unpricedTokens: Int64
    let invalidTokens: Int64
    let unpricedModels: [String]
    let invalidRowCount: Int
    let tokenCountOverflow: Bool

    var isPartial: Bool {
        unpricedTokens > 0 || invalidRowCount > 0 || tokenCountOverflow
    }
}

/// A local, dated comparison catalog, deliberately independent of account bills.
/// Matching is exact: a new model, custom model, or unverified snapshot stays
/// unpriced until its published rate has been reviewed.
enum TokenCostCatalog {
    static let reviewedOn = "2026-10-04"
    static let pricingURL = "https://developers.openai.com/api/docs/pricing"
    static let cachingURL = "https://developers.openai.com/api/docs/guides/prompt-caching"
    static let basisText = "USD · Standard API rates · short-context baseline"
    static let disclaimer = "Approximate API comparison at current published rates, not your Codex bill or historical spend. Local records do not identify cache writes, long-context pricing, service tiers, regional premiums, or tool fees. Cache savings show the cache-read discount only, before cache-write premiums. Unknown models are excluded."

    // The pricing page's official Markdown variant exposes its full Standard
    // table: https://developers.openai.com/api/docs/pricing.md. All rates below
    // were reviewed on reviewedOn; they are not date-specific historical rates.
    private static let rates: [String: TokenCostRate] = {
        let published: [(String, Double, Double, Double)] = [
            ("gpt-6-astra", 10, 1, 50),
            ("gpt-6.1-sol", 2, 0.10, 10),
            ("gpt-6-sol", 2, 0.20, 10),
            ("gpt-6-luna", 0.10, 0.01, 0.50),
            ("gpt-5.6-sol", 4, 0.40, 20),
            ("gpt-5.6-terra", 2, 0.20, 12),
            ("gpt-5.6-luna", 0.20, 0.02, 1.20),
            ("gpt-5.5", 5, 0.50, 30),
            ("gpt-5.4", 2.50, 0.25, 15),
            ("gpt-5.4-mini", 0.75, 0.075, 4.50),
            ("gpt-5.4-nano", 0.20, 0.02, 1.25),
            ("gpt-5.3-codex", 1.75, 0.175, 14),
            ("gpt-5.2", 1.75, 0.175, 14),
            ("gpt-5.1", 1.25, 0.125, 10),
            ("gpt-5", 1.25, 0.125, 10),
            ("gpt-5-mini", 0.25, 0.025, 2),
            ("gpt-5-nano", 0.05, 0.005, 0.40),
            ("gpt-4.1", 2, 0.50, 8),
            ("gpt-4.1-mini", 0.40, 0.10, 1.60),
            ("gpt-4.1-nano", 0.10, 0.025, 0.40),
            ("gpt-4o", 2.50, 1.25, 10),
            ("gpt-4o-mini", 0.15, 0.075, 0.60),
            ("o1", 15, 7.50, 60),
            ("o3", 2, 0.50, 8),
            ("o4-mini", 1.10, 0.275, 4.40),
            ("o3-mini", 1.10, 0.55, 4.40)
        ]
        var result = Dictionary(uniqueKeysWithValues: published.map { model, input, cached, output in
            (model, TokenCostRate(model: model, inputUSDPerMillion: input,
                                  cachedInputUSDPerMillion: cached, outputUSDPerMillion: output,
                                  sourceURL: pricingURL))
        })
        // Legacy Codex rates are still published on their individual model pages.
        let codex: [(String, Double, Double, Double)] = [
            ("gpt-5.2-codex", 1.75, 0.175, 14),
            ("gpt-5.1-codex", 1.25, 0.125, 10),
            ("gpt-5.1-codex-max", 1.25, 0.125, 10),
            ("gpt-5.1-codex-mini", 0.25, 0.025, 2),
            ("gpt-5-codex", 1.25, 0.125, 10)
        ]
        for (model, input, cached, output) in codex {
            result[model] = TokenCostRate(model: model, inputUSDPerMillion: input,
                cachedInputUSDPerMillion: cached, outputUSDPerMillion: output,
                sourceURL: "https://developers.openai.com/api/docs/models/\(model)")
        }
        return result
    }()

    // Only documented snapshots are allowed. Never strip arbitrary suffixes.
    // https://developers.openai.com/api/docs/models/gpt-5.5
    private static let aliases = ["gpt-5.5-2026-04-23": "gpt-5.5"]

    static func rate(for model: String) -> TokenCostRate? {
        rates[model] ?? aliases[model].flatMap { rates[$0] }
    }

    static func estimate(model: String, inputTokens: Int64, cachedInputTokens: Int64,
                         outputTokens: Int64) -> TokenCostEstimate? {
        guard let rate = rate(for: model), inputTokens >= 0, cachedInputTokens >= 0,
              cachedInputTokens <= inputTokens, outputTokens >= 0,
              !inputTokens.addingReportingOverflow(outputTokens).overflow else { return nil }
        let uncached = inputTokens - cachedInputTokens
        let inputMillions = Double(uncached) / 1_000_000
        let cachedMillions = Double(cachedInputTokens) / 1_000_000
        let outputMillions = Double(outputTokens) / 1_000_000
        return TokenCostEstimate(
            apiEquivalentUSD: inputMillions * rate.inputUSDPerMillion
                + cachedMillions * rate.cachedInputUSDPerMillion
                + outputMillions * rate.outputUSDPerMillion,
            cacheSavingsUSD: cachedMillions * (rate.inputUSDPerMillion - rate.cachedInputUSDPerMillion),
            uncachedInputTokens: uncached, cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens)
    }

    static func estimate(rows: [DailyTokenModelDay]) -> TokenCostSummary {
        var apiEquivalent = 0.0
        var cacheSavings = 0.0
        var priced: Int64 = 0
        var unpriced: Int64 = 0
        var invalid: Int64 = 0
        var invalidRows = 0
        var overflow = false
        var unpricedModels = Set<String>()
        for row in rows {
            let sum = row.inputTokens.addingReportingOverflow(row.outputTokens)
            guard row.totalTokens >= 0, row.inputTokens >= 0, row.outputTokens >= 0,
                  row.cachedInputTokens >= 0, row.cachedInputTokens <= row.inputTokens,
                  row.reasoningOutputTokens >= 0, row.reasoningOutputTokens <= row.outputTokens,
                  !sum.overflow, row.totalTokens == sum.partialValue else {
                add(max(row.totalTokens, 0), to: &invalid, overflow: &overflow)
                invalidRows += 1
                continue
            }
            guard let cost = estimate(model: row.model, inputTokens: row.inputTokens,
                                      cachedInputTokens: row.cachedInputTokens,
                                      outputTokens: row.outputTokens) else {
                add(row.totalTokens, to: &unpriced, overflow: &overflow)
                unpricedModels.insert(row.model)
                continue
            }
            apiEquivalent += cost.apiEquivalentUSD
            cacheSavings += cost.cacheSavingsUSD
            add(row.totalTokens, to: &priced, overflow: &overflow)
        }
        return TokenCostSummary(apiEquivalentUSD: apiEquivalent, cacheSavingsUSD: cacheSavings,
            pricedTokens: priced, unpricedTokens: unpriced, invalidTokens: invalid,
            unpricedModels: unpricedModels.sorted(), invalidRowCount: invalidRows,
            tokenCountOverflow: overflow)
    }

    private static func add(_ value: Int64, to total: inout Int64, overflow: inout Bool) {
        let sum = total.addingReportingOverflow(value)
        if sum.overflow { total = .max; overflow = true }
        else { total = sum.partialValue }
    }

    /// Synthetic formula and coverage checks; no sessions, network, or bills read.
    static func selfCheck() -> [String] {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        func close(_ value: Double?, _ expected: Double) -> Bool {
            value.map { abs($0 - expected) < 0.000001 } ?? false
        }
        let mixed = estimate(model: "gpt-6.1-sol", inputTokens: 2_000_000,
                             cachedInputTokens: 1_500_000, outputTokens: 500_000)
        check(close(mixed?.apiEquivalentUSD, 6.15), "Mixed input cost must charge cached tokens once")
        check(close(mixed?.cacheSavingsUSD, 2.85), "Cache-read discount formula")
        check(mixed?.uncachedInputTokens == 500_000, "Uncached input excludes cached subset")
        let uncached = estimate(model: "gpt-5.5", inputTokens: 1_000_000,
                                cachedInputTokens: 0, outputTokens: 2_000_000)
        check(close(uncached?.apiEquivalentUSD, 65) && close(uncached?.cacheSavingsUSD, 0),
              "Uncached formula")
        let cached = estimate(model: "gpt-6.1-sol", inputTokens: 2_000_000,
                              cachedInputTokens: 2_000_000, outputTokens: 0)
        check(close(cached?.apiEquivalentUSD, 0.20), "Fully cached input formula")
        check(rate(for: "gpt-5.5-2026-04-23") == rate(for: "gpt-5.5"), "Documented snapshot alias")
        for model in ["unknown", "custom-model", "gpt-6.2-sol", "gpt-5.5-2099-01-01"] {
            check(rate(for: model) == nil, "Unverified model must remain unpriced: \(model)")
        }
        check(estimate(model: "gpt-5.5", inputTokens: 1, cachedInputTokens: 2, outputTokens: 0) == nil,
              "Impossible cached subset must be rejected")
        check(estimate(model: "gpt-5.5", inputTokens: -1, cachedInputTokens: 0, outputTokens: 0) == nil,
              "Negative counters must be rejected")
        check(estimate(model: "gpt-5.5", inputTokens: .max, cachedInputTokens: 0, outputTokens: 1) == nil,
              "Overflowing token sum must be rejected")
        let pricedRow = DailyTokenModelDay(date: "2026-10-04", model: "gpt-6.1-sol",
            totalTokens: 2_500_000, inputTokens: 2_000_000, cachedInputTokens: 1_500_000,
            outputTokens: 500_000, reasoningOutputTokens: 400_000)
        let unknownRow = DailyTokenModelDay(date: "2026-10-04", model: "unknown",
            totalTokens: 4_000_000, inputTokens: 3_000_000, cachedInputTokens: 1_000_000,
            outputTokens: 1_000_000, reasoningOutputTokens: 0)
        let invalidRow = DailyTokenModelDay(date: "2026-10-04", model: "gpt-5.5",
            totalTokens: 100, inputTokens: 100, cachedInputTokens: 101,
            outputTokens: 0, reasoningOutputTokens: 0)
        let summary = estimate(rows: [pricedRow, unknownRow, invalidRow])
        check(close(summary.apiEquivalentUSD, 6.15) && close(summary.cacheSavingsUSD, 2.85),
              "Reasoning subset must not be charged again")
        check(summary.pricedTokens == 2_500_000 && summary.unpricedTokens == 4_000_000
              && summary.invalidTokens == 100 && summary.invalidRowCount == 1
              && summary.unpricedModels == ["unknown"] && summary.isPartial,
              "Partial price coverage must be explicit")
        let empty = estimate(rows: [])
        check(empty.apiEquivalentUSD == 0 && empty.pricedTokens == 0 && !empty.isPartial,
              "Empty usage produces empty estimates")
        let huge = DailyTokenModelDay(date: "2026-10-04", model: "gpt-6.1-sol", totalTokens: .max,
            inputTokens: .max, cachedInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0)
        check(estimate(rows: [huge, huge]).tokenCountOverflow, "Coverage sums must not wrap")
        return failures
    }
}
