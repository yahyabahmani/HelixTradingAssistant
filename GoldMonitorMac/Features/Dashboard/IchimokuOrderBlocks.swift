import Foundation

/// Ichimoku-confluence Order Blocks.
///
/// An order block on its own is just "the last opposing candle before an
/// impulsive move". This detector takes those base zones (via the shared
/// `OrderBlocks` engine) and keeps only the ones that line up with the
/// Ichimoku picture at the originating bar — the confluence that makes a
/// zone worth resting a limit order at:
///   • the zone overlaps the Kijun-sen (equilibrium / mean-reversion),
///   • the zone overlaps the Tenkan-sen (faster equilibrium),
///   • the zone overlaps the Kumo (cloud support/resistance),
///   • the block agrees with the cloud trend (bullish OB below/at a
///     bullish cloud that price sits above; bearish OB the mirror).
/// Each satisfied condition is +1 to `confluenceScore`; zones below
/// `minScore` are dropped.
///
/// Pure-function, no state — `ChartView` maps the result into
/// `RectangleMark`s like the other order-block overlays.
enum IchimokuOrderBlocks {
    struct Zone: Identifiable, Hashable {
        let index: Int
        let high: Double
        let low: Double
        let isBullish: Bool
        let status: OrderBlocks.ExhaustionStatus
        let testCount: Int
        /// 0…4 — how many Ichimoku conditions the zone satisfied.
        let confluenceScore: Int
        /// Short human tags for the satisfied conditions ("Kijun",
        /// "Kumo", …), surfaced in the zone's label.
        let reasons: [String]

        var avg: Double { (high + low) / 2 }
        var id: String { "\(index)-\(isBullish ? "bull" : "bear")" }
    }

    /// Do the price ranges `[aLow, aHigh]` and `[bLow, bHigh]` overlap?
    private static func overlaps(_ aLow: Double, _ aHigh: Double, _ bLow: Double, _ bHigh: Double) -> Bool {
        aLow <= bHigh && aHigh >= bLow
    }

    /// Does the zone touch the single level `level` (within its band)?
    private static func touches(_ zoneLow: Double, _ zoneHigh: Double, _ level: Double?) -> Bool {
        guard let level else { return false }
        return level >= zoneLow && level <= zoneHigh
    }

    static func compute(
        _ candles: [Candle],
        periods: Int,
        threshold: Double,
        useWicks: Bool,
        tenkan tenkanP: Int,
        kijun kijunP: Int,
        senkouB senkouBP: Int,
        displacement: Int,
        minScore: Int,
        requireTrendAgreement: Bool
    ) -> [Zone] {
        let base = OrderBlocks.compute(
            candles,
            periods: periods,
            threshold: threshold,
            useWicks: useWicks
        )
        guard !base.isEmpty else { return [] }

        let snaps = Ichimoku.snapshots(
            candles,
            tenkan: tenkanP,
            kijun: kijunP,
            senkouB: senkouBP,
            displacement: displacement
        )

        var out: [Zone] = []
        for z in base {
            guard snaps.indices.contains(z.index) else { continue }
            let s = snaps[z.index]

            var score = 0
            var reasons: [String] = []

            if touches(z.low, z.high, s.kijun) { score += 1; reasons.append("Kijun") }
            if touches(z.low, z.high, s.tenkan) { score += 1; reasons.append("Tenkan") }
            if let top = s.cloudTop, let bottom = s.cloudBottom,
               overlaps(z.low, z.high, bottom, top) {
                score += 1
                reasons.append("Kumo")
            }

            // Trend agreement: a bullish OB wants a bullish cloud with the
            // block sitting at or below the cloud top (demand under price);
            // a bearish OB wants a bearish cloud with the block at or above
            // the cloud bottom (supply over price).
            var trendAgrees = false
            if let top = s.cloudTop, let bottom = s.cloudBottom {
                if z.isBullish, s.cloudBullish, z.low <= top {
                    trendAgrees = true
                } else if !z.isBullish, !s.cloudBullish, z.high >= bottom {
                    trendAgrees = true
                }
            }
            if trendAgrees { score += 1; reasons.append("Trend") }

            if requireTrendAgreement && !trendAgrees { continue }
            guard score >= minScore else { continue }

            out.append(Zone(
                index: z.index,
                high: z.high,
                low: z.low,
                isBullish: z.isBullish,
                status: z.status,
                testCount: z.testCount,
                confluenceScore: score,
                reasons: reasons
            ))
        }
        return out
    }
}
