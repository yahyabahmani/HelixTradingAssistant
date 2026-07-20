import Foundation

/// Ranked Order Blocks — swing-structure order blocks graded by Volume
/// Profile + Ichimoku confluence.
///
/// Ported from the PineScript v6 "Ranked Order Blocks Pro
/// [Swing + VP + Ichimoku]" indicator. Three pieces:
///
///   1. **Detection (swing engine).** A pivot high/low confirmed
///      `swingLength` bars later becomes the "protected" swing. When a
///      close breaks that swing (a BOS), we walk back to the extreme
///      candle of the impulse and mark its range as the order block —
///      lowest low for a bullish break, highest high for a bearish one.
///      Zones wider than `maxATRMult × ATR` are discarded as noise.
///
///   2. **Lifecycle.** A zone stays live until price trades through it
///      (wick or close, per `invalidateByClose`). At that point it flips
///      into a *breaker* — its right edge freezes at the break bar — and
///      it is dropped entirely once price passes fully through the far
///      side.
///
///   3. **Ranking.** Each zone scores 0–2 for Volume Profile overlap
///      (does it sit on a high-volume node?) and 0–3 for Ichimoku
///      alignment (bullish zones above the cloud, plus Tenkan/Kijun
///      agreement). The total maps to a grade: ≥70% → A, ≥40% → B,
///      else C. Both legs are optional; `maxScore` reports the divisor
///      actually in play so the UI can render "3/5".
///
/// The Pine original also draws the VP histogram, the Ichimoku cloud,
/// and a legend table. Here VP and Ichimoku are *scoring inputs only* —
/// the app already ships a standalone Volume Profile indicator, and the
/// chart layer renders just the graded zones.
///
/// Pure-function, no state. `ChartView` maps the result into
/// `RectangleMark`s.
enum RankedOrderBlocks {

    /// How a zone's price range is measured off the extreme candle.
    enum ZoneSource: String, Codable, Hashable {
        /// Whole high-low range including wicks (Pine default).
        case wicks
        /// Candle body only.
        case body
    }

    /// What counts as trading through a zone.
    enum Invalidation: String, Codable, Hashable {
        /// Any wick past the far edge.
        case wick
        /// Only a body (open/close) past the far edge.
        case close
    }

    /// Letter grade from the confluence score.
    enum Grade: String, Codable, Hashable {
        case a = "A"
        case b = "B"
        case c = "C"
        /// No ranking inputs enabled — nothing to grade on.
        case unranked = "–"
    }

    struct Config: Equatable {
        var swingLength: Int = 10
        var zoneSource: ZoneSource = .wicks
        var maxATRMult: Double = 3.5
        var atrLength: Int = 10
        var invalidation: Invalidation = .wick
        /// Zones rendered per side (bullish / bearish), most recent first.
        var zonesPerSide: Int = 3
        /// Cap on zones tracked per side while scanning.
        var maxStored: Int = 30
        var showBreakers: Bool = true
        var combineOverlapping: Bool = true
        /// Minimum overlap (% of the union area) for two zones to merge.
        var mergeThreshold: Double = 0.0

        var useVolumeProfile: Bool = true
        var vpLookback: Int = 200
        var vpRows: Int = 24

        var useIchimoku: Bool = true
        var tenkanLength: Int = 9
        var kijunLength: Int = 26
        var senkouBLength: Int = 52
        var ichimokuDisplacement: Int = 26

        /// Only the last N bars are scanned for new zones (Pine's
        /// `maxDist`) — deep histories would otherwise mark up zones
        /// that scrolled off long ago.
        var processingWindow: Int = 1750
    }

    /// One graded order block.
    struct Zone: Identifiable, Hashable {
        /// Bar index of the order-block candle.
        let startIndex: Int
        /// Right edge — the break bar for a breaker, else the last bar.
        let endIndex: Int
        let top: Double
        let bottom: Double
        let isBullish: Bool
        /// True once price traded through the zone; drawn dashed/grey.
        let isBreaker: Bool
        /// Product of merging two overlapping zones.
        let isCombined: Bool
        let grade: Grade
        let score: Int
        let maxScore: Int

        var id: String {
            "rob-\(startIndex)-\(endIndex)-\(isBullish ? "bull" : "bear")-\(isCombined ? "m" : "s")"
        }

