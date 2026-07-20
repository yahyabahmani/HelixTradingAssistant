import Foundation

/// Ichimoku Kinkō Hyō ("one glance equilibrium chart") — the classic
/// trend / equilibrium / dynamic-S-R system.
///
/// Five components, all derived from candle highs/lows (never closes,
/// except Chikou):
///   • Tenkan-sen (Conversion) — midpoint of the last `tenkan` bars.
///   • Kijun-sen  (Base)       — midpoint of the last `kijun` bars.
///   • Senkou Span A (Leading A) — (Tenkan + Kijun) / 2, plotted
///     `displacement` bars *ahead*.
///   • Senkou Span B (Leading B) — midpoint of the last `senkouB` bars,
///     plotted `displacement` bars *ahead*.
///   • Chikou Span (Lagging)   — the close, plotted `displacement` bars
///     *behind*.
/// The band between Span A and Span B is the Kumo (cloud): bullish
/// (green) when A ≥ B, bearish (red) when A < B.
///
/// Pure-function, no state. `ChartView` maps `Output` into `LineMark`s
/// (the five lines) plus `AreaMark`s (the cloud fill), mirroring how the
/// other custom overlays render. Displacement is applied to the *plot*
/// index here so the renderer just plots each point at `point.index`.
enum Ichimoku {
    /// One plotted sample of a single line. `index` is the bar the value
    /// is *drawn* at (displacement already folded in), so Chikou points
    /// carry indices below their source bar and Senkou points carry
    /// indices above it.
    struct LinePoint: Identifiable, Hashable {
        let index: Int
        let value: Double
        var id: Int { index }
    }

    /// One plotted slice of the cloud: the two span values at a drawn
    /// bar index. `isBullish` is A ≥ B (green) vs A < B (red).
    struct CloudPoint: Identifiable, Hashable {
        let index: Int
        let spanA: Double
        let spanB: Double
        var isBullish: Bool { spanA >= spanB }
        var id: Int { index }
    }

    struct Output: Hashable {
        var tenkan: [LinePoint]
        var kijun: [LinePoint]
        var senkouA: [LinePoint]
        var senkouB: [LinePoint]
        var chikou: [LinePoint]
        var cloud: [CloudPoint]

        static let empty = Output(
            tenkan: [], kijun: [], senkouA: [], senkouB: [], chikou: [], cloud: []
        )
    }

    /// Rolling window midpoint = (max high + min low) / 2 over the trailing
    /// `period` bars. Returns one value per bar; the first `period - 1`
    /// bars have no value (nil) — not enough history.
    ///
    /// Uses monotonic deques for O(n) rolling max/min so deep 1-minute
    /// histories stay cheap on the background compute Task.
    private static func midline(_ candles: [Candle], period: Int) -> [Double?] {
        let n = candles.count
        var out = [Double?](repeating: nil, count: n)
        guard period > 0, n >= period else { return out }
        // Monotonic deques of indices: `maxD` decreasing highs, `minD`
        // increasing lows. Front is always the window extreme.
        var maxD: [Int] = []
        var minD: [Int] = []
        for i in 0..<n {
            let h = candles[i].high
            let l = candles[i].low
            while let last = maxD.last, candles[last].high <= h { maxD.removeLast() }
            maxD.append(i)
            while let last = minD.last, candles[last].low >= l { minD.removeLast() }
            minD.append(i)
            let windowStart = i - period + 1
            if let f = maxD.first, f < windowStart { maxD.removeFirst() }
            if let f = minD.first, f < windowStart { minD.removeFirst() }
            if i >= period - 1 {
                let hi = candles[maxD.first!].high
                let lo = candles[minD.first!].low
                out[i] = (hi + lo) / 2
            }
        }
        return out
    }

