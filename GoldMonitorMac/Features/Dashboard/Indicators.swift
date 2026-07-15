import Foundation
import SwiftUI

/// A single parameter value — numeric, boolean, or string — stored in an
/// indicator/oscillator instance's params dictionary.
enum ParamValue: Codable, Equatable, Hashable {
    case double(Double)
    case bool(Bool)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        throw DecodingError.typeMismatch(ParamValue.self, .init(
            codingPath: c.codingPath,
            debugDescription: "Expected Double, Bool, or String"
        ))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .double(let v): try c.encode(v)
        case .bool(let v):   try c.encode(v)
        case .string(let v): try c.encode(v)
        }
    }

    var doubleValue: Double {
        switch self {
        case .double(let v): return v
        case .bool(let v):   return v ? 1 : 0
        case .string:        return 0
        }
    }

    var boolValue: Bool {
        switch self {
        case .bool(let v):   return v
        case .double(let v): return v >= 0.5
        case .string:        return false
        }
    }

    var stringValue: String {
        switch self {
        case .string(let v): return v
        case .double(let v): return String(format: "%.1f", v)
        case .bool(let v):   return v ? "true" : "false"
        }
    }
}

/// Describes one tunable parameter for an indicator/oscillator kind.
struct ParamOption: Equatable {
    let label: String
    let value: String
}

enum ParamSpec: Equatable {
    case double(key: String, label: String, default: Double, step: Double, range: ClosedRange<Double>)
    case bool(key: String, label: String, default: Bool)
    case `enum`(key: String, label: String, default: String, options: [ParamOption])
}