        /// "A 4/5" — the badge the chart draws on the zone.
        var badge: String {
            grade == .unranked ? "OB" : "\(grade.rawValue) \(score)/\(maxScore)"
        }
    }

    // MARK: - Internal working zone (mutable through the scan)

    private struct WorkingZone {
        var top: Double
        var bottom: Double
        var isBullish: Bool
        var startIndex: Int
        var isBreaker: Bool = false
        var breakIndex: Int? = nil
        var isCombined: Bool = false
        var score: Int = 0
        var maxScore: Int = 0
    }

    // MARK: - Entry point

    static func compute(_ candles: [Candle], config cfg: Config) -> [Zone] {
        let n = candles.count
        guard n > cfg.swingLength + 2, cfg.swingLength >= 2 else { return [] }

        let atr = wilderATR(candles, period: max(1, cfg.atrLength))
        let ichi = cfg.useIchimoku ? ichimokuCloud(candles, cfg: cfg) : nil

        // Zone-range source per bar: wicks (high/low) or body extremes.
        let maxP: [Double] = candles.map { cfg.zoneSource == .body ? max($0.open, $0.close) : $0.high }
        let minP: [Double] = candles.map { cfg.zoneSource == .body ? min($0.open, $0.close) : $0.low }

        // Rolling swing state — mirrors the Pine `var` block.
        var swingType = 0            // 0 = last pivot was a high, 1 = a low
        var swingTop: (price: Double, index: Int)? = nil
        var swingBottom: (price: Double, index: Int)? = nil
        var topCrossed = false
        var bottomCrossed = false

        // Most-recent-first, like Pine's `unshift`.
        var bullZones: [WorkingZone] = []
        var bearZones: [WorkingZone] = []

        let windowStart = max(0, n - max(1, cfg.processingWindow))

        for i in cfg.swingLength..<n {
            let pivotIdx = i - cfg.swingLength

            // ── Swing detection ──────────────────────────────────────
            // A pivot is confirmed once `swingLength` bars have printed
            // without exceeding it.
            let tailStart = pivotIdx + 1
            var tailHigh = -Double.greatestFiniteMagnitude
            var tailLow = Double.greatestFiniteMagnitude
            for k in tailStart...i {
                tailHigh = max(tailHigh, candles[k].high)
                tailLow = min(tailLow, candles[k].low)
            }
            let prevSwingType = swingType
            if candles[pivotIdx].high > tailHigh {
                swingType = 0
            } else if candles[pivotIdx].low < tailLow {
                swingType = 1
            }
            if swingType == 0 && prevSwingType != 0 {
                swingTop = (candles[pivotIdx].high, pivotIdx)
                topCrossed = false
            }
            if swingType == 1 && prevSwingType != 1 {
                swingBottom = (candles[pivotIdx].low, pivotIdx)
                bottomCrossed = false
            }

            // ── Lifecycle: mitigation → breaker → removal ────────────
            // Runs before creation, matching Pine's statement order.
            let bar = candles[i]
            let lowProbe  = cfg.invalidation == .wick ? bar.low  : min(bar.open, bar.close)
            let highProbe = cfg.invalidation == .wick ? bar.high : max(bar.open, bar.close)

            for zi in bullZones.indices.reversed() {
                if !bullZones[zi].isBreaker {
                    if lowProbe < bullZones[zi].bottom {
                        bullZones[zi].isBreaker = true
                        bullZones[zi].breakIndex = i
                    }
                } else if bar.high > bullZones[zi].top {
                    bullZones.remove(at: zi)
                }
            }
            for zi in bearZones.indices.reversed() {
                if !bearZones[zi].isBreaker {
                    if highProbe > bearZones[zi].top {
                        bearZones[zi].isBreaker = true
                        bearZones[zi].breakIndex = i
                    }
                } else if bar.low < bearZones[zi].bottom {
                    bearZones.remove(at: zi)
                }
            }

            guard i >= windowStart, i >= 1 else { continue }

            // ── Creation: a close through the protected swing ────────
            let atrHere = atr[i]
            let maxWidth = atrHere * cfg.maxATRMult

            if let top = swingTop, !topCrossed, bar.close > top.price {
                topCrossed = true
                // Walk back to the impulse's lowest candle.
                var zoneBottom = minP[i - 1]
                var zoneTop = maxP[i - 1]
                var zoneIdx = i - 1
                if i - 2 > top.index {
                    for j in stride(from: i - 2, through: top.index + 1, by: -1) {
                        if minP[j] < zoneBottom {
                            zoneBottom = minP[j]
                            zoneTop = maxP[j]
                            zoneIdx = j
                        }
                    }
                }
                if zoneTop > zoneBottom, maxWidth <= 0 || (zoneTop - zoneBottom) <= maxWidth {
                    var z = WorkingZone(top: zoneTop, bottom: zoneBottom, isBullish: true, startIndex: zoneIdx)
                    let scored = score(
                        top: zoneTop, bottom: zoneBottom, isBullish: true,
                        at: i, candles: candles, ichi: ichi, cfg: cfg
                    )
                    z.score = scored.score
                    z.maxScore = scored.maxScore
                    bullZones.insert(z, at: 0)
                    if bullZones.count > cfg.maxStored { bullZones.removeLast() }
                }
            }

            if let bottom = swingBottom, !bottomCrossed, bar.close < bottom.price {
                bottomCrossed = true
                var zoneTop = maxP[i - 1]
                var zoneBottom = minP[i - 1]
                var zoneIdx = i - 1
                if i - 2 > bottom.index {
                    for j in stride(from: i - 2, through: bottom.index + 1, by: -1) {
                        if maxP[j] > zoneTop {
                            zoneTop = maxP[j]
                            zoneBottom = minP[j]
                            zoneIdx = j
                        }
                    }
                }
                if zoneTop > zoneBottom, maxWidth <= 0 || (zoneTop - zoneBottom) <= maxWidth {
                    var z = WorkingZone(top: zoneTop, bottom: zoneBottom, isBullish: false, startIndex: zoneIdx)
                    let scored = score(
                        top: zoneTop, bottom: zoneBottom, isBullish: false,
                        at: i, candles: candles, ichi: ichi, cfg: cfg
                    )
                    z.score = scored.score
                    z.maxScore = scored.maxScore
                    bearZones.insert(z, at: 0)
                    if bearZones.count > cfg.maxStored { bearZones.removeLast() }
                }
            }
        }

        // ── Render set: the freshest `zonesPerSide` from each side ───
        let perSide = max(1, cfg.zonesPerSide)
        var render = Array(bullZones.prefix(perSide)) + Array(bearZones.prefix(perSide))
        if !cfg.showBreakers {
            render.removeAll { $0.isBreaker }
        }
        if cfg.combineOverlapping {
            render = merge(render, lastIndex: n - 1, at: n - 1, candles: candles, ichi: ichi, cfg: cfg)
        }

        return render.map { z in
            Zone(
                startIndex: z.startIndex,
                endIndex: z.isBreaker ? (z.breakIndex ?? n - 1) : n - 1,
                top: z.top,
                bottom: z.bottom,
                isBullish: z.isBullish,
                isBreaker: z.isBreaker,
                isCombined: z.isCombined,
                grade: grade(score: z.score, maxScore: z.maxScore),
                score: z.score,
                maxScore: z.maxScore
            )
        }
    }

