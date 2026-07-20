import Foundation

/// Volume-Filtered Order Block Detector.
///
/// A port of Mehdi Pirhayati's PineScript v6 indicator. Order blocks are
/// anchored to one-sided swing pivots (a bar whose high/low is the extreme
/// of the following `swingLength` bars). When price then closes through the
/// swing level, the origin candle of the move — the lowest-low bar (bullish)
/// or highest-high bar (bearish) between the swing and the break — becomes
/// the block. Each block carries the breakout's volume split into an
/// "up" and "down" share so the renderer can draw the volumetric bar and a
/// balance percentage. Blocks larger than `maxATRMult` × ATR(10) are
/// rejected.
///
/// Blocks live through a breaker lifecycle: a bullish block turns into a
/// breaker when price trades below its bottom (by wick or close, per
/// `invalidationWick`), and is removed once price trades back above its top;
/// the bearish case mirrors. Overlapping same-direction blocks are optionally
/// merged. Pure-function, no rendering — `ChartView` maps `Zone`s into
/// `RectangleMark`s.
enum VolumeFilteredOrderBlocks {
    struct Zone: Identifiable, Hashable {
        /// The order-block candle.
        let startIndex: Int
        /// Right edge — the break bar for a breaker, else the last bar.
        let endIndex: Int
        let top: Double
        let bottom: Double
        let isBullish: Bool
        /// Combined breakout volume and its up/down split.
        let volume: Double
        let highVolume: Double
        let lowVolume: Double
        /// True once price invalidated the block (kept as a "historic" zone).
        let breaker: Bool
        /// True when this zone is the merge of ≥2 overlapping blocks.
        let combined: Bool

        var id: String { "\(startIndex)-\(isBullish ? "bull" : "bear")-\(Int(top * 100))" }

        /// Balance between the two volume shares, 0…100 (Pine's percentage).
        var balancePct: Int {
            guard highVolume > 0, lowVolume > 0 else { return 0 }
            return Int((min(highVolume, lowVolume) / max(highVolume, lowVolume)) * 100.0)
        }
    }

    struct Output: Hashable {
        var zones: [Zone]
        static let empty = Output(zones: [])
    }

    /// Pine caps detection to the most recent bars for performance.
    private static let maxDistanceToLastBar = 1750
    private static let maxStored = 30