/// Catalog of technical indicators the user can overlay on the price
/// chart. Each kind is self-describing (label, colour, computation) so
/// ChartView can iterate without a giant switch. New indicators get
/// added here and automatically show up in the menu.
enum IndicatorKind: String, CaseIterable, Identifiable, Hashable, Codable {
    case sma20
    case sma50
    case sma200
    case ema9
    case ema21
    case bollinger
    /// UT Bot Alerts — ATR-based trailing stop with buy/sell labels.
    /// Special-cased in the chart: the trailing stop renders as a
    /// stepped line and signals render as labels at the relevant bars.
    case utBot
    /// Order Block Finder — institutional order-block zones. Like UT Bot
    /// it doesn't fit the single-line `IndicatorPoint` shape: it renders
    /// as translucent rectangles (see `OrderBlocks` + ChartView's
    /// `orderBlockMarks`) and reads its run length / threshold / wick
    /// options from the indicator config.
    case orderBlock
    /// Steroid Order Blocks — institutional order blocks validated by Volume Profile.
    case steroidOrderBlock
    /// Trading Sessions — shades the Tokyo / London / New York sessions as
    /// per-day high-low boxes with open/close/average lines. Like the two
    /// above it renders as zones, not a line series (see `TradingSessions`
    /// + ChartView's `sessionMarks`); which sessions show and which lines
    /// draw come from the indicator config.
    case tradingSession
    /// NY Open Setup — the 5-minute opening-range breakout + FVG-retest
    /// strategy (see `NYOpenSetup` + ChartView's `setupMarks`). Renders
    /// the opening-range box, the breakout FVG, and the entry/SL/TP plan;
    /// on 1m and 5m charts. The dashboard also turns the live day's plan
    /// into alerts + an activate-trade affordance.
    case nyOpenSetup
    /// SP2L Strategy — Spike-2Leg continuation setup. Detects balance,
    /// a breakout + follow-through pressure gap, then rests a limit order
    /// at the first pullback level. Renders entry/SL/TP/add-on.
    case sp2lStrategy
    /// Pin Bar Combo — confirmation overlay for SP2L pullbacks and BTB
    /// broken-level retests. Enters only after a directional rejection
    /// candle and draws the tested level plus entry/SL/TP plan.
    case pinBarCombo
    /// MicroMap continuation strategy — strong spike, weak counter-trend
    /// micro-channel, then up to three close-confirmed entry attempts.
    case microMapStrategy
    /// Major Trend Reversal — confirmed trend channel break, retest of the
    /// old extreme, then a close-confirmed break of the intervening swing.
    case mtrStrategy
    /// Fair Value Gap (FVG) detector — three-candle imbalance zones.
    /// Renders as translucent green/red rectangles extending rightward
    /// from the bar where the gap formed. Mitigated gaps (price closed
    /// back inside) are kept at lower opacity with a dashed outline.
    /// Ported from LuxAlgo's PineScript v5 FVG indicator (CC BY-NC-SA 4.0).
    case fairValueGap
    /// Sonarlab Order Blocks — momentum-based OB detection using a
    /// custom ROC (Rate of Change) of opens over 4 bars. When ROC
    /// crosses above/below a sensitivity threshold the last
    /// counter-trend candle within bars 4–15 is marked as an order
    /// block. Ported from ClayeWeight's PineScript v5 "Sonarlab -
    /// Order Blocks" (MPL 2.0).
    case sonarlabOrderBlock
    /// Change of Character (CHoCH) — Smart-Money structure-break detector.
    /// Reads market structure from swing pivots (via `ZigZag`); when a
    /// close breaks the last protected swing *against* the prevailing
    /// trend, it marks the reversal and draws the order-block / fair-value-
    /// gap confluence zone left behind by the breaking impulse. Renders as
    /// zones + a "CHoCH↑/↓" label + a dashed broken-structure line (see
    /// `ChangeOfCharacter` + ChartView's `chochMarks`).
    case changeOfCharacter
    /// Session-based Volume Profile — per-day volume histogram with POC, VAH, VAL.
    case volumeProfile

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sma20:          return "SMA 20"
        case .sma50:          return "SMA 50"
        case .sma200:         return "SMA 200"
        case .ema9:           return "EMA 9"
        case .ema21:          return "EMA 21"
        case .bollinger:      return "Bollinger"
        case .utBot:          return "UT Bot Alerts"
        case .orderBlock:     return "Order Blocks"
        case .steroidOrderBlock: return "Steroid OB"
        case .tradingSession: return "Trading Sessions"
        case .nyOpenSetup:    return "NY Open Setup"
        case .sp2lStrategy:   return "SP2L Strategy"
        case .pinBarCombo:    return "Pin Bar · SP2L + BTB"
        case .microMapStrategy: return "MicroMap Strategy"
        case .mtrStrategy:    return "MTR · Major Trend Reversal"
        case .fairValueGap:   return "Fair Value Gap"
        case .sonarlabOrderBlock: return "Sonarlab OB"
        case .changeOfCharacter: return "CHoCH Zones"
        case .volumeProfile:     return "Volume Profile"
        }
    }

    var color: Color {
        switch self {
        case .sma20:     return Color(red: 1.00, green: 0.78, blue: 0.20)
        case .sma50:     return Color(red: 0.38, green: 0.65, blue: 1.00)
        case .sma200:    return Color(red: 0.85, green: 0.35, blue: 0.95)
        case .ema9:      return Color(red: 1.00, green: 0.45, blue: 0.65)
        case .ema21:     return Color(red: 0.45, green: 0.85, blue: 0.95)
        case .bollinger: return Color(red: 0.55, green: 0.85, blue: 1.00)
        case .utBot:     return Color(red: 0.95, green: 0.62, blue: 0.18)
        case .orderBlock: return Color(red: 0.55, green: 0.50, blue: 0.95)
        case .steroidOrderBlock: return Color(red: 1.00, green: 0.40, blue: 0.20)
        case .tradingSession: return Color(red: 0.40, green: 0.55, blue: 0.70)
        case .nyOpenSetup: return Color(red: 0.95, green: 0.75, blue: 0.30)
        case .sp2lStrategy: return Color(red: 0.25, green: 0.72, blue: 1.00)
        case .pinBarCombo:  return Color(red: 1.00, green: 0.54, blue: 0.28)
        case .microMapStrategy: return Color(red: 0.20, green: 0.82, blue: 0.58)
        case .mtrStrategy: return Color(red: 0.66, green: 0.48, blue: 1.00)
        case .fairValueGap: return Color(red: 0.30, green: 0.80, blue: 0.75)
        case .sonarlabOrderBlock: return Color(red: 0.80, green: 0.45, blue: 0.90)
        case .changeOfCharacter: return Color(red: 0.95, green: 0.35, blue: 0.72)
        case .volumeProfile:     return Color(red: 0.20, green: 0.80, blue: 0.75)
        }
    }

    /// Keys (and defaults) for every tunable parameter this kind accepts.
    var paramSpecs: [ParamSpec] {
        switch self {
        case .sma20:  return [.double(key: "period", label: "Period", default: 20, step: 1, range: 2...200)]
        case .sma50:  return [.double(key: "period", label: "Period", default: 50, step: 1, range: 2...200)]
        case .sma200: return [.double(key: "period", label: "Period", default: 200, step: 1, range: 2...200)]
        case .ema9:   return [.double(key: "period", label: "Period", default: 9, step: 1, range: 2...200)]
        case .ema21:  return [.double(key: "period", label: "Period", default: 21, step: 1, range: 2...200)]
        case .bollinger:
            return [
                .double(key: "period", label: "Period", default: 20, step: 1, range: 2...200),
                .double(key: "stdDev", label: "Std Dev", default: 2.0, step: 0.1, range: 0.5...5.0),
            ]
        case .utBot:
            return [
                .double(key: "keyValue", label: "Key Value", default: 1.0, step: 0.1, range: 0.1...10.0),
                .double(key: "atrPeriod", label: "ATR Period", default: 10, step: 1, range: 1...100),
                .bool(key: "showTrailingStop", label: "Show ATR trailing-stop line", default: true),
                .bool(key: "useHeikinAshi", label: "Use Heikin Ashi for signals", default: false),
            ]
        case .orderBlock:
            return [
                .double(key: "periods", label: "Run Length (periods)", default: 5, step: 1, range: 1...20),
                .double(key: "threshold", label: "Min % Move", default: 0.0, step: 0.1, range: 0...10),
                .bool(key: "useWicks", label: "Use whole high/low range", default: false),
                .bool(key: "showExhausted", label: "Show exhausted blocks", default: true),
                .bool(key: "detectSteroids", label: "Filter by volume (Steroids)", default: false),
            ]
        case .steroidOrderBlock:
            return [
                .double(key: "periods", label: "Run Length (periods)", default: 5, step: 1, range: 1...20),
                .double(key: "threshold", label: "Min % Move", default: 0.0, step: 0.1, range: 0...10),
                .double(key: "volumeMult", label: "Volume Multiplier", default: 1.2, step: 0.1, range: 0.5...3.0),
                .bool(key: "useWicks", label: "Use whole high/low range", default: false),
                .bool(key: "showExhausted", label: "Show exhausted blocks", default: true),
                .bool(key: "detectSteroids", label: "Filter by volume (Steroids)", default: true),
            ]
        case .tradingSession:
            return [
                .bool(key: "showTokyo", label: "Tokyo · 09:00–15:00 JST", default: true),
                .bool(key: "showLondon", label: "London · 08:30–16:30 UK", default: true),
                .bool(key: "showNewYork", label: "New York · 09:30–16:00 ET", default: true),
                .bool(key: "showNames", label: "Show session names", default: true),
                .bool(key: "showOpenClose", label: "Draw open & close lines", default: true),
                .bool(key: "showRange", label: "Show session range", default: true),
                .bool(key: "showAverage", label: "Show average price line", default: true),
            ]
        case .nyOpenSetup:
            return [
                .double(key: "atrMult", label: "Breakout strength (× ATR)", default: 1.0, step: 0.1, range: 0...5),
                .bool(key: "amOnly", label: "AM kill-zone only (09:35–11:00 ET)", default: true),
            ]
        case .sp2lStrategy:
            return [
                .double(key: "minSpikeBars", label: "Min spike candles", default: 2, step: 1, range: 2...8),
                .double(key: "maxSpikeBars", label: "Max spike candles", default: 4, step: 1, range: 2...10),
                .double(key: "rangeBars", label: "Balance candles", default: 4, step: 1, range: 2...12),
                .double(key: "targetCount", label: "Take-profit targets", default: 1, step: 1, range: 1...3),
                .double(key: "atrPeriod", label: "ATR period", default: 14, step: 1, range: 2...100),
                .double(key: "minSpikeATR", label: "Min spike width (× ATR)", default: 1.0, step: 0.1, range: 0.1...5),
                .double(key: "maxSpikeATR", label: "Max spike width (× ATR)", default: 3.0, step: 0.25, range: 0.5...10),
                .double(key: "maxRangeATR", label: "Max balance width (× ATR)", default: 1.5, step: 0.1, range: 0.25...5),
                .double(key: "minGapPct", label: "Min gap %", default: 0.0, step: 0.1, range: 0...5),
                .double(key: "maxPressureGapBar", label: "Latest P-Gap candle", default: 3, step: 1, range: 3...6),
                .double(key: "emaPeriod", label: "Equilibrium EMA", default: 60, step: 1, range: 10...200),
                .bool(key: "useEMAContext", label: "Require EMA equilibrium context", default: true),
                .double(key: "maxEMADistanceATR", label: "Max start distance from EMA (× ATR)", default: 1.0, step: 0.1, range: 0...5),
                .double(key: "maxPullbackBars", label: "Limit order expiry (bars)", default: 6, step: 1, range: 1...30),
                .double(key: "maxContinuationBars", label: "Continuation timeout (bars)", default: 10, step: 1, range: 1...50),
                .double(key: "riskReward", label: "Risk reward", default: 1.0, step: 0.25, range: 0.25...5),
            ]
        case .pinBarCombo:
            return [
                .bool(key: "enableSP2L", label: "Confirm SP2L pullbacks", default: true),
                .bool(key: "enableBTB", label: "Detect BTB retests", default: true),
                .double(key: "atrPeriod", label: "ATR period", default: 14, step: 1, range: 2...100),
                .double(key: "minWickBodyRatio", label: "Min rejection wick / body", default: 2.0, step: 0.25, range: 1...8),
                .double(key: "minWickRangeRatio", label: "Min rejection wick / range", default: 0.55, step: 0.05, range: 0.3...0.9),
                .double(key: "maxBodyRangeRatio", label: "Max body / range", default: 0.35, step: 0.05, range: 0.05...0.6),
                .double(key: "minCloseLocation", label: "Min close near rejection side", default: 0.65, step: 0.05, range: 0.5...0.95),
                .double(key: "oppositeWickDominance", label: "Rejection / opposite wick", default: 1.5, step: 0.25, range: 1...6),
                .double(key: "touchToleranceATR", label: "Level touch tolerance (x ATR)", default: 0.10, step: 0.05, range: 0...1),
                .double(key: "stopBufferATR", label: "Stop buffer (x ATR)", default: 0.05, step: 0.05, range: 0...1),
                .double(key: "maxConfirmationBars", label: "Retest expiry (bars)", default: 8, step: 1, range: 1...30),
                .double(key: "btbLookbackBars", label: "BTB level lookback", default: 12, step: 1, range: 3...50),
                .double(key: "minBreakoutBodyATR", label: "Min BTB breakout body (x ATR)", default: 0.5, step: 0.1, range: 0...3),
                .double(key: "riskReward", label: "Risk reward", default: 2.0, step: 0.25, range: 0.25...10),
                .double(key: "maxContinuationBars", label: "Trade timeout (bars)", default: 20, step: 1, range: 1...100),
            ]
        case .microMapStrategy:
            return [
                .double(key: "atrPeriod", label: "ATR period", default: 14, step: 1, range: 2...100),
                .double(key: "minSpikeBars", label: "Min spike candles", default: 2, step: 1, range: 2...8),
                .double(key: "maxSpikeBars", label: "Max spike candles", default: 6, step: 1, range: 2...12),
                .double(key: "minSpikeATR", label: "Min spike strength (x ATR)", default: 1.5, step: 0.1, range: 0.1...5),
                .double(key: "minDirectionalRatio", label: "Min directional candles", default: 0.65, step: 0.05, range: 0.5...1),
                .double(key: "minBodyRatio", label: "Min body / range", default: 0.60, step: 0.05, range: 0.1...1),
                .double(key: "maxCloseFromExtreme", label: "Max close distance from extreme", default: 0.25, step: 0.05, range: 0...1),
                .double(key: "minMicroBars", label: "Min micro-channel candles", default: 2, step: 1, range: 2...8),
                .double(key: "maxMicroBars", label: "Max micro-channel candles", default: 8, step: 1, range: 2...20),
                .double(key: "maxMicroRangeRatio", label: "Max pullback / spike candle range", default: 0.70, step: 0.05, range: 0.1...1.5),
                .double(key: "maxRetracement", label: "Max spike retracement", default: 0.60, step: 0.05, range: 0.1...1),
                .double(key: "structureToleranceATR", label: "Structure tolerance (x ATR)", default: 0.10, step: 0.05, range: 0...1),
                .double(key: "maxReentryBars", label: "Re-entry expiry (bars)", default: 8, step: 1, range: 1...30),
                .double(key: "riskReward", label: "Risk reward", default: 2.0, step: 0.25, range: 0.25...10),
                .double(key: "confluenceBalanceBars", label: "Key-level lookback", default: 4, step: 1, range: 2...20),
                .double(key: "confluenceEMAPeriod", label: "Trend EMA", default: 60, step: 1, range: 10...200),
                .double(key: "minPressureGapPct", label: "Min pressure gap %", default: 0.0, step: 0.1, range: 0...5),
                .double(key: "maxPressureGapBar", label: "Latest pressure-gap candle", default: 3, step: 1, range: 2...6),
                .bool(key: "requirePressureGap", label: "Require SP2L pressure gap", default: false),
                .bool(key: "requireKeyLevelBreak", label: "Require key-level breakout", default: false),
                .double(key: "minConfluenceScore", label: "Minimum confluence score", default: 0, step: 1, range: 0...6),
            ]
        case .mtrStrategy:
            return [
                .double(key: "pivotDepth", label: "Pivot depth", default: 3, step: 1, range: 1...10),
                .double(key: "atrPeriod", label: "ATR period", default: 14, step: 1, range: 2...100),
                .double(key: "minTrendLegATR", label: "Min trend leg (x ATR)", default: 1.0, step: 0.1, range: 0...5),
                .double(key: "breakBufferATR", label: "Break close buffer (x ATR)", default: 0.10, step: 0.05, range: 0...1),
                .double(key: "retestToleranceATR", label: "Double top/bottom tolerance", default: 0.25, step: 0.05, range: 0...2),
                .double(key: "maxFailedBreakATR", label: "Max failed-break overshoot", default: 0.75, step: 0.05, range: 0.1...3),
                .double(key: "maxRetestBars", label: "Retest deadline (bars)", default: 20, step: 1, range: 2...100),
                .double(key: "maxConfirmationBars", label: "Confirmation deadline (bars)", default: 20, step: 1, range: 2...100),
                .double(key: "stopBufferATR", label: "Stop buffer (x ATR)", default: 0.10, step: 0.05, range: 0...2),
                .double(key: "riskReward", label: "Risk reward", default: 2.0, step: 0.25, range: 0.25...10),
                .double(key: "maxTradeBars", label: "Trade expiry (bars)", default: 50, step: 1, range: 5...250),
                .double(key: "maxResults", label: "Stored results", default: 12, step: 1, range: 1...50),
            ]
        case .fairValueGap:
            return [
                .double(key: "threshold", label: "Min Gap %", default: 0.0, step: 0.1, range: 0...5),
                .bool(key: "showMitigated", label: "Show mitigated gaps", default: true),
            ]
        case .sonarlabOrderBlock:
            return [
                .double(key: "sensitivity", label: "Sensitivity (ROC threshold)", default: 26.0, step: 1, range: 1...100),
                .enum(key: "mitigationType", label: "Mitigation type", default: "Close", options: [
                    ParamOption(label: "Close", value: "Close"),
                    ParamOption(label: "Wick", value: "Wick"),
                ]),
            ]
        case .changeOfCharacter:
            return [
                .double(key: "swingLength", label: "Swing length (pivots)", default: 5, step: 1, range: 2...50),
                .double(key: "minSwingPct", label: "Min swing %", default: 0.2, step: 0.1, range: 0...5),
                .bool(key: "showOB", label: "Show order block", default: true),
                .bool(key: "showFVG", label: "Show FVG", default: true),
                .bool(key: "showIFVG", label: "Show inverse FVG (iFVG)", default: false),
                .bool(key: "requireFVG", label: "Require FVG confluence", default: false),
                .bool(key: "showMitigated", label: "Show mitigated zones", default: false),
                .bool(key: "htfEnabled", label: "Higher-timeframe zones", default: false),
                .enum(key: "htfTimeframe", label: "HTF timeframe", default: "1h", options: [
                    ParamOption(label: "15m", value: "15m"),
                    ParamOption(label: "30m", value: "30m"),
                    ParamOption(label: "1H", value: "1h"),
                    ParamOption(label: "4H", value: "4h"),
                    ParamOption(label: "1D", value: "1d"),
                ]),
                .double(key: "htfCount", label: "HTF zones to show", default: 3, step: 1, range: 1...8),
            ]
        case .volumeProfile:
            return [
                .double(key: "bucketCount", label: "Buckets per session", default: 24, step: 2, range: 10...100),
                .double(key: "valueAreaPct", label: "Value area %", default: 70.0, step: 5.0, range: 50...95),
                .bool(key: "useZigzag", label: "ZigZag trend mode (last trend only)", default: true),
                .bool(key: "showZigzag", label: "Show ZigZag lines", default: true),
                .double(key: "zzDepth", label: "ZigZag depth", default: 5, step: 1, range: 2...50),
                .double(key: "zzMinChange", label: "ZigZag min change %", default: 1.0, step: 0.5, range: 0.1...10),
            ]
        }
    }
}