    /// Compute all five lines + the cloud.
    ///
    /// - tenkan/kijun/senkouB: the three midline periods (Pine defaults
    ///   9 / 26 / 52).
    /// - displacement: how far Senkou spans lead and Chikou lags (26).
    static func compute(
        _ candles: [Candle],
        tenkan tenkanP: Int = 9,
        kijun kijunP: Int = 26,
        senkouB senkouBP: Int = 52,
        displacement: Int = 26
    ) -> Output {
        let n = candles.count
        guard n > 0 else { return .empty }

        let tenkanMid = midline(candles, period: tenkanP)
        let kijunMid = midline(candles, period: kijunP)
        let senkouBMid = midline(candles, period: senkouBP)

        var tenkan: [LinePoint] = []
        var kijun: [LinePoint] = []
        var senkouA: [LinePoint] = []
        var senkouB: [LinePoint] = []
        var chikou: [LinePoint] = []
        var cloud: [CloudPoint] = []

        for i in 0..<n {
            if let t = tenkanMid[i] { tenkan.append(LinePoint(index: i, value: t)) }
            if let k = kijunMid[i] { kijun.append(LinePoint(index: i, value: k)) }

            // Senkou spans are computed at bar i but drawn `displacement`
            // bars ahead. Only the slice that still lands on a real (or
            // just-past-the-last) bar is kept — the far-forward tail is
            // clipped by the chart's x-domain anyway.
            let drawIdx = i + displacement
            if let t = tenkanMid[i], let k = kijunMid[i] {
                let a = (t + k) / 2
                senkouA.append(LinePoint(index: drawIdx, value: a))
                if let b = senkouBMid[i] {
                    senkouB.append(LinePoint(index: drawIdx, value: b))
                    cloud.append(CloudPoint(index: drawIdx, spanA: a, spanB: b))
                }
            } else if let b = senkouBMid[i] {
                senkouB.append(LinePoint(index: drawIdx, value: b))
            }

            // Chikou is the close drawn `displacement` bars behind.
            let lagIdx = i - displacement
            if lagIdx >= 0 {
                chikou.append(LinePoint(index: lagIdx, value: candles[i].close))
            }
        }

        return Output(
            tenkan: tenkan,
            kijun: kijun,
            senkouA: senkouA,
            senkouB: senkouB,
            chikou: chikou,
            cloud: cloud
        )
    }

    /// The non-displaced component values *at* bar `i` — what a trader
    /// reads as "current" Tenkan/Kijun, plus the cloud edges actually
    /// visible over bar `i` (which are the spans computed `displacement`
    /// bars earlier). Used by `IchimokuOrderBlocks` for confluence
    /// scoring so it doesn't have to re-derive the geometry.
    struct Snapshot {
        let tenkan: Double?
        let kijun: Double?
        /// Upper / lower edge of the Kumo visible over this bar.
        let cloudTop: Double?
        let cloudBottom: Double?
        /// True when the cloud over this bar is bullish (Span A ≥ B).
        let cloudBullish: Bool
    }

    /// Build a per-bar snapshot array aligned to `candles` indices.
    static func snapshots(
        _ candles: [Candle],
        tenkan tenkanP: Int = 9,
        kijun kijunP: Int = 26,
        senkouB senkouBP: Int = 52,
        displacement: Int = 26
    ) -> [Snapshot] {
        let n = candles.count
        let tenkanMid = midline(candles, period: tenkanP)
        let kijunMid = midline(candles, period: kijunP)
        let senkouBMid = midline(candles, period: senkouBP)
        var out: [Snapshot] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            // Cloud visible over bar i was computed at bar i - displacement.
            let src = i - displacement
            var top: Double? = nil
            var bottom: Double? = nil
            var bullish = false
            if src >= 0, let t = tenkanMid[src], let k = kijunMid[src], let b = senkouBMid[src] {
                let a = (t + k) / 2
                top = max(a, b)
                bottom = min(a, b)
                bullish = a >= b
            }
            out.append(Snapshot(
                tenkan: tenkanMid[i],
                kijun: kijunMid[i],
                cloudTop: top,
                cloudBottom: bottom,
                cloudBullish: bullish
            ))
        }
        return out
    }
}