    // MARK: - Merging

    /// Repeatedly fuse same-direction zones whose overlap exceeds
    /// `mergeThreshold` (% of their union area). Pine loops until no
    /// pair merges; we bound the passes so a pathological input can't
    /// spin.
    private static func merge(
        _ zones: [WorkingZone],
        lastIndex: Int,
        at bar: Int,
        candles: [Candle],
        ichi: IchimokuCloud?,
        cfg: Config
    ) -> [WorkingZone] {
        var work = zones
        var passes = 0
        while passes < 16 {
            passes += 1
            var mergedAny = false
            outer: for i in 0..<work.count {
                for j in (i + 1)..<work.count {
                    guard work[i].isBullish == work[j].isBullish else { continue }
                    guard overlaps(work[i], work[j], lastIndex: lastIndex, threshold: cfg.mergeThreshold) else { continue }

                    let a = work[i], b = work[j]
                    var m = WorkingZone(
                        top: max(a.top, b.top),
                        bottom: min(a.bottom, b.bottom),
                        isBullish: a.isBullish,
                        startIndex: min(a.startIndex, b.startIndex)
                    )
                    m.isBreaker = a.isBreaker || b.isBreaker
                    m.breakIndex = [a.breakIndex, b.breakIndex].compactMap { $0 }.max()
                    m.isCombined = true
                    let scored = score(
                        top: m.top, bottom: m.bottom, isBullish: m.isBullish,
                        at: bar, candles: candles, ichi: ichi, cfg: cfg
                    )
                    m.score = scored.score
                    m.maxScore = scored.maxScore

                    work.remove(at: j)
                    work.remove(at: i)
                    work.insert(m, at: 0)
                    mergedAny = true
                    break outer
                }
            }
            if !mergedAny { break }
        }
        return work
    }

