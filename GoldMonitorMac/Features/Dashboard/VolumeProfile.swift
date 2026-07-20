import Foundation

/// Volume Profile indicator: builds a volume histogram over a bar range
/// and identifies POC / VAH / VAL plus ranked high-volume levels.
///
/// Three modes share one histogram implementation (`buildCore`):
///   • `compute`              — per-session profiles, one per CME-style
///                              *trading day* (18:00 ET → 17:00 ET next
///                              day, anchored to New York time so every
///                              user sees identical profiles).
///   • `computeLastTrend`     — a single profile over the last ZigZag
///                              trend segment.
///   • `computeVisibleRange`  — a profile over the bars currently in
///                              view, plus the top-N high-volume nodes
///                              extracted as price levels.
///
/// Each range's price span is divided into `bucketCount` equal bands;
/// each candle's typical price `(H+L+C)/3` decides which bucket its
/// volume lands in. Buckets also track the up/down split (close ≥ open
/// vs close < open) so renderers can draw two-tone bars. Candles with
/// nil/zero volume fall back to 1, so pairs without volume data still
/// produce a (TPO-style, time-at-price) profile — `hasRealVolume` tells
/// the renderer that happened.
enum VolumeProfile {

    /// One price-level bucket in a volume histogram.
    struct Bucket: Hashable {
        /// Lower edge of this price band.
        let priceLevel: Double
        /// Total volume in the band.
        let volume: Double
        /// Volume from candles that closed up (close ≥ open).
        let upVolume: Double
        /// Volume from candles that closed down (close < open).
        let downVolume: Double
    }

    /// A high-volume level extracted from a profile — a price that
    /// carried an outsized share of the range's volume.
    struct Level: Hashable {
        /// Bucket-centre price of the level.
        let price: Double
        let volume: Double
        /// 0…1 — this level's volume relative to the strongest one.
        let strength: Double
        /// True for the single strongest level (the POC).
        let isPOC: Bool
    }

    /// One trading session's volume profile.
    struct SessionVP: Identifiable, Hashable {
        /// Session index within the input series (stable across appends).
        let id: Int
        /// Bar indices (into the input candle array) of the first & last
        /// candle in this session.
        let startBar: Int
        let endBar: Int
        /// Height of one histogram bucket in price units.
        let bucketSize: Double
        /// Bucket indices for POC and the value-area edges — renderers
        /// use these instead of float-comparing prices.
        let pocIndex: Int
        let vaLowIndex: Int
        let vaHighIndex: Int
        /// Point of Control — centre of the highest-volume bucket.
        let poc: Double
        /// Value Area High / Low (default ~70% of volume around the POC).
        let vah: Double
        let val: Double
        /// False when every candle lacked volume data (profile is
        /// time-at-price, not true volume).
        let hasRealVolume: Bool
        let buckets: [Bucket]
    }

    /// A single trend-based volume profile (the last ZigZag segment).
    struct TrendVP: Hashable {
        let bucketSize: Double
        let pocIndex: Int
        let vaLowIndex: Int
        let vaHighIndex: Int
        let poc: Double
        let vah: Double
        let val: Double
        let hasRealVolume: Bool
        let buckets: [Bucket]
        /// Bar indices where the trend segment starts and ends.
        let startBar: Int
        let endBar: Int
        /// Whether the trend is bullish (swing-low → swing-high).
        let isBullish: Bool
    }

    /// A visible-range volume profile with ranked high-volume levels.
    struct VisibleRangeVP: Hashable {
        let startBar: Int
        let endBar: Int
        let bucketSize: Double
        let pocIndex: Int
        let vaLowIndex: Int
        let vaHighIndex: Int
        let poc: Double
        let vah: Double
        let val: Double
        let hasRealVolume: Bool
        let buckets: [Bucket]
        /// Ranked high-volume nodes, strongest first. Levels are at
        /// least 2 buckets apart so they mark distinct nodes.
        let levels: [Level]
    }

    // MARK: - Shared histogram builder

    /// Everything a profile needs except its bar span — the single
    /// implementation behind all three modes.
    private struct Core {
        let buckets: [Bucket]
        let bucketSize: Double
        let pocIndex: Int
        let vaLowIndex: Int
        let vaHighIndex: Int
        let hasRealVolume: Bool

        /// Lower price edge of bucket 0.
        var base: Double { buckets[0].priceLevel }
        /// POC is the bucket *centre*, not its lower edge.
        var poc: Double { base + (Double(pocIndex) + 0.5) * bucketSize }
        var val: Double { base + Double(vaLowIndex) * bucketSize }
        var vah: Double { base + Double(vaHighIndex + 1) * bucketSize }
    }

