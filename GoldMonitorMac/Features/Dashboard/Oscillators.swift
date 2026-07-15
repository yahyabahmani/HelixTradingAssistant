import Foundation
import SwiftUI

/// Oscillator-class technical indicators. Unlike SMA/EMA/Bollinger
/// (overlaid on the price chart), these run on their own Y scale —
/// RSI/Stoch are 0-100, MACD oscillates around zero — so they render in
/// their own sub-panels below the main chart.
enum OscillatorKind: String, CaseIterable, Identifiable, Hashable, Codable {
    case rsi
    case macd
    case stochastic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rsi:        return "RSI"
        case .macd:       return "MACD"
        case .stochastic: return "Stochastic"
        }
    }

    /// Keys (and defaults) for every tunable parameter this oscillator accepts.
    var paramSpecs: [ParamSpec] {
        switch self {
        case .rsi:        return [.double(key: "period", label: "Period", default: 14, step: 1, range: 2...100)]
        case .macd:
            return [
                .double(key: "fast", label: "Fast EMA", default: 12, step: 1, range: 2...50),
                .double(key: "slow", label: "Slow EMA", default: 26, step: 1, range: 3...100),
                .double(key: "signal", label: "Signal EMA", default: 9, step: 1, range: 2...50),
            ]
        case .stochastic:
            return [
                .double(key: "k", label: "%K Period", default: 14, step: 1, range: 2...50),
                .double(key: "d", label: "%D Period", default: 3, step: 1, range: 1...20),
            ]
        }
    }
}

/// One instance of an oscillator panel on the chart.
struct OscillatorInstance: Identifiable, Hashable, Codable {
    let id: UUID
    let kind: OscillatorKind
    var params: [String: ParamValue]
    var hidden: Bool

    init(id: UUID = UUID(), kind: OscillatorKind, params: [String: ParamValue] = [:], hidden: Bool = false) {
        self.id = id
        self.kind = kind
        self.params = params
        for spec in kind.paramSpecs {
            if self.params[spec.key] == nil { self.params[spec.key] = spec.defaultValue }
        }
        self.hidden = hidden
    }

    var label: String {
        switch kind {
        case .rsi:
            return "RSI (\(Int(params["period"]?.doubleValue ?? 14)))"
        case .macd:
            let f = Int(params["fast"]?.doubleValue ?? 12)
            let s = Int(params["slow"]?.doubleValue ?? 26)
            let sig = Int(params["signal"]?.doubleValue ?? 9)
            return "MACD (\(f), \(s), \(sig))"
        case .stochastic:
            let k = Int(params["k"]?.doubleValue ?? 14)
            let d = Int(params["d"]?.doubleValue ?? 3)
            return "Stochastic (\(k), \(d))"
        }
    }
}

/// Tunable parameters for every oscillator. Persisted to UserDefaults so
/// the user's preferred period sticks across launches. All ints — these
/// indicators don't have non-integer parameters in practice.
struct OscillatorConfig: Codable, Equatable {
    var rsiPeriod: Int = 14
    var macdFast: Int = 12
    var macdSlow: Int = 26
    var macdSignal: Int = 9
    var stochK: Int = 14
    var stochD: Int = 3

    // UT Bot Alerts parameters (PineScript v4 port). `keyValue` is the
    // sensitivity multiplier (`a` in Pine), `atrPeriod` is the ATR
    // window (`c`), and `utUseHeikinAshi` swaps the signal source from
    // raw closes to Heikin Ashi closes (Pine's `h` input).
    var utKeyValue: Double = 1.0
    var utATRPeriod: Int = 10
    var utUseHeikinAshi: Bool = false
    /// Visibility of the amber trailing-stop line itself. When off, the
    /// UT Bot still computes positions and emits buy/sell labels — just
    /// the visual stop line is hidden. Some traders want the signals
    /// without the clutter of the stepped line behind their candles.
    var utShowTrailingStop: Bool = true

    // Order Block Finder parameters (PineScript v4 port). `obPeriods` is
    // the required same-direction run length after the OB candle (Pine's
    // `periods`), `obThreshold` the minimum % move that validates the
    // block (`threshold`), and `obUseWicks` marks the candle's full
    // high/low range instead of open→low (bull) / open→high (bear).
    var obPeriods: Int = 5
    var obThreshold: Double = 0.0
    var obUseWicks: Bool = false
    var obShowExhausted: Bool = true
    var obDetectSteroids: Bool = false
    /// Fire a system notification when an Order Block appears, gets its
    /// first retest, or is exhausted. Opt-in (default off) — evaluating
    /// this costs an extra full-history `OrderBlocks.compute` on every
    /// candle refresh, so users who don't care about the alerts pay
    /// nothing. See `AlertStore.evaluateOrderBlocks`.
    var obNotifyEvents: Bool = false

    // Steroid Order Blocks parameters.
    var sobPeriods: Int = 5
    var sobThreshold: Double = 0.0
    var sobUseWicks: Bool = false
    var sobVolumeMultiplier: Double = 1.2
    var sobShowExhausted: Bool = true
    var sobDetectSteroids: Bool = true
    /// Same lifecycle notifications as `obNotifyEvents`, for Steroid
    /// Order Blocks.
    var sobNotifyEvents: Bool = false