    /// Intersection-over-union of the two zones' drawn rectangles, as a
    /// percentage. `> threshold` means merge.
    private static func overlaps(
        _ a: WorkingZone,
        _ b: WorkingZone,
        lastIndex: Int,
        threshold: Double
    ) -> Bool {
        func right(_ z: WorkingZone) -> Double {
            Double(z.isBreaker ? (z.breakIndex ?? lastIndex) : lastIndex + 1)
        }
        func area(_ z: WorkingZone) -> Double {
            abs(right(z) - Double(z.startIndex)) * abs(z.top - z.bottom)
        }
        let ix = max(0, min(right(a), right(b)) - Double(max(a.startIndex, b.startIndex)))
        let iy = max(0, min(a.top, b.top) - max(a.bottom, b.bottom))
        let inter = ix * iy
        let union = area(a) + area(b) - inter
        guard union > 0 else { return false }
        return inter / union * 100.0 > threshold
    }

    // MARK: - Scoring

    private static func score(
        top: Double,
        bottom: Double,
        isBullish: Bool,
        at bar: Int,
        candles: [Candle],
        ichi: IchimokuCloud?,
        cfg: Config
    ) -> (score: Int, maxScore: Int) {
        var total = 0
        var maxScore = 0
        if cfg.useVolumeProfile {
            maxScore += 2
            total += volumeScore(top: top, bottom: bottom, at: bar, candles: candles, cfg: cfg)
        }
        if cfg.useIchimoku, let ichi {
            maxScore += 3
            total += ichimokuScore(top: top, bottom: bottom, isBullish: isBullish, at: bar, ichi: ichi)
        }
        return (total, maxScore)
    }

    /// 0–2 by how close the zone's busiest price row sits to the profile
    /// peak: ≥70% of peak volume → 2, ≥40% → 1, else 0.
    private static func volumeScore(
        top: Double,
        bottom: Double,
        at bar: Int,
        candles: [Candle],
        cfg: Config
    ) -> Int {
        let rows = max(1, cfg.vpRows)
        let lookback = max(1, min(cfg.vpLookback, bar + 1))
        let start = bar - lookback + 1
        var hi = -Double.greatestFiniteMagnitude
        var lo = Double.greatestFiniteMagnitude
        for k in start...bar {
            hi = max(hi, candles[k].high)
            lo = min(lo, candles[k].low)
        }
        let step = (hi - lo) / Double(rows)
        guard step > 0 else { return 0 }

        var bins = [Double](repeating: 0, count: rows)
        for k in start...bar {
            let typical = (candles[k].high + candles[k].low + candles[k].close) / 3
            let b = max(0, min(rows - 1, Int((typical - lo) / step)))
            bins[b] += candles[k].volume ?? 0
        }
        guard let peak = bins.max(), peak > 0 else { return 0 }

        let b0 = max(0, min(rows - 1, Int((bottom - lo) / step)))
        let b1 = max(0, min(rows - 1, Int((top - lo) / step)))
        var localMax = 0.0
        for b in min(b0, b1)...max(b0, b1) { localMax = max(localMax, bins[b]) }

        let ratio = localMax / peak
        return ratio >= 0.7 ? 2 : ratio >= 0.4 ? 1 : 0
    }

