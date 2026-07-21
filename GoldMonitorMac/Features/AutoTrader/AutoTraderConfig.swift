import Foundation
import Combine
import SwiftUI

/// Trader "personality" — picks the timeframe trio + tunes the
/// continuous-mode parameters (run frequency, staleness window,
/// horizon framing in the prompt). One enum case per archetype.
///
/// Adding a new profile is a one-line `case` + the `meta` switch
/// entry. The engine reads `meta.timeframes` for the candle bundle
/// and `meta.recommended*` to snap the config's continuous-mode
/// knobs when the user picks the profile.
enum StrategyProfile: String, Codable, CaseIterable, Identifiable {
    /// 1h / 4h / 1d — patient, multi-day holds. Lowest run
    /// frequency; biggest stops. Good when you want to ride the
    /// macro structure without sweating intraday noise.
    case position
    /// 15m / 1h / 4h — the default. Intraday-to-multi-day
    /// horizon, anchored on 4h bias with 1h/15m execution.
    case swing
    /// 1m / 5m / 15m — scalper mode. Fast triggers, tight stops,
    /// lots of runs. Requires a fast tick source (or another
    /// sub-second tick source) to be useful — Yahoo's 10s polling
    /// lags badly at this timescale.
    case scalp

    var id: String { rawValue }

    struct Meta {
        let label: String
        let description: String
        let icon: String                  // SF Symbol
        let timeframes: [Timeframe]       // [low, mid, high] — order matters
        let recommendedRunsPerHour: Int
        let recommendedStalenessPercent: Double
        let recommendedStalenessMinutes: Int
        let recommendedRiskPercent: Double
        let recommendedTrailingATR: Double
        let horizonText: String           // injected into the user prompt
        let requiresLiveTickStream: Bool  // Scalp = yes; Swing/Position = polling is fine
    }

    var meta: Meta {
        switch self {
        case .position:
            return Meta(
                label: "Position",
                description: "1h / 4h / 1d · multi-day holds · widest stops · slowest cadence",
                icon: "tortoise.fill",
                timeframes: [.h1, .h4, .d1],
                recommendedRunsPerHour: 1,
                recommendedStalenessPercent: 1.5,
                recommendedStalenessMinutes: 240,
                recommendedRiskPercent: 2.0,
                recommendedTrailingATR: 2.0,
                horizonText: "Trade horizon: days to weeks. Pick patient setups with wide stops; ignore intraday noise.",
                requiresLiveTickStream: false
            )
        case .swing:
            return Meta(
                label: "Swing",
                description: "15m / 1h / 4h · intraday-to-multi-day · balanced cadence",
                icon: "figure.walk",
                timeframes: [.m15, .h1, .h4],
                recommendedRunsPerHour: 4,
                recommendedStalenessPercent: 0.5,
                recommendedStalenessMinutes: 30,
                recommendedRiskPercent: 1.0,
                recommendedTrailingATR: 1.5,
                horizonText: "Trade horizon: hours to a few days. Anchor on 4h bias, execute on 1h / 15m structure.",
                requiresLiveTickStream: false
            )
        case .scalp:
            return Meta(
                label: "Scalp",
                description: "1m / 5m / 15m · minutes-to-hours · fastest cadence · needs live tick source",
                icon: "bolt.fill",
                timeframes: [.m1, .m5, .m15],
                recommendedRunsPerHour: 12,
                recommendedStalenessPercent: 0.1,
                recommendedStalenessMinutes: 5,
                recommendedRiskPercent: 0.5,
                recommendedTrailingATR: 1.0,
                horizonText: "Trade horizon: minutes to an hour. Tight stops, fast invalidations. Take only the cleanest setups.",
                requiresLiveTickStream: true
            )
        }
    }
}