    // Trading Sessions overlay (Pine v6 "Trading Sessions" port). The
    // four `sessShow…` flags mirror the Pine display inputs; the three
    // per-session flags let the user show only the venues they trade.
    // Session times / timezones / colours are baked to the canonical
    // Tokyo / London / New York presets — see `TradingSessions.catalog`.
    var sessShowNames: Bool = true
    var sessShowOpenClose: Bool = true
    var sessShowRange: Bool = true
    var sessShowAverage: Bool = true
    var sessShowTokyo: Bool = true
    var sessShowLondon: Bool = true
    var sessShowNewYork: Bool = true

    // NY Open Setup (5m opening-range breakout + FVG-retest). `nyAtrMult`
    // is the "power breakout" gate — the displacement body must be at
    // least this many ATR(14). `nyAMOnly` limits the hunt to the morning
    // kill-zone (09:35–11:00 ET) vs the whole NY session. Entry (FVG 50%),
    // stop (beyond the OR) and target (2R) are fixed — see `NYOpenSetup`.
    var nyAtrMult: Double = 1.0
    var nyAMOnly: Bool = true

    // SP2L defaults follow the source video: a short 2-4 bar pressure
    // move out of balance, first-pullback limit entry, EMA(60) context,
    // and a 1R target. Detection runs on every chart timeframe; numeric
    // thresholds not specified by the teacher remain tunable.
    var sp2lMinSpikeBars: Int = 2
    var sp2lMaxSpikeBars: Int = 4
    var sp2lRangeBars: Int = 4
    var sp2lATRPeriod: Int = 14
    var sp2lMinSpikeATR: Double = 1.0
    var sp2lMaxSpikeATR: Double = 3.0
    var sp2lMaxRangeATR: Double = 1.5
    var sp2lMinGapPct: Double = 0.0
    var sp2lMaxPressureGapBar: Int = 3
    var sp2lEMAPeriod: Int = 60
    var sp2lUseEMAContext: Bool = true
    var sp2lMaxEMADistanceATR: Double = 1.0
    var sp2lMaxPullbackBars: Int = 6
    var sp2lMaxContinuationBars: Int = 10
    var sp2lRiskReward: Double = 1.0
    var sp2lTargetCount: Int = 1

    // Pin-bar confirmation for SP2L pullbacks and BTB broken-level retests.
    var pinBarEnableSP2L: Bool = true
    var pinBarEnableBTB: Bool = true
    var pinBarATRPeriod: Int = 14
    var pinBarMinWickBodyRatio: Double = 2.0
    var pinBarMinWickRangeRatio: Double = 0.55
    var pinBarMaxBodyRangeRatio: Double = 0.35
    var pinBarMinCloseLocation: Double = 0.65
    var pinBarOppositeWickDominance: Double = 1.5
    var pinBarTouchToleranceATR: Double = 0.10
    var pinBarStopBufferATR: Double = 0.05
    var pinBarMaxConfirmationBars: Int = 8
    var pinBarBTBLookbackBars: Int = 12
    var pinBarMinBreakoutBodyATR: Double = 0.50
    var pinBarRiskReward: Double = 2.0
    var pinBarMaxContinuationBars: Int = 20

    // MicroMap continuation strategy. Entries and stops are confirmed by
    // candle close; targets use the candle high/low after entry.
    var microMapATRPeriod: Int = 14
    var microMapMinSpikeBars: Int = 2
    var microMapMaxSpikeBars: Int = 6
    var microMapMinSpikeATR: Double = 1.5
    var microMapMinDirectionalRatio: Double = 0.65
    var microMapMinBodyRatio: Double = 0.60
    var microMapMaxCloseFromExtreme: Double = 0.25
    var microMapMinMicroBars: Int = 2
    var microMapMaxMicroBars: Int = 8
    var microMapMaxMicroRangeRatio: Double = 0.70
    var microMapMaxRetracement: Double = 0.60
    var microMapStructureToleranceATR: Double = 0.10
    var microMapMaxReentryBars: Int = 8
    var microMapRiskReward: Double = 2.0
    var microMapNotifyEvents: Bool = true
    var microMapConfluenceBalanceBars: Int = 4
    var microMapConfluenceEMAPeriod: Int = 60
    var microMapMinPressureGapPct: Double = 0.0
    var microMapMaxPressureGapBar: Int = 3
    var microMapRequirePressureGap: Bool = false
    var microMapRequireKeyLevelBreak: Bool = false
    var microMapMinConfluenceScore: Int = 0

    // Major Trend Reversal: confirmed pivots define the prior channel;
    // confirmation is a close through the neckline after the old extreme
    // has been retested.
    var mtrPivotDepth: Int = 3
    var mtrATRPeriod: Int = 14
    var mtrMinTrendLegATR: Double = 1.0
    var mtrBreakBufferATR: Double = 0.10
    var mtrRetestToleranceATR: Double = 0.25
    var mtrMaxFailedBreakATR: Double = 0.75
    var mtrMaxRetestBars: Int = 20
    var mtrMaxConfirmationBars: Int = 20
    var mtrStopBufferATR: Double = 0.10
    var mtrRiskReward: Double = 2.0
    var mtrMaxTradeBars: Int = 50
    var mtrMaxResults: Int = 12