/// One instance of an indicator on the chart. Users can add multiple
/// instances of the same kind (e.g. two SMAs with different periods).
struct IndicatorInstance: Identifiable, Hashable, Codable {
    let id: UUID
    let kind: IndicatorKind
    var params: [String: ParamValue]
    var hidden: Bool

    init(id: UUID = UUID(), kind: IndicatorKind, params: [String: ParamValue] = [:], hidden: Bool = false) {
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
        case .sma20, .sma50, .sma200, .ema9, .ema21:
            let p = Int(params["period"]?.doubleValue ?? 0)
            return "\(kind.label) (\(p))"
        case .bollinger:
            let p = Int(params["period"]?.doubleValue ?? 20)
            let k = params["stdDev"]?.doubleValue ?? 2.0
            return "Bollinger (\(p), \(String(format: "%.1f", k)))"
        default:
            return kind.label
        }
    }
}

extension ParamSpec {
    var key: String {
        switch self {
        case .double(let k, _, _, _, _): return k
        case .bool(let k, _, _):         return k
        case .enum(let k, _, _, _):      return k
        }
    }

    var defaultValue: ParamValue {
        switch self {
        case .double(_, _, let d, _, _): return .double(d)
        case .bool(_, _, let d):         return .bool(d)
        case .enum(_, _, let d, _):      return .string(d)
        }
    }
}