    /// Build the histogram + POC + value area for one bar segment.
    private static func buildCore(
        _ segment: ArraySlice<Candle>,
        bucketCount: Int,
        valueAreaPct: Double
    ) -> Core? {
        guard !segment.isEmpty, bucketCount >= 2 else { return nil }

        // Single pass for the price range + volume-presence flag.
        var priceMin = Double.greatestFiniteMagnitude
        var priceMax = -Double.greatestFiniteMagnitude
        var hasRealVolume = false
        for c in segment {
            if c.low < priceMin { priceMin = c.low }
            if c.high > priceMax { priceMax = c.high }
            if (c.volume ?? 0) > 0 { hasRealVolume = true }
        }
        guard priceMax > priceMin else { return nil }

        let bucketSize = (priceMax - priceMin) / Double(bucketCount)
        var volumes = [Double](repeating: 0, count: bucketCount)
        var upVolumes = [Double](repeating: 0, count: bucketCount)
        var totalVol: Double = 0

        for c in segment {
            let typical = (c.high + c.low + c.close) / 3
            let idx = min(bucketCount - 1, Int((typical - priceMin) / bucketSize))
            let vol = c.volume.flatMap { $0 > 0 ? $0 : nil } ?? 1
            volumes[idx] += vol
            if c.close >= c.open { upVolumes[idx] += vol }
            totalVol += vol
        }

        let maxVol = volumes.max() ?? 1
        let pocIdx = volumes.firstIndex(of: maxVol) ?? 0

        // Value area: expand outward from the POC toward the heavier
        // side until cumulative volume reaches the threshold. The
        // `canGo` guards make the walk total — a pct of 100 (or float
        // rounding that leaves cumVol a hair under the threshold once
        // every bucket is included) terminates instead of indexing past
        // the array edges.
        let clampedPct = min(max(valueAreaPct, 0), 100)
        let vaThreshold = totalVol * clampedPct / 100.0
        var cumVol = volumes[pocIdx]
        var loIdx = pocIdx
        var hiIdx = pocIdx
        while cumVol < vaThreshold {
            let canGoLow = loIdx > 0
            let canGoHigh = hiIdx < bucketCount - 1
            guard canGoLow || canGoHigh else { break }
            let leftVol = canGoLow ? volumes[loIdx - 1] : -Double.infinity
            let rightVol = canGoHigh ? volumes[hiIdx + 1] : -Double.infinity
            if leftVol >= rightVol {
                loIdx -= 1
                cumVol += volumes[loIdx]
            } else {
                hiIdx += 1
                cumVol += volumes[hiIdx]
            }
        }

        let buckets: [Bucket] = (0..<bucketCount).map { i in
            Bucket(
                priceLevel: priceMin + Double(i) * bucketSize,
                volume: volumes[i],
                upVolume: upVolumes[i],
                downVolume: volumes[i] - upVolumes[i]
            )
        }
        return Core(
            buckets: buckets,
            bucketSize: bucketSize,
            pocIndex: pocIdx,
            vaLowIndex: loIdx,
            vaHighIndex: hiIdx,
            hasRealVolume: hasRealVolume
        )
    }

    // MARK: - Session mode (trading-day profiles)