    // Fair Value Gap parameters (LuxAlgo port). `fvgThreshold` is the
    // minimum gap size as a % of the gap floor (0 = no filter, the default).
    // `fvgShowMitigated` keeps absorbed gaps visible at reduced opacity;
    // when false they are removed from the chart once mitigated.
    var fvgThreshold: Double = 0.0
    var fvgShowMitigated: Bool = true

    // Sonarlab Order Blocks parameters (ClayeWeight PineScript v5 port).
    // `sonarlabSensitivity` is the ROC threshold (Pine default 26 → 0.26
    // after /100). `sonarlabMitigationType` is "Close" (default) or "Wick"
    // — how a block is invalidated once price revisits it.
    var sonarlabSensitivity: Double = 26.0
    var sonarlabMitigationType: String = "Close"

    // Change of Character parameters (see `ChangeOfCharacter`).
    // `chochSwingLength` is the ZigZag pivot depth used to read structure;
    // `chochMinSwingPct` filters swing noise. `chochRequireFVG` restricts
    // output to OB∩FVG confluence zones; `chochShowMitigated` keeps zones
    // price has already closed through.
    var chochSwingLength: Int = 5
    var chochMinSwingPct: Double = 0.2
    var chochShowOB: Bool = true
    var chochShowFVG: Bool = true
    var chochShowIFVG: Bool = false
    var chochRequireFVG: Bool = false
    var chochShowMitigated: Bool = false
    var chochNotifyEvents: Bool = false
    // Higher-timeframe CHoCH overlay: draw the last `chochHTFCount` zones
    // from `chochHTFTimeframe` projected onto whatever (lower) timeframe
    // is currently displayed. Reference-only context for LTF entries.
    var chochHTFEnabled: Bool = false
    var chochHTFTimeframe: String = "1h"
    var chochHTFCount: Int = 3

    // Volume Profile parameters (session-based, see `VolumeProfile`).
    // `vpBucketCount` is the number of equal-price bands per session;
    // `vpValueAreaPct` is the % of total volume that defines the value area.
    // ZigZag-based VP: `vpUseZigzag` enables last-trend-only mode,
    // `vpShowZigzag` draws the zigzag lines on the chart,
    // `vpZZDepth` / `vpZZMinChange` tune the zigzag sensitivity.
    var vpBucketCount: Int = 24
    var vpValueAreaPct: Double = 70.0
    var vpUseZigzag: Bool = true
    var vpShowZigzag: Bool = true
    var vpZZDepth: Int = 5
    var vpZZMinChange: Double = 1.0

    // We decode every field with `decodeIfPresent` (see init(from:)) so
    // adding a field no longer requires bumping this key — an older
    // payload that predates the field just falls back to its default
    // instead of failing to decode and wiping the user's whole config.
    private static let storageKey = "dashboard.indicator.config.v2"

    init() {}