/// One point on an indicator series. Tuple-ish but a struct so it slots
/// into `ForEach` with a stable identity. The chart now uses bar index
/// as its X plottable so consecutive bars sit flush against each other
/// even when there are calendar gaps (weekends), so indicators emit an
/// index rather than a wall-clock date.
struct IndicatorPoint: Identifiable, Hashable {
    let index: Int
    let value: Double
    /// Composite indicators (e.g. Bollinger) emit multiple bands; this
    /// disambiguates them within a single series.
    let band: String

    var id: String { "\(index)-\(band)" }
}

/// Pure-function indicator computations. No state, no rendering — the
/// chart layer maps these into `LineMark`s.
enum Indicators {
    /// Simple moving average. Each output point is the mean close over
    /// the trailing `period` candles. The first `period - 1` candles
    /// have no SMA value (not enough history) and are skipped.
    static func sma(_ candles: [Candle], period: Int) -> [IndicatorPoint] {
        guard period > 0, candles.count >= period else { return [] }
        var out: [IndicatorPoint] = []
        out.reserveCapacity(candles.count - period + 1)
        // Rolling sum — O(n) instead of O(n·period).
        var sum: Double = 0
        for i in 0..<candles.count {
            sum += candles[i].close
            if i >= period { sum -= candles[i - period].close }
            if i >= period - 1 {
                out.append(IndicatorPoint(
                    index: i,
                    value: sum / Double(period),
                    band: "sma\(period)"
                ))
            }
        }
        return out
    }