    static func compute(
        _ candles: [Candle],
        swingLength: Int,
        invalidationWick: Bool,     // obEndMethod == "Wick"
        maxZonesPerSide: Int,       // from zoneCount
        showHistoric: Bool,
        combine: Bool,
        maxATRMult: Double = 3.5
    ) -> Output {
        let n = candles.count
        let len = max(1, swingLength)
        guard n > 0 else { return .empty }

        let atr = atr10(candles)
        let lastIndex = n - 1

        struct WorkOB {
            var startIndex: Int
            var top: Double
            var bottom: Double
            let isBullish: Bool
            var volume: Double
            var highVolume: Double
            var lowVolume: Double
            var breaker: Bool = false
            var breakIndex: Int? = nil
            var combined: Bool = false
        }

        var bull: [WorkOB] = []
        var bear: [WorkOB] = []

        // Swing state (one-sided pivots, right length `len`).
        var swingType = 0
        var topX: Int? = nil, topY: Double? = nil, topCrossed = false
        var btmX: Int? = nil, btmY: Double? = nil, btmCrossed = false

        func vol(_ i: Int) -> Double { i >= 0 && i < n ? (candles[i].volume ?? 0) : 0 }

        let windowStart = max(0, n - maxDistanceToLastBar)
        for i in windowStart..<n {
            let c = candles[i]

            // ── Swing detection ──
            if i - len >= 0 {
                var upper = -Double.greatestFiniteMagnitude
                var lower = Double.greatestFiniteMagnitude
                for k in (i - len + 1)...i {
                    upper = max(upper, candles[k].high)
                    lower = min(lower, candles[k].low)
                }
                let hLen = candles[i - len].high
                let lLen = candles[i - len].low
                let prev = swingType
                swingType = hLen > upper ? 0 : (lLen < lower ? 1 : swingType)
                if swingType == 0, prev != 0 {
                    topX = i - len; topY = hLen; topCrossed = false
                }
                if swingType == 1, prev != 1 {
                    btmX = i - len; btmY = lLen; btmCrossed = false
                }
            }

            // ── Bullish breaker lifecycle ──
            var idx = bull.count - 1
            while idx >= 0 {
                if !bull[idx].breaker {
                    let px = invalidationWick ? c.low : min(c.open, c.close)
                    if px < bull[idx].bottom {
                        bull[idx].breaker = true
                        bull[idx].breakIndex = i
                    }
                } else if c.high > bull[idx].top {
                    bull.remove(at: idx)
                }
                idx -= 1
            }

            // ── Bullish creation ──
            if let ty = topY, let tx = topX, !topCrossed, c.close > ty {
                topCrossed = true
                let barsBack = i - tx
                var boxBtm = i - 1 >= 0 ? candles[i - 1].high : c.high
                var boxTop = i - 1 >= 0 ? candles[i - 1].low : c.low
                var boxLoc = max(0, i - 1)
                if barsBack > 1 {
                    for k in 1...(barsBack - 1) where i - k >= 0 {
                        let lowK = candles[i - k].low
                        let newBtm = min(lowK, boxBtm)
                        if newBtm == lowK {
                            boxTop = candles[i - k].high
                            boxLoc = i - k
                        }
                        boxBtm = newBtm
                    }
                }
                if let a = atr[i], abs(boxTop - boxBtm) <= a * maxATRMult {
                    bull.insert(WorkOB(
                        startIndex: boxLoc, top: boxTop, bottom: boxBtm, isBullish: true,
                        volume: vol(i) + vol(i - 1) + vol(i - 2),
                        highVolume: vol(i) + vol(i - 1),
                        lowVolume: vol(i - 2)
                    ), at: 0)
                    if bull.count > maxStored { bull.removeLast() }
                }
            }

            // ── Bearish breaker lifecycle ──
            idx = bear.count - 1
            while idx >= 0 {
                if !bear[idx].breaker {
                    let px = invalidationWick ? c.high : max(c.open, c.close)
                    if px > bear[idx].top {
                        bear[idx].breaker = true
                        bear[idx].breakIndex = i
                    }
                } else if c.low < bear[idx].bottom {
                    bear.remove(at: idx)
                }
                idx -= 1
            }

            // ── Bearish creation ──
            if let by = btmY, let bx = btmX, !btmCrossed, c.close < by {
                btmCrossed = true
                let barsBack = i - bx
                var boxBtm = i - 1 >= 0 ? candles[i - 1].low : c.low
                var boxTop = i - 1 >= 0 ? candles[i - 1].high : c.high
                var boxLoc = max(0, i - 1)
                if barsBack > 1 {
                    for k in 1...(barsBack - 1) where i - k >= 0 {
                        let highK = candles[i - k].high
                        let newTop = max(highK, boxTop)
                        if newTop == highK {
                            boxBtm = candles[i - k].low
                            boxLoc = i - k
                        }
                        boxTop = newTop
                    }
                }
                if let a = atr[i], abs(boxTop - boxBtm) <= a * maxATRMult {
                    bear.insert(WorkOB(
                        startIndex: boxLoc, top: boxTop, bottom: boxBtm, isBullish: false,
                        volume: vol(i) + vol(i - 1) + vol(i - 2),
                        highVolume: vol(i - 2),
                        lowVolume: vol(i) + vol(i - 1)
                    ), at: 0)
                    if bear.count > maxStored { bear.removeLast() }
                }
            }
        }

        // Keep only the most recent N per side, then optionally merge.
        var selected = Array(bull.prefix(max(0, maxZonesPerSide)))
                     + Array(bear.prefix(max(0, maxZonesPerSide)))
        if combine {
            selected = combineZones(selected, lastIndex: lastIndex)
        }

        var zones: [Zone] = []
        zones.reserveCapacity(selected.count)
        for ob in selected where showHistoric || !ob.breaker {
            zones.append(Zone(
                startIndex: ob.startIndex,
                endIndex: ob.breakIndex ?? lastIndex,
                top: ob.top, bottom: ob.bottom, isBullish: ob.isBullish,
                volume: ob.volume, highVolume: ob.highVolume, lowVolume: ob.lowVolume,
                breaker: ob.breaker, combined: ob.combined
            ))
        }
        return Output(zones: zones)

        // MARK: nested

        func combineZones(_ input: [WorkOB], lastIndex: Int) -> [WorkOB] {
            var list = input
            func endX(_ o: WorkOB) -> Int { o.breakIndex ?? (lastIndex + 1) }
            var changed = true
            while changed {
                changed = false
                outer: for a in 0..<list.count {
                    for b in 0..<list.count where a != b {
                        guard list[a].isBullish == list[b].isBullish else { continue }
                        // Box-overlap test (both x and y must intersect).
                        let ix = min(endX(list[a]), endX(list[b])) - max(list[a].startIndex, list[b].startIndex)
                        let iy = min(list[a].top, list[b].top) - max(list[a].bottom, list[b].bottom)
                        if ix > 0, iy > 0 {
                            var merged = WorkOB(
                                startIndex: min(list[a].startIndex, list[b].startIndex),
                                top: max(list[a].top, list[b].top),
                                bottom: min(list[a].bottom, list[b].bottom),
                                isBullish: list[a].isBullish,
                                volume: list[a].volume + list[b].volume,
                                highVolume: list[a].highVolume + list[b].highVolume,
                                lowVolume: list[a].lowVolume + list[b].lowVolume,
                                breaker: list[a].breaker || list[b].breaker,
                                combined: true
                            )
                            let bi = max(list[a].breakIndex ?? 0, list[b].breakIndex ?? 0)
                            merged.breakIndex = bi == 0 ? nil : bi
                            // Remove the two originals (higher index first).
                            let hi = max(a, b), lo = min(a, b)
                            list.remove(at: hi)
                            list.remove(at: lo)
                            list.insert(merged, at: 0)
                            changed = true
                            break outer
                        }
                    }
                }
            }
            return list
        }
    }

    /// Wilder's ATR(10) — `nil` until 10 bars of history exist.
    private static func atr10(_ candles: [Candle]) -> [Double?] {
        let n = candles.count
        let length = 10
        var out = [Double?](repeating: nil, count: n)
        guard n >= length else { return out }
        var tr = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let h = candles[i].high, l = candles[i].low
            if i == 0 { tr[i] = h - l }
            else {
                let pc = candles[i - 1].close
                tr[i] = max(h - l, max(abs(h - pc), abs(l - pc)))
            }
        }
        var sum = 0.0
        for i in 0..<length { sum += tr[i] }
        var prev = sum / Double(length)
        out[length - 1] = prev
        for i in length..<n {
            prev = (prev * Double(length - 1) + tr[i]) / Double(length)
            out[i] = prev
        }
        return out
    }
}