    /// Lenient decode: any key missing from an older saved payload falls
    /// back to the property's default rather than throwing. This is what
    /// lets us extend the config (e.g. the Order Block fields) without
    /// resetting the user's existing RSI / MACD / UT Bot tuning. See
    /// CLAUDE.md "Added a Codable field to a persisted struct".
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rsiPeriod          = try c.decodeIfPresent(Int.self,    forKey: .rsiPeriod)          ?? 14
        macdFast           = try c.decodeIfPresent(Int.self,    forKey: .macdFast)           ?? 12
        macdSlow           = try c.decodeIfPresent(Int.self,    forKey: .macdSlow)           ?? 26
        macdSignal         = try c.decodeIfPresent(Int.self,    forKey: .macdSignal)         ?? 9
        stochK             = try c.decodeIfPresent(Int.self,    forKey: .stochK)             ?? 14
        stochD             = try c.decodeIfPresent(Int.self,    forKey: .stochD)             ?? 3
        utKeyValue         = try c.decodeIfPresent(Double.self, forKey: .utKeyValue)         ?? 1.0
        utATRPeriod        = try c.decodeIfPresent(Int.self,    forKey: .utATRPeriod)        ?? 10
        utUseHeikinAshi    = try c.decodeIfPresent(Bool.self,   forKey: .utUseHeikinAshi)    ?? false
        utShowTrailingStop = try c.decodeIfPresent(Bool.self,   forKey: .utShowTrailingStop) ?? true
        obPeriods          = try c.decodeIfPresent(Int.self,    forKey: .obPeriods)          ?? 5
        obThreshold        = try c.decodeIfPresent(Double.self, forKey: .obThreshold)        ?? 0.0
        obUseWicks         = try c.decodeIfPresent(Bool.self,   forKey: .obUseWicks)         ?? false
        obShowExhausted    = try c.decodeIfPresent(Bool.self,   forKey: .obShowExhausted)    ?? true
        obDetectSteroids   = try c.decodeIfPresent(Bool.self,   forKey: .obDetectSteroids)   ?? false
        obNotifyEvents     = try c.decodeIfPresent(Bool.self,   forKey: .obNotifyEvents)     ?? false
        sobPeriods         = try c.decodeIfPresent(Int.self,    forKey: .sobPeriods)         ?? 5
        sobThreshold       = try c.decodeIfPresent(Double.self, forKey: .sobThreshold)       ?? 0.0
        sobUseWicks        = try c.decodeIfPresent(Bool.self,   forKey: .sobUseWicks)        ?? false
        sobVolumeMultiplier = try c.decodeIfPresent(Double.self, forKey: .sobVolumeMultiplier) ?? 1.2
        sobShowExhausted   = try c.decodeIfPresent(Bool.self,   forKey: .sobShowExhausted)   ?? true
        sobDetectSteroids  = try c.decodeIfPresent(Bool.self,   forKey: .sobDetectSteroids)  ?? true
        sobNotifyEvents    = try c.decodeIfPresent(Bool.self,   forKey: .sobNotifyEvents)    ?? false
        sessShowNames      = try c.decodeIfPresent(Bool.self,   forKey: .sessShowNames)      ?? true
        sessShowOpenClose  = try c.decodeIfPresent(Bool.self,   forKey: .sessShowOpenClose)  ?? true
        sessShowRange      = try c.decodeIfPresent(Bool.self,   forKey: .sessShowRange)      ?? true
        sessShowAverage    = try c.decodeIfPresent(Bool.self,   forKey: .sessShowAverage)    ?? true
        sessShowTokyo      = try c.decodeIfPresent(Bool.self,   forKey: .sessShowTokyo)      ?? true
        sessShowLondon     = try c.decodeIfPresent(Bool.self,   forKey: .sessShowLondon)     ?? true
        sessShowNewYork    = try c.decodeIfPresent(Bool.self,   forKey: .sessShowNewYork)    ?? true
        nyAtrMult          = try c.decodeIfPresent(Double.self, forKey: .nyAtrMult)          ?? 1.0
        nyAMOnly           = try c.decodeIfPresent(Bool.self,   forKey: .nyAMOnly)           ?? true
        sp2lMinSpikeBars   = try c.decodeIfPresent(Int.self,    forKey: .sp2lMinSpikeBars)   ?? 2
        sp2lMaxSpikeBars   = try c.decodeIfPresent(Int.self,    forKey: .sp2lMaxSpikeBars)   ?? 4
        sp2lRangeBars      = try c.decodeIfPresent(Int.self,    forKey: .sp2lRangeBars)      ?? 4
        sp2lATRPeriod      = try c.decodeIfPresent(Int.self,    forKey: .sp2lATRPeriod)      ?? 14
        sp2lMinSpikeATR    = try c.decodeIfPresent(Double.self, forKey: .sp2lMinSpikeATR)    ?? 1.0
        sp2lMaxSpikeATR    = try c.decodeIfPresent(Double.self, forKey: .sp2lMaxSpikeATR)    ?? 3.0
        sp2lMaxRangeATR    = try c.decodeIfPresent(Double.self, forKey: .sp2lMaxRangeATR)    ?? 1.5
        sp2lMinGapPct      = try c.decodeIfPresent(Double.self, forKey: .sp2lMinGapPct)      ?? 0.0
        sp2lMaxPressureGapBar = try c.decodeIfPresent(Int.self, forKey: .sp2lMaxPressureGapBar) ?? 3
        sp2lEMAPeriod      = try c.decodeIfPresent(Int.self,    forKey: .sp2lEMAPeriod)      ?? 60
        sp2lUseEMAContext  = try c.decodeIfPresent(Bool.self,   forKey: .sp2lUseEMAContext)  ?? true
        sp2lMaxEMADistanceATR = try c.decodeIfPresent(Double.self, forKey: .sp2lMaxEMADistanceATR) ?? 1.0
        sp2lMaxPullbackBars = try c.decodeIfPresent(Int.self,   forKey: .sp2lMaxPullbackBars) ?? 6
        sp2lMaxContinuationBars = try c.decodeIfPresent(Int.self, forKey: .sp2lMaxContinuationBars) ?? 10
        sp2lRiskReward     = try c.decodeIfPresent(Double.self, forKey: .sp2lRiskReward)     ?? 1.0
        sp2lTargetCount    = try c.decodeIfPresent(Int.self, forKey: .sp2lTargetCount)       ?? 1
        pinBarEnableSP2L   = try c.decodeIfPresent(Bool.self,   forKey: .pinBarEnableSP2L)   ?? true
        pinBarEnableBTB    = try c.decodeIfPresent(Bool.self,   forKey: .pinBarEnableBTB)    ?? true
        pinBarATRPeriod    = try c.decodeIfPresent(Int.self,    forKey: .pinBarATRPeriod)    ?? 14
        pinBarMinWickBodyRatio = try c.decodeIfPresent(Double.self, forKey: .pinBarMinWickBodyRatio) ?? 2.0
        pinBarMinWickRangeRatio = try c.decodeIfPresent(Double.self, forKey: .pinBarMinWickRangeRatio) ?? 0.55
        pinBarMaxBodyRangeRatio = try c.decodeIfPresent(Double.self, forKey: .pinBarMaxBodyRangeRatio) ?? 0.35
        pinBarMinCloseLocation = try c.decodeIfPresent(Double.self, forKey: .pinBarMinCloseLocation) ?? 0.65
        pinBarOppositeWickDominance = try c.decodeIfPresent(Double.self, forKey: .pinBarOppositeWickDominance) ?? 1.5
        pinBarTouchToleranceATR = try c.decodeIfPresent(Double.self, forKey: .pinBarTouchToleranceATR) ?? 0.10
        pinBarStopBufferATR = try c.decodeIfPresent(Double.self, forKey: .pinBarStopBufferATR) ?? 0.05
        pinBarMaxConfirmationBars = try c.decodeIfPresent(Int.self, forKey: .pinBarMaxConfirmationBars) ?? 8
        pinBarBTBLookbackBars = try c.decodeIfPresent(Int.self, forKey: .pinBarBTBLookbackBars) ?? 12
        pinBarMinBreakoutBodyATR = try c.decodeIfPresent(Double.self, forKey: .pinBarMinBreakoutBodyATR) ?? 0.50
        pinBarRiskReward = try c.decodeIfPresent(Double.self, forKey: .pinBarRiskReward) ?? 2.0
        pinBarMaxContinuationBars = try c.decodeIfPresent(Int.self, forKey: .pinBarMaxContinuationBars) ?? 20
        microMapATRPeriod  = try c.decodeIfPresent(Int.self,    forKey: .microMapATRPeriod)  ?? 14
        microMapMinSpikeBars = try c.decodeIfPresent(Int.self,  forKey: .microMapMinSpikeBars) ?? 2
        microMapMaxSpikeBars = try c.decodeIfPresent(Int.self,  forKey: .microMapMaxSpikeBars) ?? 6
        microMapMinSpikeATR = try c.decodeIfPresent(Double.self, forKey: .microMapMinSpikeATR) ?? 1.5
        microMapMinDirectionalRatio = try c.decodeIfPresent(Double.self, forKey: .microMapMinDirectionalRatio) ?? 0.65
        microMapMinBodyRatio = try c.decodeIfPresent(Double.self, forKey: .microMapMinBodyRatio) ?? 0.60
        microMapMaxCloseFromExtreme = try c.decodeIfPresent(Double.self, forKey: .microMapMaxCloseFromExtreme) ?? 0.25
        microMapMinMicroBars = try c.decodeIfPresent(Int.self, forKey: .microMapMinMicroBars) ?? 2
        microMapMaxMicroBars = try c.decodeIfPresent(Int.self, forKey: .microMapMaxMicroBars) ?? 8
        microMapMaxMicroRangeRatio = try c.decodeIfPresent(Double.self, forKey: .microMapMaxMicroRangeRatio) ?? 0.70
        microMapMaxRetracement = try c.decodeIfPresent(Double.self, forKey: .microMapMaxRetracement) ?? 0.60
        microMapStructureToleranceATR = try c.decodeIfPresent(Double.self, forKey: .microMapStructureToleranceATR) ?? 0.10
        microMapMaxReentryBars = try c.decodeIfPresent(Int.self, forKey: .microMapMaxReentryBars) ?? 8
        microMapRiskReward = try c.decodeIfPresent(Double.self, forKey: .microMapRiskReward) ?? 2.0
        microMapNotifyEvents = try c.decodeIfPresent(Bool.self, forKey: .microMapNotifyEvents) ?? true
        microMapConfluenceBalanceBars = try c.decodeIfPresent(Int.self, forKey: .microMapConfluenceBalanceBars) ?? 4
        microMapConfluenceEMAPeriod = try c.decodeIfPresent(Int.self, forKey: .microMapConfluenceEMAPeriod) ?? 60
        microMapMinPressureGapPct = try c.decodeIfPresent(Double.self, forKey: .microMapMinPressureGapPct) ?? 0.0
        microMapMaxPressureGapBar = try c.decodeIfPresent(Int.self, forKey: .microMapMaxPressureGapBar) ?? 3
        microMapRequirePressureGap = try c.decodeIfPresent(Bool.self, forKey: .microMapRequirePressureGap) ?? false
        microMapRequireKeyLevelBreak = try c.decodeIfPresent(Bool.self, forKey: .microMapRequireKeyLevelBreak) ?? false
        microMapMinConfluenceScore = try c.decodeIfPresent(Int.self, forKey: .microMapMinConfluenceScore) ?? 0
        mtrPivotDepth       = try c.decodeIfPresent(Int.self, forKey: .mtrPivotDepth) ?? 3
        mtrATRPeriod        = try c.decodeIfPresent(Int.self, forKey: .mtrATRPeriod) ?? 14
        mtrMinTrendLegATR   = try c.decodeIfPresent(Double.self, forKey: .mtrMinTrendLegATR) ?? 1.0
        mtrBreakBufferATR   = try c.decodeIfPresent(Double.self, forKey: .mtrBreakBufferATR) ?? 0.10
        mtrRetestToleranceATR = try c.decodeIfPresent(Double.self, forKey: .mtrRetestToleranceATR) ?? 0.25
        mtrMaxFailedBreakATR = try c.decodeIfPresent(Double.self, forKey: .mtrMaxFailedBreakATR) ?? 0.75
        mtrMaxRetestBars    = try c.decodeIfPresent(Int.self, forKey: .mtrMaxRetestBars) ?? 20
        mtrMaxConfirmationBars = try c.decodeIfPresent(Int.self, forKey: .mtrMaxConfirmationBars) ?? 20
        mtrStopBufferATR    = try c.decodeIfPresent(Double.self, forKey: .mtrStopBufferATR) ?? 0.10
        mtrRiskReward       = try c.decodeIfPresent(Double.self, forKey: .mtrRiskReward) ?? 2.0
        mtrMaxTradeBars     = try c.decodeIfPresent(Int.self, forKey: .mtrMaxTradeBars) ?? 50
        mtrMaxResults       = try c.decodeIfPresent(Int.self, forKey: .mtrMaxResults) ?? 12
        fvgThreshold       = try c.decodeIfPresent(Double.self, forKey: .fvgThreshold)       ?? 0.0
        fvgShowMitigated   = try c.decodeIfPresent(Bool.self,   forKey: .fvgShowMitigated)   ?? true
        sonarlabSensitivity = try c.decodeIfPresent(Double.self, forKey: .sonarlabSensitivity) ?? 26.0
        sonarlabMitigationType = try c.decodeIfPresent(String.self, forKey: .sonarlabMitigationType) ?? "Close"
        chochSwingLength   = try c.decodeIfPresent(Int.self,    forKey: .chochSwingLength)   ?? 5
        chochMinSwingPct   = try c.decodeIfPresent(Double.self, forKey: .chochMinSwingPct)   ?? 0.2
        chochShowOB        = try c.decodeIfPresent(Bool.self,   forKey: .chochShowOB)        ?? true
        chochShowFVG       = try c.decodeIfPresent(Bool.self,   forKey: .chochShowFVG)       ?? true
        chochShowIFVG      = try c.decodeIfPresent(Bool.self,   forKey: .chochShowIFVG)      ?? false
        chochRequireFVG    = try c.decodeIfPresent(Bool.self,   forKey: .chochRequireFVG)    ?? false
        chochShowMitigated = try c.decodeIfPresent(Bool.self,   forKey: .chochShowMitigated) ?? false
        chochNotifyEvents  = try c.decodeIfPresent(Bool.self,   forKey: .chochNotifyEvents)  ?? false
        chochHTFEnabled    = try c.decodeIfPresent(Bool.self,   forKey: .chochHTFEnabled)    ?? false
        chochHTFTimeframe  = try c.decodeIfPresent(String.self, forKey: .chochHTFTimeframe)  ?? "1h"
        chochHTFCount      = try c.decodeIfPresent(Int.self,    forKey: .chochHTFCount)      ?? 3
        vpBucketCount      = try c.decodeIfPresent(Int.self,    forKey: .vpBucketCount)      ?? 24
        vpValueAreaPct     = try c.decodeIfPresent(Double.self, forKey: .vpValueAreaPct)     ?? 70.0
        vpUseZigzag        = try c.decodeIfPresent(Bool.self,   forKey: .vpUseZigzag)        ?? true
        vpShowZigzag       = try c.decodeIfPresent(Bool.self,   forKey: .vpShowZigzag)       ?? true
        vpZZDepth          = try c.decodeIfPresent(Int.self,    forKey: .vpZZDepth)          ?? 5
        vpZZMinChange      = try c.decodeIfPresent(Double.self, forKey: .vpZZMinChange)      ?? 1.0
    }

    /// Whether the given `TradingSessions` preset id is toggled on. Used
    /// by ChartView to filter the (data-keyed, always-all-sessions)
    /// memoized run list down to what the user wants drawn.
    func showsSession(_ id: String) -> Bool {
        switch id {
        case "tokyo":   return sessShowTokyo
        case "london":  return sessShowLondon
        case "newYork": return sessShowNewYork
        default:        return true
        }
    }

    static func load() -> OscillatorConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let cfg = try? JSONDecoder().decode(OscillatorConfig.self, from: data)
        else { return OscillatorConfig() }
        return cfg
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    var pinBarComboConfiguration: PinBarComboSetup.Configuration {
        var config = PinBarComboSetup.Configuration()
        config.enableSP2L = pinBarEnableSP2L
        config.enableBTB = pinBarEnableBTB
        config.atrPeriod = pinBarATRPeriod
        config.minWickBodyRatio = pinBarMinWickBodyRatio
        config.minWickRangeRatio = pinBarMinWickRangeRatio
        config.maxBodyRangeRatio = pinBarMaxBodyRangeRatio
        config.minCloseLocation = pinBarMinCloseLocation
        config.oppositeWickDominance = pinBarOppositeWickDominance
        config.touchToleranceATR = pinBarTouchToleranceATR
        config.stopBufferATR = pinBarStopBufferATR
        config.maxConfirmationBars = pinBarMaxConfirmationBars
        config.btbLookbackBars = pinBarBTBLookbackBars
        config.minBreakoutBodyATR = pinBarMinBreakoutBodyATR
        config.riskReward = pinBarRiskReward
        config.maxContinuationBars = pinBarMaxContinuationBars
        return config
    }

    var microMapConfiguration: MicroMapSetup.Configuration {
        var config = MicroMapSetup.Configuration()
        config.atrPeriod = microMapATRPeriod
        config.minSpikeBars = microMapMinSpikeBars
        config.maxSpikeBars = microMapMaxSpikeBars
        config.minSpikeATR = microMapMinSpikeATR
        config.minDirectionalRatio = microMapMinDirectionalRatio
        config.minBodyRatio = microMapMinBodyRatio
        config.maxCloseFromExtreme = microMapMaxCloseFromExtreme
        config.minMicroBars = microMapMinMicroBars
        config.maxMicroBars = microMapMaxMicroBars
        config.maxMicroRangeRatio = microMapMaxMicroRangeRatio
        config.maxRetracement = microMapMaxRetracement
        config.structureToleranceATR = microMapStructureToleranceATR
        config.maxReentryBars = microMapMaxReentryBars
        config.riskReward = microMapRiskReward
        config.confluenceBalanceBars = microMapConfluenceBalanceBars
        config.confluenceEMAPeriod = microMapConfluenceEMAPeriod
        config.minPressureGapPct = microMapMinPressureGapPct
        config.maxPressureGapBar = microMapMaxPressureGapBar
        config.requirePressureGap = microMapRequirePressureGap
        config.requireKeyLevelBreak = microMapRequireKeyLevelBreak
        config.minConfluenceScore = microMapMinConfluenceScore
        return config
    }

    var mtrConfiguration: MTRSetup.Configuration {
        var config = MTRSetup.Configuration()
        config.pivotDepth = mtrPivotDepth
        config.atrPeriod = mtrATRPeriod
        config.minTrendLegATR = mtrMinTrendLegATR
        config.breakBufferATR = mtrBreakBufferATR
        config.retestToleranceATR = mtrRetestToleranceATR
        config.maxFailedBreakATR = mtrMaxFailedBreakATR
        config.maxRetestBars = mtrMaxRetestBars
        config.maxConfirmationBars = mtrMaxConfirmationBars
        config.stopBufferATR = mtrStopBufferATR
        config.riskReward = mtrRiskReward
        config.maxTradeBars = mtrMaxTradeBars
        config.maxResults = mtrMaxResults
        return config
    }
}