    /// Sessions are CME-style *trading days* anchored to New York time:
    /// the 18:00 ET evening open belongs to the next calendar day. This
    /// matches `MarketCalendar`'s weekend/reopen convention and gives
    /// every user identical profiles regardless of their local timezone.
    private static let sessionCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return cal
    }()

    /// Trading-day bucket for a timestamp: +6h shifts the 18:00 ET
    /// session boundary onto midnight, so `startOfDay` groups the
    /// evening open with the following day.
    static func tradingDayStart(for date: Date) -> Date {
        sessionCalendar.startOfDay(for: date.addingTimeInterval(6 * 3600))
    }

    /// Compute volume profiles for the most recent trading sessions.
    ///
    /// - Parameters:
    ///   - candles:      Sorted OHLC candles (newest last).
    ///   - bucketCount:  Number of equal-price bands per session.
    ///   - valueAreaPct: % of total volume that defines the value area.
    ///   - maxSessions:  How many recent sessions to return. Only these
    ///                   are built — deep histories no longer compute
    ///                   hundreds of profiles that get thrown away.
    static func compute(
        _ candles: [Candle],
        bucketCount: Int = 24,
        valueAreaPct: Double = 70.0,
        maxSessions: Int = 5
    ) -> [SessionVP] {
        guard candles.count >= 2, bucketCount >= 2, maxSessions >= 1 else { return [] }

        // 1. Group bar ranges by trading day (dates only, no profile work).
        var ranges: [Range<Int>] = []
        var dayStart = tradingDayStart(for: candles[0].id)
        var sessionStart = 0
        for i in 1..<candles.count {
            let d = tradingDayStart(for: candles[i].id)
            if d != dayStart {
                ranges.append(sessionStart..<i)
                dayStart = d
                sessionStart = i
            }
        }
        ranges.append(sessionStart..<candles.count)

        // 2. Build profiles for the most recent sessions only.
        var results: [SessionVP] = []
        for (idx, range) in ranges.enumerated().suffix(maxSessions) {
            guard let core = buildCore(
                candles[range],
                bucketCount: bucketCount,
                valueAreaPct: valueAreaPct
            ) else { continue }
            results.append(SessionVP(
                id: idx,
                startBar: range.lowerBound,
                endBar: range.upperBound - 1,
                bucketSize: core.bucketSize,
                pocIndex: core.pocIndex,
                vaLowIndex: core.vaLowIndex,
                vaHighIndex: core.vaHighIndex,
                poc: core.poc,
                vah: core.vah,
                val: core.val,
                hasRealVolume: core.hasRealVolume,
                buckets: core.buckets
            ))
        }
        return results
    }

    // MARK: - ZigZag trend mode

    /// Compute a volume profile for the last ZigZag trend segment only.
    ///
    /// The histogram is built from the candles between the last two
    /// confirmed ZigZag pivots (i.e. the current active trend).
    static func computeLastTrend(
        _ candles: [Candle],
        bucketCount: Int = 24,
        valueAreaPct: Double = 70.0,
        zigzagDepth: Int = 5,
        zigzagMinChange: Double = 1.0
    ) -> TrendVP? {
        let pivots = ZigZag.compute(candles, depth: zigzagDepth, minChangePct: zigzagMinChange)
        guard pivots.count >= 2 else { return nil }

        // Last two pivots define the current trend.
        let p0 = pivots[pivots.count - 2]
        let p1 = pivots[pivots.count - 1]
        let segStart = min(p0.barIndex, p1.barIndex)
        let segEnd = max(p0.barIndex, p1.barIndex)
        guard segEnd > segStart, segEnd < candles.count else { return nil }

        guard let core = buildCore(
            candles[segStart...segEnd],
            bucketCount: bucketCount,
            valueAreaPct: valueAreaPct
        ) else { return nil }

        return TrendVP(
            bucketSize: core.bucketSize,
            pocIndex: core.pocIndex,
            vaLowIndex: core.vaLowIndex,
            vaHighIndex: core.vaHighIndex,
            poc: core.poc,
            vah: core.vah,
            val: core.val,
            hasRealVolume: core.hasRealVolume,
            buckets: core.buckets,
            startBar: segStart,
            endBar: segEnd,
            isBullish: p1.price > p0.price
        )
    }

    // MARK: - Visible-range mode (levels with volume)

    /// Compute a volume profile over a visible bar window and extract
    /// the top-N high-volume nodes as price levels.
    ///
    /// Level picking walks buckets from highest volume down, skipping
    /// any bucket adjacent to an already-picked one, so the levels land
    /// on distinct volume nodes instead of clustering on the POC's
    /// shoulders.
    static func computeVisibleRange(
        _ candles: [Candle],
        barRange: ClosedRange<Int>,
        bucketCount: Int = 48,
        valueAreaPct: Double = 70.0,
        levelCount: Int = 5
    ) -> VisibleRangeVP? {
        guard candles.count >= 2, bucketCount >= 2 else { return nil }
        let lo = max(0, barRange.lowerBound)
        let hi = min(candles.count - 1, barRange.upperBound)
        guard hi > lo else { return nil }

        guard let core = buildCore(
            candles[lo...hi],
            bucketCount: bucketCount,
            valueAreaPct: valueAreaPct
        ) else { return nil }

        let pocVolume = core.buckets[core.pocIndex].volume
        var picked: [Int] = []
        for (idx, bucket) in core.buckets.enumerated()
            .sorted(by: { $0.element.volume > $1.element.volume }) {
            guard picked.count < max(1, levelCount) else { break }
            guard bucket.volume > 0 else { break }
            if picked.contains(where: { abs($0 - idx) <= 1 }) { continue }
            picked.append(idx)
        }
        // Strongest first; the POC (max volume) is always picked first.
        let levels: [Level] = picked.map { idx in
            Level(
                price: core.base + (Double(idx) + 0.5) * core.bucketSize,
                volume: core.buckets[idx].volume,
                strength: pocVolume > 0 ? core.buckets[idx].volume / pocVolume : 0,
                isPOC: idx == core.pocIndex
            )
        }

        return VisibleRangeVP(
            startBar: lo,
            endBar: hi,
            bucketSize: core.bucketSize,
            pocIndex: core.pocIndex,
            vaLowIndex: core.vaLowIndex,
            vaHighIndex: core.vaHighIndex,
            poc: core.poc,
            vah: core.vah,
            val: core.val,
            hasRealVolume: core.hasRealVolume,
            buckets: core.buckets,
            levels: levels
        )
    }
}
