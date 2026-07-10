import Foundation
import Combine
import OSLog

/// A single billable read-aloud event.
///
/// One record is written when a cloud request completes successfully (HTTP 2xx).
/// Apple provider reads are also recorded but with zero cost — useful for the
/// "reads per day" and "most used voice" stats without polluting spend numbers.
struct ReadAloudUsageRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    /// One of `"apple"`, `"elevenlabs"`, `"openai"` (matches `ReadAloudProvider.rawValue`).
    let provider: String
    /// Provider-specific model id (e.g. `"eleven_turbo_v2_5"`, `"tts-1"`).
    let model: String
    /// Provider-specific voice id / name.
    let voiceId: String
    let characterCount: Int
    /// Estimated cost in USD at time of the request. Cached so historical rows
    /// stay stable even if the pricing table below is later updated.
    let estimatedCostUSD: Double
}

/// Central bookkeeping for Read Aloud usage: what got read, by whom, and how
/// much it (probably) cost.
///
/// Pricing lives here so all UI surfaces read from the same source. Records
/// are persisted as a JSON blob in UserDefaults — small footprint, no schema
/// migration, easy to inspect. If the record count blows up past a few
/// thousand we can migrate to SwiftData; the aggregation API is designed so
/// swapping the store doesn't touch call sites.
@MainActor
final class ReadAloudUsageTracker: ObservableObject {
    static let shared = ReadAloudUsageTracker()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ReadAloud.Usage")

    private enum Keys {
        static let history = "readAloud.usageHistory"
        static let budget = "readAloud.monthlyBudgetUSD"
    }

    /// Newest last. Chronological append + prune keeps memory bounded.
    @Published private(set) var records: [ReadAloudUsageRecord] = []

    /// Monthly budget in USD. `0` disables the budget entirely (no warnings).
    @Published var monthlyBudgetUSD: Double {
        didSet { UserDefaults.standard.set(monthlyBudgetUSD, forKey: Keys.budget) }
    }

    /// Maximum history retained. Keeps the UserDefaults value small even after
    /// heavy usage; oldest records are dropped first.
    private let maxRecords = 5_000

    /// Records older than this many days are dropped on the next persist.
    private let retentionDays = 365

    private init() {
        let defaults = UserDefaults.standard
        self.monthlyBudgetUSD = defaults.double(forKey: Keys.budget)
        self.records = Self.loadRecords(defaults: defaults, logger: logger)
    }

    // MARK: - Recording

    /// Register a successful read. `characterCount` is the number of characters
    /// actually sent to the provider (post-trim). Cost is computed once, at
    /// write-time, so past records stay accurate even if the pricing table
    /// changes later.
    @discardableResult
    func record(
        provider: String,
        model: String,
        voiceId: String,
        characterCount: Int
    ) -> ReadAloudUsageRecord {
        let cost = Self.estimatedCostUSD(provider: provider, model: model, characterCount: characterCount)
        let record = ReadAloudUsageRecord(
            id: UUID(),
            timestamp: Date(),
            provider: provider,
            model: model,
            voiceId: voiceId,
            characterCount: characterCount,
            estimatedCostUSD: cost
        )
        records.append(record)
        pruneOld()
        persist()
        return record
    }

    /// Wipe all recorded usage. Used by the "Reset" button in settings.
    func resetAll() {
        records = []
        persist()
    }

    // MARK: - Pricing

    /// Estimated USD cost for a cloud request. Reflects public rates as of
    /// 2026-07 — Apple returns 0 (local). Update `pricingReference` alongside
    /// any change here.
    static func estimatedCostUSD(provider: String, model: String, characterCount: Int) -> Double {
        guard characterCount > 0 else { return 0 }
        let k = Double(characterCount) / 1_000.0
        let m = model.lowercased()

        switch provider.lowercased() {
        case "apple":
            return 0
        case "elevenlabs":
            if m.contains("flash") || m.contains("turbo") {
                return k * 0.05
            }
            // multilingual_v2, v3, eleven_english_sts_v2, etc.
            return k * 0.10
        case "openai":
            if m.contains("hd") {
                // tts-1-hd → $30 / 1M chars
                return Double(characterCount) / 1_000_000.0 * 30.0
            }
            // tts-1 and gpt-4o-mini-tts approx → $15 / 1M chars.
            // gpt-4o-mini-tts is actually token-priced but ~equivalent at this granularity.
            return Double(characterCount) / 1_000_000.0 * 15.0
        default:
            return 0
        }
    }

    /// Human-readable table for the settings footer / tooltips.
    static let pricingReference: String = """
    ElevenLabs Flash/Turbo: $0.05 / 1K chars
    ElevenLabs Multilingual v2 / v3: $0.10 / 1K chars
    OpenAI tts-1: $0.015 / 1K chars
    OpenAI tts-1-hd: $0.030 / 1K chars
    OpenAI gpt-4o-mini-tts: ~$0.015 / 1K chars (token-priced, approx)
    Apple (local): free
    """