/// Pure-function oscillator computations. Each returns
/// `[IndicatorPoint]` keyed by candle index + band, matching the rest of
/// the chart's plotting conventions.
enum Oscillators {
    // MARK: - RSI (Wilder smoothing)
    //
    // Standard 14-period RSI using Wilder's exponential smoothing (the
    // canonical definition — not the SMA variant some libraries use).
    // First value lands at index = period; everything before is nil.
    static func rsi(_ candles: [Candle], period: Int) -> [IndicatorPoint] {
        guard period > 0, candles.count > period else { return [] }
        // Step 1: per-bar gain/loss against prior close.
        var gains:  [Double] = [0]
        var losses: [Double] = [0]
        for i in 1..<candles.count {
            let diff = candles[i].close - candles[i - 1].close
            gains.append(max(0,  diff))
            losses.append(max(0, -diff))
        }
        // Step 2: seed averages = simple mean over the first `period` bars.
        var avgGain = gains[1...period].reduce(0, +) / Double(period)
        var avgLoss = losses[1...period].reduce(0, +) / Double(period)

        var out: [IndicatorPoint] = []
        out.reserveCapacity(candles.count - period)
        out.append(IndicatorPoint(index: period, value: rsiFrom(avgGain, avgLoss), band: "rsi"))

        // Step 3: Wilder's smoothing for the rest of the series.
        // new_avg = (old_avg * (period - 1) + new_value) / period
        let p = Double(period)
        for i in (period + 1)..<candles.count {
            avgGain = (avgGain * (p - 1) + gains[i])  / p
            avgLoss = (avgLoss * (p - 1) + losses[i]) / p
            out.append(IndicatorPoint(index: i, value: rsiFrom(avgGain, avgLoss), band: "rsi"))
        }
        return out
    }