/// Per-pair auto-trader configuration. Captured by `AutoTraderCard`
/// in Settings; consumed by `AutoTraderEngine` when a fresh Confluence Trade Scanner
/// scenario arrives.
///
/// Two opt-in gates on purpose: `enabled` (master switch) must be
/// true *and* `paperMode` must be set to false to send real orders
/// to the broker. Either being wrong defaults to paper.
struct AutoTraderConfig: Codable, Equatable {
    var enabled: Bool                       = false
    var paperMode: Bool                     = true
    var riskPercent: Double                 = 1.0
    var trailingATRMultiple: Double?        = 1.5
    var atrPeriod: Int                      = 14
    var maxConcurrentPositions: Int         = 1
    var pauseDuringHighImpactNews: Bool     = true
    var maxDailyLossPercent: Double         = 3.0
    var cooldownAfterConsecutiveLosses: Int = 3
    var maxSpreadPips: Double?              = nil

    // ── Continuous-mode (the "trade assistant pro" loop) ──────────
    // When `continuousMode` is on, the engine keeps a rolling
    // analysis going: it validates the active scenario on every
    // tick, and on each 15m / 1h / 4h bar close decides whether to
    // re-run the Confluence Trade Scanner. Hard-capped by
    // `maxRunsPerHour` so the token spend stays bounded.
    var continuousMode: Bool                = true
    /// Hard rate limit: never fire more than N analyses per pair
    /// per hour. Defaults snap to the active `strategyProfile`'s
    /// recommendation (Swing = 4, Scalp = 12, Position = 1).
    var maxRunsPerHour: Int                 = 4
    /// "Stale entry" threshold: if live price drifts further than
    /// this percent (e.g. 0.5 = 0.5%) from the staged scenario's
    /// entry, the setup is no longer reachable — treat as
    /// invalidated and re-run.
    var stalenessPricePercent: Double       = 0.5
    /// On the fastest watched TF's bar close, only re-run if the
    /// prior analysis is at least this old. Higher TFs trigger
    /// runs more aggressively (mid TF if prior > 20min, highest
    /// TF always).
    var stalenessMinutes: Int               = 30
    /// Trader "personality" — picks the timeframe trio + tunes
    /// the continuous-mode defaults. Defaults to `.swing` so
    /// existing users see no behaviour change. Picking a profile
    /// snaps the relevant override fields above via `applyProfile`.
    var strategyProfile: StrategyProfile    = .swing

    static let `default` = AutoTraderConfig()

    /// Explicit init lets us also write a `decodeIfPresent`-style
    /// decoder below so old saved configs (pre-continuous-mode)
    /// keep loading instead of all resetting to .default.
    init(
        enabled: Bool = false,
        paperMode: Bool = true,
        riskPercent: Double = 1.0,
        trailingATRMultiple: Double? = 1.5,
        atrPeriod: Int = 14,
        maxConcurrentPositions: Int = 1,
        pauseDuringHighImpactNews: Bool = true,
        maxDailyLossPercent: Double = 3.0,
        cooldownAfterConsecutiveLosses: Int = 3,
        maxSpreadPips: Double? = nil,
        continuousMode: Bool = true,
        maxRunsPerHour: Int = 4,
        stalenessPricePercent: Double = 0.5,
        stalenessMinutes: Int = 30,
        strategyProfile: StrategyProfile = .swing
    ) {
        self.enabled = enabled
        self.paperMode = paperMode
        self.riskPercent = riskPercent
        self.trailingATRMultiple = trailingATRMultiple
        self.atrPeriod = atrPeriod
        self.maxConcurrentPositions = maxConcurrentPositions
        self.pauseDuringHighImpactNews = pauseDuringHighImpactNews
        self.maxDailyLossPercent = maxDailyLossPercent
        self.cooldownAfterConsecutiveLosses = cooldownAfterConsecutiveLosses
        self.maxSpreadPips = maxSpreadPips
        self.continuousMode = continuousMode
        self.maxRunsPerHour = maxRunsPerHour
        self.stalenessPricePercent = stalenessPricePercent
        self.stalenessMinutes = stalenessMinutes
        self.strategyProfile = strategyProfile
    }