    /// Exponential moving average. Seeds the EMA with a plain SMA over
    /// the first `period` bars so the curve doesn't lurch out of the
    /// gate, then applies the standard recurrence.
    static func ema(_ candles: [Candle], period: Int) -> [IndicatorPoint] {
        guard period > 0, candles.count >= period else { return [] }
        let alpha = 2.0 / (Double(period) + 1.0)
        var out: [IndicatorPoint] = []
        out.reserveCapacity(candles.count - period + 1)
        // Seed = SMA of the first `period` closes.
        var prev = candles.prefix(period).reduce(0.0) { $0 + $1.close } / Double(period)
        out.append(IndicatorPoint(
            index: period - 1,
            value: prev,
            band: "ema\(period)"
        ))
        for i in period..<candles.count {
            prev = alpha * candles[i].close + (1 - alpha) * prev
            out.append(IndicatorPoint(
                index: i,
                value: prev,
                band: "ema\(period)"
            ))
        }
        return out
    }

    /// Bollinger Bands: SMA(period) with upper/lower envelope at ±σ·k
    /// (population standard deviation). Returns three series tagged
    /// "bb_upper", "bb_mid", "bb_lower" so the chart can style them
    /// independently. `k` defaults to 2 — the textbook setting.
    static func bollinger(_ candles: [Candle], period: Int = 20, k: Double = 2.0)
        -> [IndicatorPoint]
    {
        guard period > 1, candles.count >= period else { return [] }
        var out: [IndicatorPoint] = []
        out.reserveCapacity((candles.count - period + 1) * 3)
        // We need both mean and stddev per window. Maintain rolling sums
        // of value and squared value for O(n) per band.
        var sum: Double = 0
        var sumSq: Double = 0
        for i in 0..<candles.count {
            let c = candles[i].close
            sum += c
            sumSq += c * c
            if i >= period {
                let old = candles[i - period].close
                sum -= old
                sumSq -= old * old
            }
            if i >= period - 1 {
                let mean = sum / Double(period)
                // Variance via E[x²] - E[x]². Clamp to 0 to dodge
                // tiny negative results from floating-point drift.
                let variance = max(0, sumSq / Double(period) - mean * mean)
                let sd = variance.squareRoot()
                out.append(.init(index: i, value: mean - k * sd, band: "bb_lower"))
                out.append(.init(index: i, value: mean,           band: "bb_mid"))
                out.append(.init(index: i, value: mean + k * sd, band: "bb_upper"))
            }
        }
        return out
    }

    /// Dispatch: compute each visible indicator instance, returning points.
    static func compute(instances: [IndicatorInstance], candles: [Candle])
        -> [(instance: IndicatorInstance, points: [IndicatorPoint])]
    {
        instances.compactMap { inst in
            guard !inst.hidden else { return nil }
            let pts: [IndicatorPoint]
            switch inst.kind {
            case .sma20, .sma50, .sma200:
                let period = Int(inst.params["period"]?.doubleValue ?? 20)
                pts = sma(candles, period: period)
            case .ema9, .ema21:
                let period = Int(inst.params["period"]?.doubleValue ?? 9)
                pts = ema(candles, period: period)
            case .bollinger:
                let period = Int(inst.params["period"]?.doubleValue ?? 20)
                let k = inst.params["stdDev"]?.doubleValue ?? 2.0
                pts = bollinger(candles, period: period, k: k)
            default:
                pts = []
            }
            return pts.isEmpty ? nil : (inst, pts)
        }
    }
}