    /// RSI = 100 - 100/(1 + RS); guard zero loss (means RSI=100 by
    /// convention) so the divide doesn't NaN.
    private static func rsiFrom(_ gain: Double, _ loss: Double) -> Double {
        guard loss > 0 else { return 100 }
        let rs = gain / loss
        return 100 - 100 / (1 + rs)
    }

    // MARK: - MACD
    //
    // MACD line  = EMA(close, fast) - EMA(close, slow)
    // Signal     = EMA(MACD line, signal)
    // Histogram  = MACD line - signal
    // All three series get emitted; OscillatorPanel renders the line+signal
    // as curves and the histogram as a small bar series.
    static func macd(_ candles: [Candle], fast: Int, slow: Int, signal: Int) -> [IndicatorPoint] {
        guard fast > 0, slow > fast, signal > 0, candles.count >= slow else { return [] }
        let closes = candles.map(\.close)
        let emaFast = emaSeries(closes, period: fast)
        let emaSlow = emaSeries(closes, period: slow)

        // MACD line is defined wherever both EMAs are defined.
        var macdLine: [Double?] = Array(repeating: nil, count: candles.count)
        for i in 0..<candles.count {
            if let f = emaFast[i], let s = emaSlow[i] { macdLine[i] = f - s }
        }

        // Signal = EMA of the (defined) MACD-line tail.
        let firstMACD = macdLine.firstIndex { $0 != nil } ?? candles.count
        let macdTail = macdLine[firstMACD..<candles.count].compactMap { $0 }
        let signalRel = emaSeries(macdTail, period: signal)

        var out: [IndicatorPoint] = []
        for i in 0..<candles.count {
            if let m = macdLine[i] {
                out.append(IndicatorPoint(index: i, value: m, band: "macd"))
            }
            let rel = i - firstMACD
            if rel >= 0, rel < signalRel.count, let s = signalRel[rel] {
                out.append(IndicatorPoint(index: i, value: s, band: "signal"))
                if let m = macdLine[i] {
                    out.append(IndicatorPoint(index: i, value: m - s, band: "histogram"))
                }
            }
        }
        return out
    }

