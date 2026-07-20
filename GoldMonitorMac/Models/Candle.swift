import Foundation

/// A single OHLC bar at the given timeframe. Used by ChartView (Apple Charts)
/// for both line plots (using `close` only) and candlestick plots (full OHLC).
struct Candle: Identifiable, Hashable {
    let id: Date            // bucket start time, also unique across a series
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    /// Trading volume during the bucket. Optional because some live-tick
    /// sources have no notion of volume; only Yahoo-sourced bars populate
    /// this.
    var volume: Double?
    var bucketStart: Date { id }

    init(id: Date, open: Double, high: Double, low: Double, close: Double, volume: Double? = nil) {
        self.id = id
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
    }
}

extension Candle {
    /// Cheap O(1) equality proxy for a whole candle *series*, used by the
    /// `Equatable` chart views (`ChartView`, `VolumeBarsView`,
    /// `OscillatorPanel`) to decide whether a parent-driven re-render
    /// actually changed the drawn data. Mirrors the signature the
    /// `ChartDerivedCache` already keys on: the series only ever changes
    /// by a full reload (count / first bar differ) or by rewriting the
    /// trailing bar on a live tick (last bar differs). Comparing count +
    /// first id + last bar catches every one of those without an O(n)
    /// element-wise walk on the hot pan/zoom path.
    static func seriesEqual(_ a: [Candle], _ b: [Candle]) -> Bool {
        guard a.count == b.count else { return false }
        guard let fa = a.first, let fb = b.first else { return a.isEmpty && b.isEmpty }
        guard fa.id == fb.id, let la = a.last, let lb = b.last else { return false }
        return la.id == lb.id
            && la.open == lb.open && la.high == lb.high
            && la.low == lb.low && la.close == lb.close
            && la.volume == lb.volume
    }
}

/// Supported analysis timeframes. Same set as the web app's
/// [`ChartAnalysisPanel`](../../newWebapp2/src/components/Chart/ChartAnalysisPanel.tsx).
enum Timeframe: String, CaseIterable, Identifiable, Codable {
    case m1 = "1m"
    case m5 = "5m"
    case m15 = "15m"
    case m30 = "30m"
    case h1 = "1h"
    case h4 = "4h"
    case d1 = "1d"

    var id: String { rawValue }

    /// Human label for the picker.
    var label: String {
        switch self {
        case .m1: return "1 min"
        case .m5: return "5 min"
        case .m15: return "15 min"
        case .m30: return "30 min"
        case .h1: return "1 hour"
        case .h4: return "4 hours"
        case .d1: return "1 day"
        }
    }

    /// Bucket size in seconds.
    var seconds: TimeInterval {
        switch self {
        case .m1:  return 60
        case .m5:  return 300
        case .m15: return 900
        case .m30: return 1800
        case .h1:  return 3600
        case .h4:  return 14400
        case .d1:  return 86400
        }
    }

    /// How far back to look for snapshots when building a chart at this
    /// timeframe. Trades freshness for chart density — coarser bars need
    /// more history to render meaningfully.
    var historySeconds: TimeInterval {
        switch self {
        case .m1:  return 6 * 3600       // 6 hours of 1-min bars = 360 candles
        case .m5:  return 24 * 3600      // 1 day → 288 candles
        case .m15: return 3 * 24 * 3600  // 3 days → 288 candles
        case .m30: return 7 * 24 * 3600
        case .h1:  return 14 * 24 * 3600
        case .h4:  return 30 * 24 * 3600
        case .d1:  return 180 * 24 * 3600
        }
    }
}

/// Chart rendering style. The dashboard forces line on 1m timeframes
/// because candlesticks are visual noise at that granularity (most bars
/// have body=0 or close to it).
enum ChartType: String, CaseIterable, Identifiable, Codable {
    case line
    case candle
    /// Heikin Ashi candles. Drawn just like regular candles but with
    /// OHLC values transformed via `HeikinAshi.transform`. The chart's
    /// indicator overlays still use raw closes — only the visible candle
    /// bodies/wicks (and the hover tooltip / last-price reference) shift
    /// to HA values.
    case heikinAshi

