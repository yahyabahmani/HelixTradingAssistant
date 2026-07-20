import SwiftUI
import Charts

/// One oscillator rendered as a thin sub-chart underneath the price
/// chart. Each kind has its own Y scale (0-100 for RSI/Stoch, auto for
/// MACD) and per-kind reference lines (overbought / oversold for RSI &
/// Stochastic; zero baseline for MACD).
///
/// X axis is hidden — the main chart's X axis labels the time for the
/// whole stack via shared `xDomain`.
struct OscillatorPanel: View {
    let instance: OscillatorInstance
    let candles: [Candle]
    /// Same bar-index domain the price chart uses; lets pan/zoom on the
    /// price chart move this panel in lock-step.
    let xDomain: ClosedRange<Double>?

    /// Memoizes this panel's oscillator computation so a pan/zoom (which
    /// only changes `xDomain`) doesn't re-run RSI/MACD/Stoch over the
    /// full history every frame, and runs the recompute on a background
    /// `Task` so it never blocks the UI. `@StateObject` so a background
    /// task's `objectWillChange` actually triggers a redraw. See
    /// `ChartDerivedCache`.
    @StateObject private var derived = ChartDerivedCache()

    var body: some View {
        // Compute visible points ONCE — both `marks` and `yDomain`
        // previously triggered independent `visiblePoints` evaluations,
        // each building a fresh `Set(renderIndices)`.
        let pts = visiblePoints
        let domain = effectiveDomain
        let yDom = yDomainForPoints(pts)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(instance.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                Spacer()
                latestReadout
            }
            Chart {
                ForEach(
                    ChartWindow.dayBoundaryPositions(candles: candles, domain: domain),
                    id: \.self
                ) { x in
                    RuleMark(x: .value("Day boundary", x))
                        .foregroundStyle(Theme.Color.textMuted.opacity(0.20))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }

                marks(pts: pts)
                referenceLines
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: yDom)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: yAxisValues(for: yDom)) { value in
                    AxisGridLine().foregroundStyle(Theme.Color.border.opacity(0.5))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(yLabel(v))
                                .font(.system(size: 8, weight: .medium).monospacedDigit())
                                .foregroundStyle(Theme.Color.textMuted)
                        }
                    }
                }
            }
            .frame(height: 90)
            .clipped()
        }
    }

    // MARK: - Marks dispatch

    @ChartContentBuilder
    private func marks(pts: [IndicatorPoint]) -> some ChartContent {
        switch instance.kind {
        case .rsi:
            ForEach(pts) { p in
                LineMark(
                    x: .value("Bar", Double(p.index)),
                    y: .value("RSI", p.value),
                    series: .value("Series", "rsi")
                )
                .foregroundStyle(rsiColor)
                .lineStyle(StrokeStyle(lineWidth: 1.4))
                .interpolationMethod(.monotone)
            }
        case .macd:
            ForEach(pts) { p in
                if p.band == "histogram" {
                    BarMark(
                        x: .value("Bar", Double(p.index)),
                        y: .value("Hist", p.value)
                    )
                    .foregroundStyle((p.value >= 0
                                       ? Theme.Color.success
                                       : Theme.Color.danger).opacity(0.6))
                } else {
                    LineMark(
                        x: .value("Bar", Double(p.index)),
                        y: .value("MACD", p.value),
                        series: .value("Series", p.band)
                    )
                    .foregroundStyle(p.band == "macd" ? macdLineColor : signalColor)
                    .lineStyle(StrokeStyle(lineWidth: p.band == "macd" ? 1.4 : 1.2))
                    .interpolationMethod(.monotone)
                }
            }
        case .stochastic:
            ForEach(pts) { p in
                LineMark(
                    x: .value("Bar", Double(p.index)),
                    y: .value("%", p.value),
                    series: .value("Series", p.band)
                )
                .foregroundStyle(p.band == "k" ? stochKColor : stochDColor)
                .lineStyle(StrokeStyle(lineWidth: p.band == "k" ? 1.4 : 1.2))
                .interpolationMethod(.monotone)
            }
        }
    }

    /// Horizontal reference lines specific to each oscillator. RSI uses
    /// 30/70 (oversold/overbought), Stochastic uses 20/80, MACD uses 0.
    @ChartContentBuilder
    private var referenceLines: some ChartContent {
        switch instance.kind {
        case .rsi:
            RuleMark(y: .value("Overbought", 70))
                .foregroundStyle(Theme.Color.danger.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
            RuleMark(y: .value("Oversold", 30))
                .foregroundStyle(Theme.Color.success.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
        case .stochastic:
            RuleMark(y: .value("Overbought", 80))
                .foregroundStyle(Theme.Color.danger.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
            RuleMark(y: .value("Oversold", 20))
                .foregroundStyle(Theme.Color.success.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
        case .macd:
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(Theme.Color.border.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 0.6))
        }
    }

    // MARK: - Latest readout (top-right label)

    /// Shows the most recent value(s) of the oscillator so the user can
    /// read them without hovering. RSI/Stoch are bounded — print as
    /// rounded ints. MACD prints as a 2-decimal float.
    @ViewBuilder
    private var latestReadout: some View {
        let pts = computedPoints
        switch instance.kind {
        case .rsi:
            if let last = pts.last {
                Text(String(format: "%.1f", last.value))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(rsiColor)
            }
        case .macd:
            if let macd = pts.last(where: { $0.band == "macd" }),
               let sig  = pts.last(where: { $0.band == "signal" }) {
                HStack(spacing: 8) {
                    label("MACD", String(format: "%.2f", macd.value), color: macdLineColor)
                    label("SIG",  String(format: "%.2f", sig.value),  color: signalColor)
                }
            }
        case .stochastic:
            if let k = pts.last(where: { $0.band == "k" }),
               let d = pts.last(where: { $0.band == "d" }) {
                HStack(spacing: 8) {
                    label("%K", String(format: "%.1f", k.value), color: stochKColor)
                    label("%D", String(format: "%.1f", d.value), color: stochDColor)
                }
            }
        }
    }

    private func label(_ key: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.Color.textMuted)
            Text(value)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
        }
    }

    // MARK: - Compute

    /// Memoized oscillator series. Cached against the candle data +
    /// config so repeated reads within a frame (marks, yDomain, readout)
    /// and across pan/zoom frames reuse one computation instead of
    /// re-running it over the full history each time.
    private var computedPoints: [IndicatorPoint] {
        derived.oscillatorPoints(kind: instance.kind, candles: candles, config: oscillatorConfigFromParams(instance.params))
    }

    /// Build an OscillatorConfig from per-instance params for the cache
    /// to use (the shared cache slot already keys on the individual
    /// int fields, so the extra config fields are harmless).
    private func oscillatorConfigFromParams(_ params: [String: ParamValue]) -> OscillatorConfig {
        var c = OscillatorConfig()
        if let v = params["period"] { c.rsiPeriod = Int(v.doubleValue); c.stochK = Int(v.doubleValue) }
        if let v = params["fast"]   { c.macdFast = Int(v.doubleValue) }
        if let v = params["slow"]   { c.macdSlow = Int(v.doubleValue) }
        if let v = params["signal"] { c.macdSignal = Int(v.doubleValue) }
        if let v = params["k"]      { c.stochK = Int(v.doubleValue) }
        if let v = params["d"]      { c.stochD = Int(v.doubleValue) }
        return c
    }

    // ── Visible-points memoization ───────────────────────────────────
    //
    // `visiblePoints` filters `computedPoints` to the visible bar
    // window. Previously it rebuilt a `Set<Int>` from
    // `renderIndices` + filtered the full array on every body eval.
    // In grid mode with 4 panes × 2 oscillators = 8 calls per tick,
    // that's 8 Set allocations + 8 full-array filters per frame.
    //
    // Cache keyed on (domain bounds, candle count, computed count).
    // During pan/zoom only the domain changes — the Set rebuild is
    // still O(visible bars), but the filter is skipped when the
    // domain is unchanged (e.g. on a tick where no new bar arrived).

    private struct VisiblePointsCache {
        let domainLo: Double
        let domainHi: Double
        let candleCount: Int
        let computedCount: Int
        let points: [IndicatorPoint]
    }
    /// Class box to avoid "Modifying state during view update" —
    /// `visiblePoints` is a computed property called from `body`.
    private final class VisiblePointsCacheBox {
        var cached: VisiblePointsCache?
    }
    private let _vpCacheBox = VisiblePointsCacheBox()

    /// computedPoints restricted to the bar indices actually rendered
    /// this frame — keeps mark count bounded on deep history, matching
    /// the price chart's windowing. Latest-value readouts still read the
    /// full series so they never go stale when zoomed in.
    private var visiblePoints: [IndicatorPoint] {
        let domain = effectiveDomain
        let computed = computedPoints
        let cacheKey = VisiblePointsCache(
            domainLo: domain.lowerBound,
            domainHi: domain.upperBound,
            candleCount: candles.count,
            computedCount: computed.count,
            points: []
        )
        if let cached = _vpCacheBox.cached,
           cached.domainLo == cacheKey.domainLo,
           cached.domainHi == cacheKey.domainHi,
           cached.candleCount == cacheKey.candleCount,
           cached.computedCount == cacheKey.computedCount {
            return cached.points
        }
        let set = Set(ChartWindow.renderIndices(domain: domain, count: candles.count))
        let result = computed.filter { set.contains($0.index) }
        _vpCacheBox.cached = VisiblePointsCache(
            domainLo: cacheKey.domainLo,
            domainHi: cacheKey.domainHi,
            candleCount: cacheKey.candleCount,
            computedCount: cacheKey.computedCount,
            points: result
        )
        return result
    }

    // MARK: - Scales

    private var effectiveDomain: ClosedRange<Double> {
        if let d = xDomain { return d }
        return ChartWindow.defaultDomain(count: candles.count)
    }

    private func yDomainForPoints(_ pts: [IndicatorPoint]) -> ClosedRange<Double> {
        switch instance.kind {
        case .rsi, .stochastic:
            return 0 ... 100
        case .macd:
            let values = pts.map(\.value)
            let lo = values.min() ?? -1
            let hi = values.max() ?? 1
            let span = max(hi - lo, 0.001)
            let pad = span * 0.1
            return (lo - pad) ... (hi + pad)
        }
    }

    private func yAxisValues(for yDom: ClosedRange<Double>) -> [Double] {
        switch instance.kind {
        case .rsi:        return [30, 50, 70]
        case .stochastic: return [20, 50, 80]
        case .macd:       return [yDom.lowerBound, 0, yDom.upperBound]
        }
    }

    private func yLabel(_ v: Double) -> String {
        switch instance.kind {
        case .rsi, .stochastic:
            return String(format: "%.0f", v)
        case .macd:
            return String(format: "%.2f", v)
        }
    }

    // MARK: - Colors

    private var rsiColor:    Color { Color(red: 1.00, green: 0.78, blue: 0.20) }
    private var macdLineColor: Color { Color(red: 0.38, green: 0.65, blue: 1.00) }
    private var signalColor:   Color { Color(red: 1.00, green: 0.45, blue: 0.65) }
    private var stochKColor:   Color { Color(red: 0.38, green: 0.65, blue: 1.00) }
    private var stochDColor:   Color { Color(red: 1.00, green: 0.45, blue: 0.65) }
}

/// See `ChartView`'s `Equatable` note — same rationale, scoped to one
/// oscillator sub-chart. In grid mode each pane can stack several of
/// these, so gating their re-layout on actual input changes (not on every
/// live tick that ripples through the pane) is a big part of the
/// split-screen win. The oscillator math itself is already memoized by
/// this view's own `ChartDerivedCache`; this stops the Charts *layout*
/// pass from running needlessly on top of that.
extension OscillatorPanel: Equatable {
    static func == (l: OscillatorPanel, r: OscillatorPanel) -> Bool {
        l.instance == r.instance
            && Candle.seriesEqual(l.candles, r.candles)
            && l.xDomain == r.xDomain
    }
}
