import SwiftUI
import Charts

/// Compact volume sub-chart rendered below the main price chart. Each bar
/// is coloured by candle direction (green if close ≥ open, red otherwise)
/// — the same convention TradingView and most exchange UIs use. Renders
/// nothing when every candle's volume is nil or zero, so non-ounce pairs
/// (which have no volume data) don't get an empty bar strip.
struct VolumeBarsView: View {
    let candles: [Candle]
    let accent: Color
    /// Same X window the price chart is rendering, expressed as bar
    /// indices (Double). Keeps the two charts horizontally aligned when
    /// the user pans or zooms — both views render against an index-based
    /// X axis so calendar gaps (weekends) never open spaces between bars.
    let xDomain: ClosedRange<Double>?

    /// True when at least one candle has measurable volume. Memoized
    /// to avoid O(n) scan on every body evaluation. Invalidated when
    /// candle count changes (new data arrives).
    ///
    /// Uses a class box instead of `@State` to avoid "Modifying state
    /// during view update" warnings — this computed property is called
    /// from `body` and the parent's gating check.
    private final class VolumeCache {
        var lastCount: Int = -1
        var result: Bool = false
    }
    private let _cacheBox = VolumeCache()
    var hasVolume: Bool {
        let n = candles.count
        if _cacheBox.lastCount == n { return _cacheBox.result }
        let v = candles.contains { ($0.volume ?? 0) > 0 }
        _cacheBox.lastCount = n
        _cacheBox.result = v
        return v
    }

    var body: some View {
        Chart {
            ForEach(
                ChartWindow.dayBoundaryPositions(candles: candles, domain: effectiveDomain),
                id: \.self
            ) { x in
                RuleMark(x: .value("Day boundary", x))
                    .foregroundStyle(Theme.Color.textMuted.opacity(0.20))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }

            ForEach(ChartWindow.renderIndices(domain: effectiveDomain, count: candles.count), id: \.self) { i in
                let c = candles[i]
                BarMark(
                    x: .value("Bar", Double(i)),
                    y: .value("Volume", c.volume ?? 0)
                )
                .foregroundStyle(barColor(c).opacity(0.75))
            }
        }
        .chartXScale(domain: effectiveDomain)
        .chartYAxis {
            // Compact "K/M/B" labels matching the main chart's style. Two
            // marks is plenty for a strip this thin.
            AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { value in
                AxisGridLine()
                    .foregroundStyle(Theme.Color.border)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Self.compact(v))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.Color.textMuted)
                    }
                }
            }
        }
        .chartXAxis(.hidden) // the main chart's X axis already labels this range
        // Match the price chart: clip marks to the frame so panned bars
        // can't render outside the card.
        .clipped()
    }

    // ── Helpers ───────────────────────────────────────────────────────
    /// Mirrors ChartView's resolution: caller-supplied window, falling
    /// back to the full bar span with half-bar padding on each side.
    private var effectiveDomain: ClosedRange<Double> {
        if let d = xDomain { return d }
        return ChartWindow.defaultDomain(count: candles.count)
    }

    private func barColor(_ c: Candle) -> Color {
        c.close >= c.open ? Theme.Color.success : Theme.Color.danger
    }

    /// Same K/M/B formatter the main chart uses for its Y axis. Inlined
    /// here so this view stays decoupled from ChartView.
    private static func compact(_ v: Double) -> String {
        let abs = Swift.abs(v)
        switch abs {
        case 1_000_000_000...:
            return "\((v / 1_000_000_000).formatted(.number.precision(.fractionLength(1))))B"
        case 1_000_000...:
            return "\((v / 1_000_000).formatted(.number.precision(.fractionLength(1))))M"
        case 1_000...:
            return "\((v / 1_000).formatted(.number.precision(.fractionLength(1))))K"
        default:
            return v.formatted(.number.precision(.fractionLength(0)))
        }
    }
}

/// See `ChartView`'s `Equatable` note — same rationale, scoped to the
/// volume strip. Wrapped in `.equatable()` at the call sites so an
/// unrelated parent re-render (a live tick that only moved the price
/// capsule, a sibling pane updating) doesn't re-lay-out this Chart when
/// its own inputs are unchanged.
extension VolumeBarsView: Equatable {
    static func == (l: VolumeBarsView, r: VolumeBarsView) -> Bool {
        Candle.seriesEqual(l.candles, r.candles)
            && l.accent == r.accent
            && l.xDomain == r.xDomain
    }
}