    // MARK: - Stochastic Oscillator
    //
    // %K = 100 * (close - low_N)  / (high_N - low_N)   over `kPeriod`
    // %D = SMA(%K, dPeriod)
    //
    // Uses a deque-based sliding window for O(1) amortised min/max per
    // bar — replaces the prior O(kPeriod) per-bar scan.
    static func stochastic(_ candles: [Candle], kPeriod: Int, dPeriod: Int) -> [IndicatorPoint] {
        guard kPeriod > 0, dPeriod > 0, candles.count >= kPeriod else { return [] }

        var kVals: [Double?] = Array(repeating: nil, count: candles.count)
        // Deques store indices; front is always the current min/max.
        // Low deque: increasing values (front = min).
        // High deque: decreasing values (front = max).
        var lowDeque: [Int] = []
        var highDeque: [Int] = []

        for i in 0..<candles.count {
            // Remove elements that fall outside the window (left side).
            let windowStart = i - kPeriod + 1
            if let first = lowDeque.first, first < windowStart {
                lowDeque.removeFirst()
            }
            if let first = highDeque.first, first < windowStart {
                highDeque.removeFirst()
            }
            // Add current bar: remove from back while worse than new element.
            let lo = candles[i].low
            let hi = candles[i].high
            while let last = lowDeque.last, candles[last].low >= lo {
                lowDeque.removeLast()
            }
            lowDeque.append(i)
            while let last = highDeque.last, candles[last].high <= hi {
                highDeque.removeLast()
            }
            highDeque.append(i)
            // Compute %K once the window is full.
            if i >= kPeriod - 1 {
                let windowLow  = candles[lowDeque[0]].low
                let windowHigh = candles[highDeque[0]].high
                let span = windowHigh - windowLow
                kVals[i] = span > 0 ? (candles[i].close - windowLow) / span * 100 : 50
            }
        }

        var dVals: [Double?] = Array(repeating: nil, count: candles.count)
        let firstK = kPeriod - 1
        if candles.count >= firstK + dPeriod {
            for i in (firstK + dPeriod - 1)..<candles.count {
                var sum = 0.0
                for j in (i - dPeriod + 1)...i {
                    sum += kVals[j] ?? 0
                }
                dVals[i] = sum / Double(dPeriod)
            }
        }

        var out: [IndicatorPoint] = []
        for i in 0..<candles.count {
            if let k = kVals[i] { out.append(IndicatorPoint(index: i, value: k, band: "k")) }
            if let d = dVals[i] { out.append(IndicatorPoint(index: i, value: d, band: "d")) }
        }
        return out
    }

    // MARK: - Internal helpers

    /// EMA over a flat `[Double]` series, returning a [Double?] aligned
    /// to input indices (nil before the seed window). Used by MACD which
    /// needs to EMA a non-Candle series (the MACD line itself).
    private static func emaSeries(_ values: [Double], period: Int) -> [Double?] {
        guard period > 0, values.count >= period else {
            return Array(repeating: nil, count: values.count)
        }
        var out: [Double?] = Array(repeating: nil, count: values.count)
        let alpha = 2.0 / (Double(period) + 1.0)
        var prev = values[0..<period].reduce(0, +) / Double(period)
        out[period - 1] = prev
        for i in period..<values.count {
            prev = alpha * values[i] + (1 - alpha) * prev
            out[i] = prev
        }
        return out
    }
}