    enum CodingKeys: String, CodingKey {
        case enabled, paperMode, riskPercent, trailingATRMultiple, atrPeriod
        case maxConcurrentPositions, pauseDuringHighImpactNews
        case maxDailyLossPercent, cooldownAfterConsecutiveLosses, maxSpreadPips
        case continuousMode, maxRunsPerHour, stalenessPricePercent, stalenessMinutes
        case strategyProfile
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        self.paperMode = (try? c.decode(Bool.self, forKey: .paperMode)) ?? true
        self.riskPercent = (try? c.decode(Double.self, forKey: .riskPercent)) ?? 1.0
        self.trailingATRMultiple = try? c.decode(Double?.self, forKey: .trailingATRMultiple) ?? 1.5
        self.atrPeriod = (try? c.decode(Int.self, forKey: .atrPeriod)) ?? 14
        self.maxConcurrentPositions = (try? c.decode(Int.self, forKey: .maxConcurrentPositions)) ?? 1
        self.pauseDuringHighImpactNews = (try? c.decode(Bool.self, forKey: .pauseDuringHighImpactNews)) ?? true
        self.maxDailyLossPercent = (try? c.decode(Double.self, forKey: .maxDailyLossPercent)) ?? 3.0
        self.cooldownAfterConsecutiveLosses = (try? c.decode(Int.self, forKey: .cooldownAfterConsecutiveLosses)) ?? 3
        self.maxSpreadPips = try? c.decode(Double?.self, forKey: .maxSpreadPips)
        self.continuousMode = (try? c.decode(Bool.self, forKey: .continuousMode)) ?? true
        self.maxRunsPerHour = (try? c.decode(Int.self, forKey: .maxRunsPerHour)) ?? 4
        self.stalenessPricePercent = (try? c.decode(Double.self, forKey: .stalenessPricePercent)) ?? 0.5
        self.stalenessMinutes = (try? c.decode(Int.self, forKey: .stalenessMinutes)) ?? 30
        self.strategyProfile = (try? c.decode(StrategyProfile.self, forKey: .strategyProfile)) ?? .swing
    }

    /// Snap the continuous-mode + risk knobs to the picked
    /// profile's recommended defaults. Called when the user
    /// switches strategy in the Auto-Trader card — gives them a
    /// clean slate of profile-tuned values rather than carrying
    /// stale tweaks from the previous profile.
    mutating func applyProfile(_ profile: StrategyProfile) {
        let meta = profile.meta
        strategyProfile = profile
        maxRunsPerHour = meta.recommendedRunsPerHour
        stalenessPricePercent = meta.recommendedStalenessPercent
        stalenessMinutes = meta.recommendedStalenessMinutes
        riskPercent = meta.recommendedRiskPercent
        trailingATRMultiple = meta.recommendedTrailingATR
    }

    private static func storageKey(_ pairID: String) -> String {
        "autoTrader.v1.\(pairID)"
    }

    static func load(pairID: String) -> AutoTraderConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey(pairID)),
              let decoded = try? JSONDecoder().decode(AutoTraderConfig.self, from: data)
        else { return .default }
        return decoded
    }

    func save(pairID: String) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey(pairID))
        }
    }
}

/// Owns the per-pair `AutoTraderConfig` map and bridges
/// `@AppStorage`-style change observation. SwiftUI views bind to
/// this for live updates; the engine observes the same store so a
/// Settings edit immediately changes the running behaviour.
@MainActor
final class AutoTraderConfigStore: ObservableObject {
    @Published private(set) var byPair: [String: AutoTraderConfig] = [:]

    init() {
        // Seed from disk on init — every TradingPair.catalog entry
        // gets a config slot (default `.default`) so the Settings
        // list renders without lazy loading flicker.
        for def in TradingPair.catalog {
            byPair[def.id] = AutoTraderConfig.load(pairID: def.id)
        }
    }

    func config(for pairID: String) -> AutoTraderConfig {
        byPair[pairID] ?? .default
    }

    func update(_ config: AutoTraderConfig, for pairID: String) {
        byPair[pairID] = config
        config.save(pairID: pairID)
    }

    /// Convenience binding for SwiftUI inputs that mutate one
    /// field of the per-pair config. The binding's `set` writes
    /// through to the store + disk.
    func binding<V>(
        for pairID: String,
        _ keyPath: WritableKeyPath<AutoTraderConfig, V>
    ) -> Binding<V> {
        Binding(
            get: { self.config(for: pairID)[keyPath: keyPath] },
            set: { newValue in
                var cfg = self.config(for: pairID)
                cfg[keyPath: keyPath] = newValue
                self.update(cfg, for: pairID)
            }
        )
    }
}