    var id: String { rawValue }
    var label: String {
        switch self {
        case .line:       return "Line"
        case .candle:     return "Candle"
        case .heikinAshi: return "Heikin Ashi"
        }
    }
}

/// Heikin Ashi candle transform. HA candles smooth price action by
/// averaging OHLC across each bar — they trade some precision for an
/// easier visual read of trend direction.
///
/// Formulae (canonical):
///   HA_close = (O + H + L + C) / 4
///   HA_open  = first bar: (O + C) / 2
///              else:       (prev HA_open + prev HA_close) / 2
///   HA_high  = max(H, HA_open, HA_close)
///   HA_low   = min(L, HA_open, HA_close)
///
/// Volume rides along unchanged — HA doesn't have a notion of derived
/// volume, the raw figure is what traders look at alongside HA bars.
enum HeikinAshi {
    static func transform(_ candles: [Candle]) -> [Candle] {
        guard !candles.isEmpty else { return [] }
        var out: [Candle] = []
        out.reserveCapacity(candles.count)
        var prevHAOpen  = (candles[0].open  + candles[0].close) / 2
        var prevHAClose = (candles[0].open + candles[0].high + candles[0].low + candles[0].close) / 4
        for (i, c) in candles.enumerated() {
            let haClose = (c.open + c.high + c.low + c.close) / 4
            let haOpen: Double
            if i == 0 {
                haOpen = (c.open + c.close) / 2
            } else {
                haOpen = (prevHAOpen + prevHAClose) / 2
            }
            let haHigh = max(c.high, haOpen, haClose)
            let haLow  = min(c.low,  haOpen, haClose)
            out.append(Candle(
                id:    c.bucketStart,
                open:  haOpen,
                high:  haHigh,
                low:   haLow,
                close: haClose,
                volume: c.volume
            ))
            prevHAOpen  = haOpen
            prevHAClose = haClose
        }
        return out
    }
}

/// Fold pre-aggregated OHLC bars into a coarser timeframe. All pairs
/// now store 1m and 5m bars from Yahoo (or live ticks from
/// TwelveData / cTrader); coarser timeframes are rolled up on the
/// fly. Bars in → bars out: open=first bar's open, close=last bar's
/// close, high/low = extremes across the group.
enum OHLCAggregator {
    /// Bucket bars by `target` timeframe and fold OHLC. Input must be
    /// chronologically sorted (caller's responsibility — OHLCRepo.read
    /// returns sorted). Bars whose own bucket size is larger than `target`
    /// are passed through unchanged (we never *downsample*).
    static func fold(bars: [OHLCBar], into target: Timeframe) -> [Candle] {
        guard !bars.isEmpty else { return [] }
        let bucketSize = target.seconds

        // Group key = floor(barStart / bucketSize). Insertion order matters
        // because we use the FIRST bar's open and the LAST bar's close.
        // Volume sums across the group — that's the canonical roll-up.
        struct Group {
            var ts: TimeInterval
            var open: Double
            var high: Double
            var low: Double
            var close: Double
            var volume: Double
            var hadVolume: Bool   // nil-vs-zero discriminator
        }
        var grouped: [Group] = []
        var lastKey: TimeInterval = -1
        for b in bars {
            let key = floor(b.bucketStart.timeIntervalSince1970 / bucketSize) * bucketSize
            if key != lastKey {
                grouped.append(Group(
                    ts: key, open: b.open, high: b.high, low: b.low, close: b.close,
                    volume: b.volume ?? 0,
                    hadVolume: b.volume != nil
                ))
                lastKey = key
            } else {
                var g = grouped[grouped.count - 1]
                if b.high > g.high { g.high = b.high }
                if b.low  < g.low  { g.low  = b.low  }
                g.close = b.close
                if let v = b.volume {
                    g.volume += v
                    g.hadVolume = true
                }
                grouped[grouped.count - 1] = g
            }
        }

        return grouped.map { g in
            Candle(
                id: Date(timeIntervalSince1970: g.ts),
                open: g.open, high: g.high, low: g.low, close: g.close,
                volume: g.hadVolume ? g.volume : nil
            )
        }
    }
}