    /// 0–3: position relative to the Kumo (0–2) plus Tenkan/Kijun
    /// agreement (0–1).
    private static func ichimokuScore(
        top: Double,
        bottom: Double,
        isBullish: Bool,
        at bar: Int,
        ichi: IchimokuCloud
    ) -> Int {
        guard let cloudTop = ichi.top[bar], let cloudBottom = ichi.bottom[bar] else { return 0 }
        let tenkan = ichi.tenkan[bar]
        let kijun = ichi.kijun[bar]
        var s: Int
        if isBullish {
            s = bottom > cloudTop ? 2 : top < cloudBottom ? 0 : 1
            if let tenkan, let kijun, tenkan > kijun { s += 1 }
        } else {
            s = top < cloudBottom ? 2 : bottom > cloudTop ? 0 : 1
            if let tenkan, let kijun, tenkan < kijun { s += 1 }
        }
        return s
    }

    private static func grade(score: Int, maxScore: Int) -> Grade {
        guard maxScore > 0 else { return .unranked }
        let ratio = Double(score) / Double(maxScore)
        return ratio >= 0.7 ? .a : ratio >= 0.4 ? .b : .c
    }

    // MARK: - Ichimoku

    /// Per-bar Ichimoku values. `top`/`bottom` are the Kumo boundaries
    /// *as seen at that bar* — i.e. Senkou A/B computed `displacement`
    /// bars earlier, which is where the cloud gets its forward shift.
    private struct IchimokuCloud {
        let tenkan: [Double?]
        let kijun: [Double?]
        let top: [Double?]
        let bottom: [Double?]
    }

    private static func ichimokuCloud(_ candles: [Candle], cfg: Config) -> IchimokuCloud {
        let n = candles.count
        let tenkan = donchianMid(candles, period: max(1, cfg.tenkanLength))
        let kijun  = donchianMid(candles, period: max(1, cfg.kijunLength))
        let senkouB = donchianMid(candles, period: max(2, cfg.senkouBLength))
        var senkouA = [Double?](repeating: nil, count: n)
        for i in 0..<n {
            if let t = tenkan[i], let k = kijun[i] { senkouA[i] = (t + k) / 2 }
        }

        let disp = max(1, cfg.ichimokuDisplacement)
        var top = [Double?](repeating: nil, count: n)
        var bottom = [Double?](repeating: nil, count: n)
        for i in disp..<max(disp, n) {
            guard let a = senkouA[i - disp], let b = senkouB[i - disp] else { continue }
            top[i] = max(a, b)
            bottom[i] = min(a, b)
        }
        return IchimokuCloud(tenkan: tenkan, kijun: kijun, top: top, bottom: bottom)
    }

    /// Midpoint of the rolling high/low channel — the shape every
    /// Ichimoku line takes.
    private static func donchianMid(_ candles: [Candle], period: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: candles.count)
        guard period > 0, candles.count >= period else { return out }
        for i in (period - 1)..<candles.count {
            var hi = -Double.greatestFiniteMagnitude
            var lo = Double.greatestFiniteMagnitude
            for k in (i - period + 1)...i {
                hi = max(hi, candles[k].high)
                lo = min(lo, candles[k].low)
            }
            out[i] = (hi + lo) / 2
        }
        return out
    }

    // MARK: - ATR

    /// Wilder-smoothed ATR, seeded with the simple mean of the first
    /// `period` true ranges — matches Pine's `ta.atr`.
    private static func wilderATR(_ candles: [Candle], period: Int) -> [Double] {
        let n = candles.count
        var out = [Double](repeating: 0, count: n)
        guard n > 1 else { return out }

        var trueRanges = [Double](repeating: 0, count: n)
        trueRanges[0] = candles[0].high - candles[0].low
        for i in 1..<n {
            let prevClose = candles[i - 1].close
            trueRanges[i] = max(
                candles[i].high - candles[i].low,
                max(abs(candles[i].high - prevClose), abs(candles[i].low - prevClose))
            )
        }
        guard n >= period else { return trueRanges }

        var seed = 0.0
        for i in 0..<period { seed += trueRanges[i] }
        var atr = seed / Double(period)
        for i in 0..<period { out[i] = atr }
        for i in period..<n {
            atr = (atr * Double(period - 1) + trueRanges[i]) / Double(period)
            out[i] = atr
        }
        return out
    }
}