    // MARK: - Aggregations

    /// Total spend across every record ever kept.
    var lifetimeCost: Double {
        records.reduce(0) { $0 + $1.estimatedCostUSD }
    }

    /// Total spend since the given date (inclusive).
    func totalCost(since date: Date, provider: String? = nil) -> Double {
        records.reduce(0) { acc, r in
            guard r.timestamp >= date else { return acc }
            if let provider, r.provider != provider { return acc }
            return acc + r.estimatedCostUSD
        }
    }

    /// Total characters sent since the given date (all providers or one).
    func totalCharacters(since date: Date, provider: String? = nil) -> Int {
        records.reduce(0) { acc, r in
            guard r.timestamp >= date else { return acc }
            if let provider, r.provider != provider { return acc }
            return acc + r.characterCount
        }
    }

    /// Number of read events since the given date.
    func readCount(since date: Date, provider: String? = nil) -> Int {
        records.reduce(0) { acc, r in
            guard r.timestamp >= date else { return acc }
            if let provider, r.provider != provider { return acc }
            return acc + 1
        }
    }

    /// Cost breakdown grouped by provider for the given time window.
    struct ProviderBreakdown: Identifiable {
        var id: String { provider }
        let provider: String
        let cost: Double
        let characters: Int
        let reads: Int
    }

    func breakdownByProvider(since date: Date) -> [ProviderBreakdown] {
        var groups: [String: (cost: Double, chars: Int, reads: Int)] = [:]
        for r in records where r.timestamp >= date {
            var g = groups[r.provider, default: (0, 0, 0)]
            g.cost += r.estimatedCostUSD
            g.chars += r.characterCount
            g.reads += 1
            groups[r.provider] = g
        }
        return groups
            .map { ProviderBreakdown(provider: $0.key, cost: $0.value.cost, characters: $0.value.chars, reads: $0.value.reads) }
            .sorted { $0.cost > $1.cost }
    }

    /// The voice used most (by character count) in the given window.
    func mostUsedVoice(since date: Date) -> (voice: String, provider: String, characters: Int)? {
        var totals: [String: (chars: Int, provider: String)] = [:]
        for r in records where r.timestamp >= date && r.provider != "apple" {
            var g = totals[r.voiceId, default: (0, r.provider)]
            g.chars += r.characterCount
            g.provider = r.provider
            totals[r.voiceId] = g
        }
        guard let best = totals.max(by: { $0.value.chars < $1.value.chars }) else { return nil }
        return (best.key, best.value.provider, best.value.chars)
    }

    // MARK: - Windows

    var startOfToday: Date {
        Calendar.current.startOfDay(for: Date())
    }

    var startOfThisWeek: Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())) ?? startOfToday
    }

    var startOfThisMonth: Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? startOfToday
    }

    // MARK: - Convenience totals

    var costToday: Double { totalCost(since: startOfToday) }
    var costThisWeek: Double { totalCost(since: startOfThisWeek) }
    var costThisMonth: Double { totalCost(since: startOfThisMonth) }

    // MARK: - Budget

    /// 0.0–1.0+ progress through the monthly budget. Nil when no budget is set.
    var budgetProgress: Double? {
        guard monthlyBudgetUSD > 0 else { return nil }
        return costThisMonth / monthlyBudgetUSD
    }

    var isOverBudget: Bool {
        guard let p = budgetProgress else { return false }
        return p >= 1.0
    }

    /// Linear projection of end-of-month spend based on average daily rate so far.
    /// Returns nil for the first day of the month (no data to project from).
    var projectedMonthlyCost: Double? {
        let cal = Calendar.current
        let now = Date()
        let start = startOfThisMonth
        let daysElapsed = max(1, cal.dateComponents([.day], from: start, to: now).day ?? 1)
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        let costSoFar = costThisMonth
        guard costSoFar > 0 else { return nil }
        let dailyRate = costSoFar / Double(daysElapsed)
        return dailyRate * Double(daysInMonth)
    }

    // MARK: - Persistence

    private static func loadRecords(defaults: UserDefaults, logger: Logger) -> [ReadAloudUsageRecord] {
        guard let data = defaults.data(forKey: Keys.history) else { return [] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([ReadAloudUsageRecord].self, from: data)
        } catch {
            logger.warning("Failed to decode usage history, starting fresh: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            UserDefaults.standard.set(data, forKey: Keys.history)
        } catch {
            logger.error("Failed to persist usage history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func pruneOld() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date.distantPast
        var trimmed = records.filter { $0.timestamp >= cutoff }
        if trimmed.count > maxRecords {
            trimmed = Array(trimmed.suffix(maxRecords))
        }
        records = trimmed
    }
}
