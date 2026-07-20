import SwiftUI
import Charts
import AppKit   // NSCursor for the price-axis resize affordance

/// Trading-style chart built on Apple's Charts framework.
///
/// What it shows:
///   • OHLC candles or a smoothed line of closes (caller's choice).
///   • A dashed horizontal rule pinned to the most recent close, with a
///     floating accent-coloured price tag at the right edge — same visual
///     idiom as TradingView / lightweight-charts. Lets you eyeball the
///     current price without scanning the whole Y axis.
///   • A live crosshair on hover: vertical + horizontal dashed lines and
///     a pulse dot at the data point under the cursor.
///   • A floating OHLC + Δ tooltip at the top-left whenever the user is
///     hovering, so they can read precise values without a separate pane.
///   • Auto-fit Y axis with 5% padding — never the dreaded "0 → ∞" scale
///     that drowns million-toman prices into a single pixel.
///   • Compact "K/M/B" Y-axis labels so 19,634,000 → "19.6M", not "1.9E7".
struct ChartView: View {
    let candles: [Candle]
    let chartType: ChartType
    let accent: Color

    /// Visible X-axis window expressed in *bar indices* (Double for
    /// fractional pan/zoom precision). nil ⇒ auto-fit to the full series.
    /// We use index-based axes rather than continuous time so calendar
    /// gaps (weekends for COMEX, intraday silences for any source) don't
    /// open holes in the chart — consecutive candles are always adjacent.
    @Binding var xDomain: ClosedRange<Double>?

    /// Manual vertical (price) scale, TradingView-style. nil ⇒ auto-fit
    /// the Y axis to the visible data (the default). Once the user drags
    /// the price axis to compress/expand the candles, this pins an
    /// explicit price window and auto-fit is suspended until they
    /// double-click the axis (or reset the chart) to clear it. Owned by
    /// DashboardView so it resets on pair / timeframe change alongside
    /// `xDomain`.
    @Binding var yDomain: ClosedRange<Double>?

    /// Technical indicators the user has toggled on. Re-computed on every
    /// candle change; ChartView is stateless about them — DashboardView
    /// owns the user's selection.
    let indicators: Set<IndicatorKind>

    /// User-tunable indicator parameters (RSI period, UT Bot key value
    /// etc.). Threaded down so UT Bot can compute its trailing stop +
    /// signals from the same config the settings sheet edits.
    let indicatorConfig: OscillatorConfig

    /// Per-instance indicator configuration for multi-instance support.
    /// Used by `Indicators.compute` to render each instance with its own
    /// params (e.g. two SMAs at different periods).
    var indicatorInstances: [IndicatorInstance] = []

    /// Higher-timeframe CHoCH zones projected onto this (lower) timeframe.
    /// Computed by DashboardView from the configured HTF candles and
    /// re-anchored to dates; ChartView maps each date to its nearest local
    /// bar via `barIndex(forDate:)`. Reference-only context — drawn muted
    /// and tagged "·HTF" to read as secondary to the live LTF zones.
    var htfChochZones: [ChangeOfCharacter.DatedZone] = []

    /// Support / resistance levels the user added from an AI analysis.
    /// Empty by default; populated when the user clicks "Add to chart"
    /// on a Support & Resistance Claude run. Drawn as horizontal rules
    /// with a small "S" / "R" tag.
    var srLevels: PromptBuilder.SRLevels = .init(support: [], resistance: [])

    /// FVG / iFVG zones from the AI analysis. Each renders as a
    /// translucent rectangle spanning the gap's bar range and price
    /// band. iFVGs (mitigated) get a dashed border to distinguish them
    /// from active FVGs.
    var fvgZones: [PromptBuilder.FVGZone] = []

    /// Supply & Demand zones from the Confluence Trade Scanner (or Custom) analysis.
    /// Each renders as a translucent rectangle: green for Demand,
    /// red for Supply, spanning the base candle's bar range + price
    /// band. Tested zones (`isFresh == false`) drop to a lower
    /// opacity + dashed border so the user can tell first-test
    /// setups apart from already-revisited ones at a glance.
    var supplyDemandZones: [PromptBuilder.SupplyDemandZone] = []

    /// Outlook from a full TA analysis. When present, two dashed rules
    /// (green target, red invalidation) plus a bias capsule at the
    /// right edge appear on the chart.
    var taScenario: PromptBuilder.TAScenario? = nil

    /// Optional alternative trade plan from the same TA run. Rendered
    /// in parallel with `taScenario` but with thinner / dimmer
    /// styling so the eye reads "this is the secondary plan, not a
    /// duplicate of the main one".
    var taAltScenario: PromptBuilder.TAScenario? = nil


    /// User-drawn shapes (horizontal lines, trend lines, rectangles).
    /// DashboardView owns the persistent store and feeds the visible
    /// subset here; ChartView is stateless about which pair these
    /// belong to.
    var drawings: [ChartDrawing] = []

    /// Tool currently armed by the dashboard's drawing toolbar. When
    /// `.none` the chart behaves normally (drag = pan). Anything else
    /// swaps drag → "draw a shape" — the pinch gesture and crosshair
    /// stay active so the user keeps spatial reference while drawing.
    var activeTool: DrawingTool = .none

    /// Contract spec for the pair on screen, used to size the position
    /// tool. The chart is otherwise pair-agnostic, so the dashboard
    /// passes this down rather than the chart looking up a pair id.
    var contractSpec: ContractSpec = .forPair(id: "ounce")

    /// Called with the fully-formed `ChartDrawing` when the user
    /// finishes a draw gesture (mouse-up). DashboardView appends to
    /// its `DrawingStore`. Optional so existing call-sites that don't
    /// care about drawings can omit it.
    var onCommitDrawing: ((ChartDrawing) -> Void)? = nil

    /// Called with a modified `ChartDrawing` when the user finishes
    /// dragging an existing shape to a new position. Same `id` as the
    /// original — DashboardView's `DrawingStore.update` replaces in
    /// place. Optional for call-sites that don't allow editing.
    var onMoveDrawing: ((ChartDrawing) -> Void)? = nil

    /// Drawing that should render with selection handles, if any. The
    /// dashboard owns this state because it also drives the inspector
    /// popover; the chart just renders + lets the user grab a handle.
    var selectedDrawingID: UUID? = nil

    /// Called when the user clicks a drawing (selects it) or clicks
    /// empty space (deselects, value = nil). Lets the dashboard sync
    /// its `selectedDrawingID` state with what the chart is showing.
    var onSelectDrawing: ((UUID?) -> Void)? = nil

    /// Open paper trades to render. Closed trades are filtered out by
    /// the dashboard (`TradeStore.openVisibleTrades`); the chart only
    /// sees `.pending` or `.active`. Each contributes three RuleMarks
    /// (entry / TP / SL) plus a fill-time marker for actives.
    var trades: [Trade] = []

    /// Journal entries pinned on the chart via "Show on chart". Each
    /// renders entry / TP / SL as styled RuleMarks so the user can
    /// see the actual trade plan against historical price action.
    var journalEntries: [JournalEntry] = []

    /// Signal selected from the Inbox or a macOS notification banner.
    /// Rendered as a prominent entry marker after navigation.
    var notificationFocus: NotificationChartTarget? = nil

    /// Most recent live price for the pair this chart represents.
    /// Drives the live P/L capsule on active trades AND the VALID /
    /// INVALID badge on TA scenario entry tags (a scenario flips to
    /// invalid the moment price crosses its SL line). Optional —
    /// non-live-stream pairs may not have a fresh tick yet, in which
    /// case the validity badge falls back to "VALID" so we don't
    /// false-negative on cold start.
    var livePrice: Double? = nil

    /// Replay mode is active (the chart is showing history up to a
    /// cursor). Draws a marker at the last (cursor) bar so the user
    /// always knows where "now" sits in the replay.
    var replayActive: Bool = false

    /// The chart is waiting for the user to click a start bar for
    /// Replay. While true, a plain click (no drag) anchors the replay
    /// instead of deselecting drawings; panning still works.
    var isPickingReplayAnchor: Bool = false

    /// Whether to show the floating OHLC + Δ tooltip on hover.
    /// Displayed in the primary chart and fullscreen panes; hidden
    /// in compact grid panes so it doesn't crowd the small chart area.
    var showHoverTooltip: Bool = true

    /// Called with the clicked bar's index (into `candles`) when the
    /// user picks a replay start bar. DashboardView maps it to that
    /// candle's date and sets the cursor.
    var onPickReplayAnchor: ((Int) -> Void)? = nil

    /// ForexFactory economic-calendar events to plot as impact-coloured
    /// flags on the bottom time axis (TradingView-style). Already
    /// currency/impact-filtered upstream by `NewsStore.chartEvents`; the
    /// chart maps each event's `eventAt` to a bar via `barIndex(forDate:)`
    /// and only draws those inside the visible window. Empty ⇒ the news
    /// layer is off (toggled from the Layers popover).
    var newsEvents: [ForexFactoryEvent] = []

    /// Display zone for the news popup's timestamp —
    /// `NewsStore.effectiveTimeZone`. Threaded so the flag detail card
    /// shows the same time the News tab does.
    var newsTimeZone: TimeZone = .current

    @State private var hovered: HoverState?

    /// The news event whose flag the user clicked, if any — drives the
    /// floating detail popover. Anchor is the flag's point in the chart
    /// overlay's coordinate space so the card can pin above it.
    @State private var selectedNews: ForexFactoryEvent?
    @State private var newsPopupAnchor: CGPoint = .zero
    /// Memoizes the data-derived arrays (HA candles, indicators, UT Bot,
    /// Order Blocks, …) so pan/zoom — which only changes `xDomain` —
    /// doesn't recompute them over the full history every frame, and
    /// runs each indicator's recompute on a background `Task` so a slow
    /// one never blocks the UI. `@StateObject` so it survives the struct
    /// being re-created each render AND so a background task's
    /// `objectWillChange` actually triggers a redraw. See
    /// `ChartDerivedCache`.
    @StateObject private var derived = ChartDerivedCache()
    @State private var dragStartDomain: ClosedRange<Double>?
    /// Price window captured at the start of a chart pan, so vertical
    /// drag shifts it against a stable reference. `panLockedY` flips true
    /// once a pan develops a real vertical component — until then the Y
    /// axis is left on auto-fit so purely horizontal pans don't pin it.
    @State private var dragStartYDomain: ClosedRange<Double>?
    @State private var panLockedY = false
    @State private var magnifyStartDomain: ClosedRange<Double>?
    /// Price-axis vertical-scale gesture: the Y window captured at the
    /// start of a drag on the price axis, held fixed so the scale factor
    /// is applied against a stable reference (mirrors how
    /// `magnifyStartDomain` anchors the X pinch).
    @State private var yScaleStartDomain: ClosedRange<Double>?
    /// Time-axis horizontal-scale gesture: the X window captured at the
    /// start of a drag on the bottom time axis, held fixed so the scale
    /// factor applies against a stable reference (mirrors
    /// `yScaleStartDomain` for the price axis).
    @State private var xScaleStartDomain: ClosedRange<Double>?

    /// In-progress drawing endpoints — captured on drag start, updated
    /// each frame, cleared on drag end. Lets the chart render a live
    /// preview of the shape the user is currently creating so they
    /// can see what they'll get before committing.
    @State private var drawingStart: DrawingPoint?
    @State private var drawingEnd: DrawingPoint?

    /// Drag-to-move state. When the user clicks on an existing drawing
    /// in cursor mode (`activeTool == .none`), `movingDrawingOriginal`
    /// captures its initial endpoints and `movingDelta` accumulates
    /// the offset (in date + price space) as the cursor moves. The
    /// chart filters the original out of `drawingMarks` and renders a
    /// translated preview based on these so the user sees where the
    /// shape will land before releasing the mouse.
    @State private var movingDrawingOriginal: ChartDrawing?
    @State private var movingDeltaTime: TimeInterval = 0
    @State private var movingDeltaPrice: Double = 0

    /// Drag-to-reshape state. When the user grabs an endpoint handle
    /// of the currently-selected drawing, this captures which handle
    /// (so we know which endpoint to mutate) plus the live cursor
    /// point each frame. `editingHandle == nil` ⇒ no handle drag in
    /// flight, fall back to move/pan logic.
    @State private var editingDrawingID: UUID?
    @State private var editingHandle: ChartDrawing.Handle?
    @State private var editingCursor: DrawingPoint?

    /// Tracks whether a gesture was a click vs a drag. We can't tell
    /// at `onChanged` time whether a click will turn into a drag, so
    /// we route the gesture optimistically and use this in `onEnded`
    /// to convert a zero-distance click on a drawing into a selection.
    @State private var dragHadMovement: Bool = false

    /// Captured on hover. Holds the candle the cursor is over plus the
    /// raw cursor location (kept for the tooltip's positional anchor —
    /// could be useful later for a sticky tooltip) and the cursor's
    /// free Y price, projected from screen Y via the chart proxy.
    /// `cursorPrice` is the value the horizontal crosshair line tracks
    /// (TradingView-style: line follows the cursor, not the snapped
    /// candle close), so the user can read off the price at any spot
    /// on the chart — not just rows that line up with a bar.
    private struct HoverState: Equatable {
        let candle: Candle
        let index: Int
        let cursor: CGPoint
        let cursorPrice: Double
    }

    var body: some View {
        if candles.isEmpty {
            emptyState
        } else {
            chart
                // Tight clip on every edge. The last-price capsule now
                // overlays the rule *inside* the plot area (see the
                // `RuleMark` above) so no trailing slack is needed.
                .clipped()
                // TradingView-style price-axis drag column: a transparent
                // strip over the trailing axis gutter that scales the Y
                // (price) axis vertically. Layered after `.clipped()` so
                // it stays interactive, and on the right so it doesn't
                // steal pan/hover from the main canvas.
                .overlay(alignment: .trailing) { priceAxisScaleStrip }
                // TradingView-style time-axis drag strip: a transparent
                // strip over the bottom axis gutter that scales the X
                // (time) axis horizontally. Inset on the trailing edge so
                // it doesn't overlap the price-axis column at the corner.
                .overlay(alignment: .bottom) { timeAxisScaleStrip }
                .overlay(alignment: .topTrailing) { Group { if showHoverTooltip { hoverTooltip } } }
                // No global .animation() modifiers here. Previously:
                //   .animation(.easeOut(0.15), value: hovered)
                //   .animation(.easeInOut(0.4), value: candles.count)
                // Both wrapped the ENTIRE chart subtree (hundreds of
                // marks + overlays), triggering animation transactions
                // on every hover event and every 1 Hz tick. The hovered
                // animation is now targeted to just the tooltip overlay;
                // the candles-count animation was removed — instant bar
                // appearance is fine (TradingView does the same).
                // (Pan/zoom performance fix.)
        }
    }

    // MARK: - Chart body

    /// Candles actually drawn on the chart. When the user selects the
    /// Heikin Ashi chart type, we transform OHLC values here so every
    /// price-anchored mark (candles, line, last-price rule, hover
    /// crosshair, UT Bot signal markers) uses the smoothed values.
    /// Indicators that derive their own values from `candles` (SMA, EMA,
    /// Bollinger, oscillators) still read the raw input — that matches
    /// TradingView's convention.
    private var displayCandles: [Candle] {
        // Delegates to the memoizing cache: HA transform + live-price
        // patch on the last bar. Cached against the candle data + live
        // price so a pan (xDomain-only change) reuses the prior result
        // instead of rebuilding the whole array every frame.
        derived.displayCandles(
            candles: candles,
            heikinAshi: chartType == .heikinAshi,
            livePrice: livePrice
        )
    }

    /// UT Bot output, lazily computed when the indicator is toggled on.
    /// Both the trailing-stop line and the buy/sell labels come from
    /// this single computation, so we don't re-run the (O(n)) loop in
    /// two different builders.
    private var utBotOutput: UTBot.Output? {
        guard indicators.contains(.utBot) else { return nil }
        return derived.utBot(
            candles: candles,
            keyValue: indicatorConfig.utKeyValue,
            atrPeriod: indicatorConfig.utATRPeriod,
            useHeikinAshi: indicatorConfig.utUseHeikinAshi
        )
    }

    /// Order-block zones, lazily computed when the indicator is toggled
    /// on. Capped to the most recent few so a deep history doesn't pile
    /// dozens of overlapping rectangles on the chart — the latest blocks
    /// are the actionable ones (older blocks have usually been revisited
    /// or invalidated already).
    private var orderBlockZones: [OrderBlocks.Zone] {
        guard indicators.contains(.orderBlock) else { return [] }
        let all = derived.orderBlocks(
            candles: candles,
            periods: indicatorConfig.obPeriods,
            threshold: indicatorConfig.obThreshold,
            useWicks: indicatorConfig.obUseWicks,
            detectSteroids: indicatorConfig.obDetectSteroids
        )
        let filtered = indicatorConfig.obShowExhausted ? all : all.filter { $0.status != .exhausted }
        return Array(filtered.suffix(Self.maxOrderBlocks))
    }
    private static let maxOrderBlocks = 6

    /// Steroid Order Block zones.
    private var steroidOrderBlockZones: [SteroidOrderBlocks.Zone] {
        guard indicators.contains(.steroidOrderBlock) else { return [] }
        let all = derived.steroidOrderBlocks(
            candles: candles,
            periods: indicatorConfig.sobPeriods,
            threshold: indicatorConfig.sobThreshold,
            useWicks: indicatorConfig.sobUseWicks,
            volumeMultiplier: indicatorConfig.sobVolumeMultiplier,
            detectSteroids: indicatorConfig.sobDetectSteroids
        )
        let filtered = indicatorConfig.sobShowExhausted ? all : all.filter { $0.status != .exhausted }
        return Array(filtered.suffix(Self.maxOrderBlocks))
    }

    /// FVG zones from the indicator (distinct from AI-analysis `fvgZones`
    /// which are PromptBuilder.FVGZone values). Computed fresh from candle
    /// data whenever the indicator is enabled; filtered to the most recent
    /// to avoid visual noise on deep histories.
    private var indicatorFvgZones: [FairValueGap.Zone] {
        guard indicators.contains(.fairValueGap) else { return [] }
        let all = derived.fairValueGaps(
            candles: candles,
            threshold: indicatorConfig.fvgThreshold
        )
        return indicatorConfig.fvgShowMitigated ? all : all.filter { !$0.isMitigated }
    }

    /// Sonarlab Order Block zones — momentum-based OB detection via ROC.
    private var sonarlabOBZones: [SonarlabOrderBlocks.Zone] {
        guard indicators.contains(.sonarlabOrderBlock) else { return [] }
        let mitType: SonarlabOrderBlocks.MitigationType =
            indicatorConfig.sonarlabMitigationType == "Wick" ? .wick : .close
        let all = derived.sonarlabOrderBlocks(
            candles: candles,
            sensitivity: indicatorConfig.sonarlabSensitivity,
            mitigationType: mitType
        )
        return Array(all.suffix(Self.maxSonarlabOBs))
    }
    private static let maxSonarlabOBs = 20

    /// Ranked Order Block zones — swing-structure OBs graded A/B/C by
    /// Volume Profile + Ichimoku confluence.
    private var rankedOBZones: [RankedOrderBlocks.Zone] {
        guard indicators.contains(.rankedOrderBlock) else { return [] }
        return derived.rankedOrderBlocks(
            candles: candles,
            config: indicatorConfig.rankedOrderBlockConfiguration
        )
    }

    /// Change of Character confluence zones — structure break + OB/FVG.
    private var chochZones: [ChangeOfCharacter.Zone] {
        guard indicators.contains(.changeOfCharacter) else { return [] }
        return derived.changeOfCharacter(
            candles: candles,
            swingLength: indicatorConfig.chochSwingLength,
            minSwingPct: indicatorConfig.chochMinSwingPct,
            requireFVG: indicatorConfig.chochRequireFVG,
            showMitigated: indicatorConfig.chochShowMitigated
        )
    }

    /// Ichimoku Cloud output — five lines + the Kumo, computed when the
    /// indicator is toggled on. Displacement is baked into the plot
    /// indices (see `Ichimoku.compute`).
    private var ichimokuOutput: Ichimoku.Output {
        guard indicators.contains(.ichimoku) else { return .empty }
        return derived.ichimoku(
            candles: candles,
            tenkan: indicatorConfig.ichiTenkan,
            kijun: indicatorConfig.ichiKijun,
            senkouB: indicatorConfig.ichiSenkouB,
            displacement: indicatorConfig.ichiDisplacement
        )
    }

    /// Ichimoku-confluence Order Block zones — base OBs filtered/scored
    /// by their alignment with the Ichimoku picture. Capped to the most
    /// recent few like the other order-block overlays.
    private var ichimokuOBZones: [IchimokuOrderBlocks.Zone] {
        guard indicators.contains(.ichimokuOrderBlock) else { return [] }
        let all = derived.ichimokuOrderBlocks(
            candles: candles,
            periods: indicatorConfig.iobPeriods,
            threshold: indicatorConfig.iobThreshold,
            useWicks: indicatorConfig.iobUseWicks,
            tenkan: indicatorConfig.iobTenkan,
            kijun: indicatorConfig.iobKijun,
            senkouB: indicatorConfig.iobSenkouB,
            displacement: indicatorConfig.iobDisplacement,
            minScore: indicatorConfig.iobMinScore,
            requireTrend: indicatorConfig.iobRequireTrend
        )
        return Array(all.suffix(Self.maxOrderBlocks))
    }

    /// Volume-Filtered Order Blocks — swing-anchored, volume-tagged zones
    /// with a breaker lifecycle. Empty when the indicator is off.
    private var volumeFilteredOBZones: [VolumeFilteredOrderBlocks.Zone] {
        guard indicators.contains(.volumeFilteredOrderBlock) else { return [] }
        let cfg = indicatorConfig
        return derived.volumeFilteredOrderBlocks(
            candles: candles,
            swingLength: cfg.vfobSwingLength,
            invalidationWick: cfg.vfobInvalidation == "Wick",
            maxZonesPerSide: Self.vfobZoneCount(cfg.vfobZoneCount),
            showHistoric: cfg.vfobShowHistoric,
            combine: true
        ).zones
    }

    /// Zone-count preset → zones rendered per side (matches the Pine
    /// "One / Low / Medium / High" mapping).
    static func vfobZoneCount(_ preset: String) -> Int {
        switch preset {
        case "One":    return 1
        case "Medium": return 5
        case "High":   return 10
        default:       return 3   // "Low"
        }
    }

    /// Session-based Volume Profile sessions — per-trading-day histograms
    /// with POC, VAH, VAL. Only used in "session" mode.
    private var volumeProfileSessions: [VolumeProfile.SessionVP] {
        guard indicators.contains(.volumeProfile), indicatorConfig.vpMode == "session" else { return [] }
        return derived.volumeProfile(
            candles: candles,
            bucketCount: indicatorConfig.vpBucketCount,
            valueAreaPct: indicatorConfig.vpValueAreaPct
        )
    }

    /// ZigZag-based Volume Profile for the last trend segment only.
    /// Used in "zigzag" mode.
    private var zigzagTrendVP: VolumeProfile.TrendVP? {
        guard indicators.contains(.volumeProfile), indicatorConfig.vpMode == "zigzag" else { return nil }
        return derived.zigzagVolumeProfile(
            candles: candles,
            bucketCount: indicatorConfig.vpBucketCount,
            valueAreaPct: indicatorConfig.vpValueAreaPct,
            zzDepth: indicatorConfig.vpZZDepth,
            zzMinChange: indicatorConfig.vpZZMinChange
        )
    }

    /// Visible-range Volume Profile: histogram of the bars currently in
    /// view plus ranked high-volume levels. Used in "visible" mode.
    private var visibleRangeVP: VolumeProfile.VisibleRangeVP? {
        guard indicators.contains(.volumeProfile), indicatorConfig.vpMode == "visible" else { return nil }
        let domain = effectiveXDomain
        let lo = max(0, Int(domain.lowerBound.rounded(.down)))
        let hi = min(candles.count - 1, Int(domain.upperBound.rounded(.up)))
        guard hi > lo else { return nil }
        return derived.visibleRangeVolumeProfile(
            candles: candles,
            barRange: lo...hi,
            bucketCount: indicatorConfig.vpBucketCount,
            valueAreaPct: indicatorConfig.vpValueAreaPct,
            levelCount: indicatorConfig.vpLevelCount
        )
    }

    /// ZigZag pivot points for drawing the zigzag line overlay.
    private var zigzagPivots: [ZigZag.Pivot] {
        guard indicators.contains(.volumeProfile),
              indicatorConfig.vpMode == "zigzag",
              indicatorConfig.vpShowZigzag else { return [] }
        return derived.zigzagPivots(
            candles: candles,
            depth: indicatorConfig.vpZZDepth,
            minChange: indicatorConfig.vpZZMinChange
        )
    }

    /// Session runs to draw: the *current day only* instance of every
    /// enabled preset — i.e. each venue's most recent run, not its whole
    /// history. `TradingSessions.compute` appends runs per-session in
    /// chronological order, so the last run seen for a given session ID is
    /// that venue's latest (today's, or still-open) trading day; overwriting
    /// by ID as we walk the memoized list picks exactly that one. This
    /// keeps at most one box per enabled session on screen — no windowing
    /// or cap needed — and lets `sessionMarks` extend each one's high/low/
    /// average lines to the live edge so, say, Tokyo's range stays visible
    /// as a dotted reference while London/New York are trading.
    private var sessionRuns: [TradingSessions.SessionRun] {
        guard indicators.contains(.tradingSession) else { return [] }
        var latest: [String: TradingSessions.SessionRun] = [:]
        for run in derived.tradingSessions(candles: candles) where indicatorConfig.showsSession(run.sessionID) {
            latest[run.sessionID] = run
        }
        return latest.values.sorted { $0.start < $1.start }
    }


    /// NY Open Setup results to draw: the per-day setups whose footprint
    /// (opening range → resolution / live edge) overlaps the visible
    /// window. Detection is memoized data-side in `ChartDerivedCache`;
    /// 1m/5m only (the detector returns nothing on coarser bars).
    private var nySetupResults: [NYOpenSetup.Result] {
        guard indicators.contains(.nyOpenSetup) else { return [] }
        let all = derived.nyOpenSetup(
            candles: candles,
            atrMult: indicatorConfig.nyAtrMult,
            amOnly: indicatorConfig.nyAMOnly
        )
        guard !all.isEmpty,
              let b = ChartWindow.visibleBounds(domain: effectiveXDomain, count: candles.count)
        else { return [] }
        let lastIndex = candles.count - 1
        let margin = max(8, (b.hi - b.lo) / 4)
        let lo = b.lo - margin
        let hi = b.hi + margin
        // Keep only the most recent few days' setups on the chart — older
        // history would pile up dozens of overlapping plans. The live /
        // most-recent setup is always among them (it's the last element).
        return all.suffix(Self.maxSetupsOnChart).filter { r in
            let end = r.resolveIndex ?? lastIndex   // live plans run to the edge
            return end >= lo && r.orStartIndex <= hi
        }
    }
    /// Cap on how many NY Open setups draw at once (the N most recent days).
    private static let maxSetupsOnChart = 3

    /// SP2L Strategy results to draw. The detector returns recent
    /// chronological setups; this trims to setups overlapping the current
    /// chart window so old historical plays do not clutter the view.
    private var sp2lResults: [SP2LSetup.Result] {
        guard indicators.contains(.sp2lStrategy) else { return [] }
        let all = derived.sp2lSetup(candles: candles, config: indicatorConfig)
        guard !all.isEmpty,
              let b = ChartWindow.visibleBounds(domain: effectiveXDomain, count: candles.count)
        else { return [] }
        let lastIndex = candles.count - 1
        let margin = max(8, (b.hi - b.lo) / 4)
        let lo = b.lo - margin
        let hi = b.hi + margin
        return all.filter { $0.stage != .invalidated }
            .suffix(Self.maxSP2LSetupsOnChart).filter { r in
            guard sp2lResultFitsCurrentCandles(r) else { return false }
            let end = r.resolveIndex ?? lastIndex
            return end >= lo && r.spikeStartIndex <= hi
        }
    }
    private static let maxSP2LSetupsOnChart = 5

    private var pinBarComboResults: [PinBarComboSetup.Result] {
        guard indicators.contains(.pinBarCombo) else { return [] }
        let bases = derived.sp2lSetup(candles: candles, config: indicatorConfig)
        let all = derived.pinBarComboSetup(
            candles: candles,
            sp2lResults: bases,
            config: indicatorConfig
        )
        guard !all.isEmpty,
              let bounds = ChartWindow.visibleBounds(domain: effectiveXDomain, count: candles.count)
        else { return [] }
        let margin = max(8, (bounds.hi - bounds.lo) / 4)
        return all.suffix(Self.maxPinBarComboSetupsOnChart).filter { result in
            pinBarComboResultFitsCurrentCandles(result)
                && result.lastRelevantIndex >= bounds.lo - margin
                && result.structureStartIndex <= bounds.hi + margin
        }
    }
    private static let maxPinBarComboSetupsOnChart = 6

    private func pinBarComboResultFitsCurrentCandles(_ result: PinBarComboSetup.Result) -> Bool {
        let upper = candles.count - 1
        guard upper >= 0 else { return false }
        let indices = [
            result.structureStartIndex,
            result.breakoutIndex,
            result.confirmationIndex
        ] + [result.resolveIndex].compactMap { $0 }
        return indices.allSatisfy { $0 >= 0 && $0 <= upper }
    }

    /// MicroMap results overlapping the visible chart window. The cache can
    /// briefly expose a result from the prior replay window, so every index is
    /// validated before marks index into the current candle array.
    private var microMapResults: [MicroMapSetup.Result] {
        guard indicators.contains(.microMapStrategy) else { return [] }
        let all = derived.microMapSetup(candles: candles, config: indicatorConfig)
        guard !all.isEmpty,
              let bounds = ChartWindow.visibleBounds(domain: effectiveXDomain, count: candles.count)
        else { return [] }
        let margin = max(8, (bounds.hi - bounds.lo) / 4)
        return all.suffix(Self.maxMicroMapSetupsOnChart).filter { result in
            microMapResultFitsCurrentCandles(result) &&
            result.lastRelevantIndex >= bounds.lo - margin &&
            result.spikeStartIndex <= bounds.hi + margin
        }
    }
    private static let maxMicroMapSetupsOnChart = 5

    private func microMapResultFitsCurrentCandles(_ result: MicroMapSetup.Result) -> Bool {
        let upper = candles.count - 1
        guard upper >= 0 else { return false }
        let required = [
            result.spikeStartIndex,
            result.spikeEndIndex,
            result.microStartIndex,
            result.microEndIndex,
            result.lastRelevantIndex
        ]
        let attemptIndices = result.attempts.flatMap { attempt in
            [attempt.anchorIndex, attempt.triggerIndex, attempt.stopIndex, attempt.targetIndex].compactMap { $0 }
        }
        return (required + attemptIndices).allSatisfy { $0 >= 0 && $0 <= upper }
    }

    /// Major Trend Reversal results overlapping the visible window. MTR
    /// uses confirmed pivots, so validating every stored index also protects
    /// replay when the revealed candle array shrinks.
    private var mtrResults: [MTRSetup.Result] {
        guard indicators.contains(.mtrStrategy) else { return [] }
        let all = derived.mtrSetup(candles: candles, config: indicatorConfig)
        guard !all.isEmpty,
              let bounds = ChartWindow.visibleBounds(domain: effectiveXDomain, count: candles.count)
        else { return [] }
        let margin = max(8, (bounds.hi - bounds.lo) / 4)
        return all.suffix(Self.maxMTRSetupsOnChart).filter { result in
            mtrResultFitsCurrentCandles(result)
                && result.lastRelevantIndex >= bounds.lo - margin
                && result.channelStartIndex <= bounds.hi + margin
        }
    }
    private static let maxMTRSetupsOnChart = 5

    private func mtrResultFitsCurrentCandles(_ result: MTRSetup.Result) -> Bool {
        let upper = candles.count - 1
        guard upper >= 0 else { return false }
        let required = [
            result.channelStartIndex,
            result.channelEndIndex,
            result.trendExtremeIndex,
            result.breakoutIndex,
            result.retestIndex,
            result.lastRelevantIndex
        ] + [result.confirmationIndex, result.resolveIndex].compactMap { $0 }
        return required.allSatisfy { $0 >= 0 && $0 <= upper }
    }

    /// `ChartDerivedCache` may briefly return the previous SP2L result
    /// while a replay step recomputes in the background. Replay can shrink
    /// `candles`, so validate every candle index before rendering marks
    /// that index into the current array.
    private func sp2lResultFitsCurrentCandles(_ r: SP2LSetup.Result) -> Bool {
        let upper = candles.count - 1
        guard upper >= 0 else { return false }
        let required = [
            r.levelStartIndex,
            r.spikeStartIndex,
            r.spikeEndIndex,
            r.breakoutIndex,
            r.followThroughIndex,
            r.gapStartIndex,
            r.gapEndIndex
        ]
        guard required.allSatisfy({ $0 >= 0 && $0 <= upper }) else { return false }
        let optional = [
            r.pullbackIndex,
            r.entryIndex,
            r.resolveIndex
        ].compactMap { $0 }
        return optional.allSatisfy { $0 >= 0 && $0 <= upper }
    }

    private var chart: some View {
        // Compute the visible bar indices ONCE for the entire frame.
        // Previously `renderIndices` and `renderIndexSet` were separate
        // computed properties that each called ChartWindow.renderIndices
        // independently, doubling the work on every pan/zoom frame.
        Group {
            let indices = renderIndices
            let indexSet = Set(indices)

            Chart {
            // Real calendar-day boundaries. The X axis is index-based, so
            // regular grid lines do not naturally land on midnight.
            dayBoundaryMarks

            // Last-price horizontal reference line. Drawn first so it sits
            // behind the data marks. The trailing annotation pins a price
            // tag to the right edge — TradingView-style.
            if let last = displayCandles.last {
                RuleMark(y: .value("Last", last.close))
                    .foregroundStyle(accent.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    // Tag overlays the rule at its trailing end and stays
                    // *inside* the plot area — previously the annotation
                    // used `.trailing` which made the capsule extend past
                    // the plot edge, so the chart had to be clipped with
                    // slack on the right (which let panned marks leak too).
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        Text(Self.priceExact(last.close))
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(accent)
                            )
                    }
            }

            // Replay cursor — a dashed vertical at the last revealed bar
            // marks where "now" sits while stepping through history.
            if replayActive, !displayCandles.isEmpty {
                RuleMark(x: .value("Replay", Double(displayCandles.count - 1)))
                    .foregroundStyle(Theme.Color.warn.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                    .annotation(position: .top, alignment: .trailing, spacing: 0) {
                        Text("REPLAY")
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.Color.warn))
                    }
            }

            // Trading-session boxes — the backmost overlay so the day's
            // price action and every other mark read on top of them.
            sessionMarks

            // Volume Profile — per-day histograms with POC, VAH, VAL.
            // Behind price action so candles remain the visual focus.
            volumeProfileMarks

            // ZigZag line overlay — on top of candles when VP is in
            // zigzag mode, so the user can see the detected trend.
            zigzagLineMarks

            // NY Open Setup — opening-range box, breakout FVG, and the
            // entry/SL/TP plan. Behind the price action like the zones.
            setupMarks
            sp2lMarks
            pinBarComboMarks
            microMapMarks
            mtrMarks
            notificationFocusMarks

            // S/R levels — horizontal rules at the prices the AI
            // analysis identified. Drawn behind the candles (before the
            // switch below) so the price action stays the visual focus.
            srLevelMarks
            fvgMarks
            indicatorFvgMarks
            supplyDemandMarks
            orderBlockMarks
            steroidOrderBlockMarks
            sonarlabOBMarks
            ichimokuOBMarks
            rankedOBMarks
            volumeFilteredOBMarks
            htfChochMarks
            chochMarks
            scenarioMarks
            tradeMarks
            journalMarks
            drawingMarks
            drawingPreviewMarks

            // Main marks. `.heikinAshi` goes through the same candle
            // builder as `.candle` — the OHLC transform happens in
            // `displayCandles`, so the renderer doesn't need to care
            // about the source.
            switch chartType {
            case .line:                  lineMarks(indices: indices)
            case .candle, .heikinAshi:   candleMarks(indices: indices)
            }

            // Indicator overlays — drawn on top of the price series so
            // SMA/EMA/Bollinger lines aren't obscured by candle bodies.
            indicatorMarks(visible: indexSet)

            // Ichimoku Cloud — translucent Kumo + five component lines.
            // On top so the lines read clearly; the cloud fill is faint
            // enough not to hide candles.
            ichimokuMarks(visible: indexSet)

            // UT Bot trailing-stop line + buy/sell labels. Rendered last
            // so the labels sit on top of every other mark.
            utBotMarks(indices: indices, visible: indexSet)

            // Crosshair — drawn last so it overlays the data. Vertical
            // rule snaps to the bar column under the cursor (bars are
            // discrete, free X would land between candles). Horizontal
            // rule follows the cursor's free Y so the user can read
            // the price at any point on the chart — TradingView's
            // default Cross mode. Both rules carry pill labels at the
            // axes showing the exact price (Y) and timestamp (X).
            if let h = hovered, h.index < displayCandles.count {
                let dc = displayCandles[h.index]
                RuleMark(x: .value("Hover X", Double(h.index)))
                    .foregroundStyle(Color.white.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .bottom, alignment: .center, spacing: 2) {
                        Text(Self.dateFormatter.string(from: h.candle.bucketStart))
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Theme.Color.surfaceMax)
                            )
                    }
                RuleMark(y: .value("Hover Y", h.cursorPrice))
                    .foregroundStyle(Color.white.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        Text(Self.priceExact(h.cursorPrice))
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(Theme.Color.surfaceMax)
                            )
                    }
                // Marker on the snapped candle close so the user still
                // sees which bar the crosshair is reading. Doesn't
                // anchor the horizontal line any more — that follows
                // the cursor.
                PointMark(
                    x: .value("Hover", Double(h.index)),
                    y: .value("Hover", dc.close)
                )
                .foregroundStyle(accent)
                .symbolSize(70)
            }
        }
        .chartYScale(domain: effectiveYDomain)
        .chartXScale(domain: effectiveXDomain)
        .chartXAxis(content: xAxis)
        .chartYAxis(content: yAxis)
        .chartPlotStyle { plot in
            plot
                .background(
                    LinearGradient(
                        colors: [
                            Theme.Color.surface.opacity(0.0),
                            Theme.Color.surface.opacity(0.6),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        }
        .chartOverlay { proxy in
            // Transparent gesture catcher sized to the plot area. Maps the
            // cursor's X position back into the data domain (Date), then
            // snaps to the nearest candle. Set to nil on hover-end so the
            // crosshair disappears cleanly. Also hosts the drag-to-pan
            // and pinch-to-zoom gestures — both operate on `xDomain` and
            // need the plot frame size to translate point-distance into
            // time-distance, which lives on the chart proxy.
            GeometryReader { geo in
                let plotFrame = geo[proxy.plotAreaFrame]
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                // Translate to the chart's plot frame coords,
                                // ask the proxy for the X-axis value (a bar
                                // index as Double), round to the nearest
                                // whole bar, and clamp into the array.
                                let origin = plotFrame.origin
                                let x = location.x - origin.x
                                let y = location.y - origin.y
                                guard let xValue: Double = proxy.value(atX: x) else { return }
                                let idx = max(0, min(candles.count - 1, Int(xValue.rounded())))
                                // Project the cursor's Y back into price
                                // space. nil ⇒ cursor is outside the plot
                                // area's Y range; fall back to the candle
                                // close so the crosshair always has a
                                // sensible reading.
                                let yPrice: Double = proxy.value(atY: y) ?? candles[idx].close
                                hovered = HoverState(
                                    candle: candles[idx],
                                    index: idx,
                                    cursor: location,
                                    cursorPrice: yPrice
                                )
                            case .ended:
                                hovered = nil
                            }
                        }
                        .gesture(dragGesture(
                            plotWidth: plotFrame.size.width,
                            plotHeight: plotFrame.size.height,
                            plotOrigin: plotFrame.origin,
                            proxy: proxy
                        ))
                        .simultaneousGesture(magnificationGesture())

                    // News flags pinned to the bottom time axis. Drawn as
                    // overlay views (not ChartContent) so they share the
                    // proxy's coordinate space with the click hit-test and
                    // the popover, and never fight the plot clip. Taps are
                    // handled by the gesture rectangle above, so the flags
                    // themselves take no hits.
                    newsFlagsLayer(proxy: proxy, plotFrame: plotFrame)
                        .allowsHitTesting(false)

                    // Detail popover for the clicked flag.
                    if let ev = selectedNews {
                        newsPopupLayer(event: ev, plotFrame: plotFrame)
                    }
                }
            }
        }
        }
    }

    // MARK: - News layer (flags + popover)

    @ViewBuilder
    private func newsFlagsLayer(proxy: ChartProxy, plotFrame: CGRect) -> some View {
        ForEach(visibleNewsMarkers) { m in
            if let px = proxy.position(forX: m.barIndex) {
                NewsFlagView(color: m.color)
                    .position(x: plotFrame.origin.x + px, y: plotFrame.maxY - 9)
            }
        }
    }

    @ViewBuilder
    private func newsPopupLayer(event: ForexFactoryEvent, plotFrame: CGRect) -> some View {
        let cardWidth: CGFloat = 240
        let halfW = cardWidth / 2 + 6
        let clampedX = min(max(newsPopupAnchor.x, plotFrame.minX + halfW),
                           plotFrame.maxX - halfW)
        // Sit the card above the flag; clamp so it never rides off the
        // top of the plot on a very short chart.
        let clampedY = max(plotFrame.minY + 70, newsPopupAnchor.y - 84)
        NewsMarkerPopover(event: event, timeZone: newsTimeZone) {
            selectedNews = nil
        }
        .position(x: clampedX, y: clampedY)
    }

    /// Was a plain click on a bottom-axis news flag? Returns the event
    /// and the flag's anchor point (in overlay coordinates) so the
    /// popover can pin above it. Only the bottom ~26px band is live so
    /// clicks on price action never trip a flag.
    private func newsHitTest(
        at location: CGPoint,
        plotOrigin: CGPoint,
        plotHeight: CGFloat,
        proxy: ChartProxy
    ) -> (event: ForexFactoryEvent, anchor: CGPoint)? {
        guard location.y >= plotOrigin.y + plotHeight - 26 else { return nil }
        var best: (dist: CGFloat, event: ForexFactoryEvent, anchor: CGPoint)?
        for m in visibleNewsMarkers {
            guard let px = proxy.position(forX: m.barIndex) else { continue }
            let sx = plotOrigin.x + px
            let d = abs(location.x - sx)
            guard d <= 14 else { continue }
            if best == nil || d < best!.dist {
                best = (d, m.event, CGPoint(x: sx, y: plotOrigin.y + plotHeight - 9))
            }
        }
        guard let b = best else { return nil }
        return (b.event, b.anchor)
    }

    // MARK: - Pan / draw

    /// Single drag-handler that dispatches to one of three modes:
    ///   • cursor + drag started on a drawing → MOVE that drawing
    ///   • cursor + drag started anywhere else → PAN the chart
    ///   • a drawing tool armed → DRAW a new shape
    /// We use `minimumDistance: 0` so a simple click commits a
    /// horizontal line — the pan branch tolerates zero-distance drags
    /// fine (translation = 0 ⇒ no-op).
    private func dragGesture(
        plotWidth: CGFloat,
        plotHeight: CGFloat,
        plotOrigin: CGPoint,
        proxy: ChartProxy
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let movedFar = pow(value.translation.width, 2) + pow(value.translation.height, 2) >= 9
                if movedFar { dragHadMovement = true }

                if activeTool != .none {
                    handleDrawChange(value, plotOrigin: plotOrigin, proxy: proxy)
                    return
                }
                // Cursor mode — decide on the very first frame whether
                // the user grabbed a handle, the body of a drawing,
                // or wants to pan. The decision sticks for the rest of
                // the gesture.
                let alreadyChose =
                    editingDrawingID != nil ||
                    movingDrawingOriginal != nil ||
                    dragStartDomain != nil
                if !alreadyChose {
                    // 1) Handle first — handles are small, so only the
                    //    currently-selected drawing presents them and
                    //    the threshold is tight.
                    if let sel = selectionTargetDrawing,
                       let anchor = hitTestHandle(
                            of: sel,
                            at: value.startLocation,
                            plotOrigin: plotOrigin,
                            proxy: proxy
                       )
                    {
                        editingDrawingID = sel.id
                        editingHandle = anchor
                        editingCursor = drawingPoint(at: value.startLocation, plotOrigin: plotOrigin, proxy: proxy)
                        hovered = nil
                    }
                    // 2) Otherwise hit-test the body of any visible drawing.
                    //    Skip hit-testing when no drawings exist and no tool
                    //    is armed — saves iterating all drawings on every
                    //    mouse-pixel during plain panning.
                    else if (!drawings.isEmpty || activeTool != .none),
                            let hit = hitTestDrawing(
                        at: value.startLocation,
                        plotOrigin: plotOrigin,
                        proxy: proxy
                    ) {
                        movingDrawingOriginal = hit
                        movingDeltaTime = 0
                        movingDeltaPrice = 0
                        hovered = nil
                    }
                }

                if editingDrawingID != nil {
                    editingCursor = drawingPoint(at: value.location, plotOrigin: plotOrigin, proxy: proxy)
                } else if movingDrawingOriginal != nil {
                    handleMoveChange(value, plotOrigin: plotOrigin, proxy: proxy)
                } else {
                    handlePanChange(value, plotWidth: plotWidth, plotHeight: plotHeight)
                }
            }
            .onEnded { value in
                let hadMovement = dragHadMovement
                dragHadMovement = false

                // Replay anchor pick takes priority: a click (no drag)
                // while picking sets the start bar. A drag is still a
                // pan — leave the panned domain in place and bail.
                if isPickingReplayAnchor {
                    if !hadMovement {
                        let xInPlot = value.location.x - plotOrigin.x
                        if let xVal: Double = proxy.value(atX: xInPlot) {
                            let idx = max(0, min(candles.count - 1, Int(xVal.rounded())))
                            onPickReplayAnchor?(idx)
                        }
                    }
                    dragStartDomain = nil
                    dragStartYDomain = nil
                    panLockedY = false
                    return
                }

                // News flag click — a plain click on a bottom-axis flag
                // opens its detail popover and takes priority over
                // pan/deselect. Only in cursor mode; drawing tools own
                // their clicks. A click that misses every flag dismisses
                // an open popover.
                if activeTool == .none, !hadMovement {
                    if let hit = newsHitTest(
                        at: value.location,
                        plotOrigin: plotOrigin,
                        plotHeight: plotHeight,
                        proxy: proxy
                    ) {
                        selectedNews = hit.event
                        newsPopupAnchor = hit.anchor
                        dragStartDomain = nil
                        dragStartYDomain = nil
                        panLockedY = false
                        return
                    }
                    if selectedNews != nil { selectedNews = nil }
                }

                if activeTool != .none {
                    handleDrawEnd(value, plotOrigin: plotOrigin, proxy: proxy)
                    return
                }
                if editingDrawingID != nil {
                    handleResizeEnd()
                    return
                }
                if let moving = movingDrawingOriginal {
                    if hadMovement {
                        handleMoveEnd()
                    } else {
                        // No drag ⇒ this was a click on a drawing — treat
                        // as "select me", not a move.
                        onSelectDrawing?(moving.id)
                        movingDrawingOriginal = nil
                        movingDeltaTime = 0
                        movingDeltaPrice = 0
                    }
                    return
                }
                // Click on empty space deselects.
                if !hadMovement && selectedDrawingID != nil {
                    onSelectDrawing?(nil)
                }
                dragStartDomain = nil
                dragStartYDomain = nil
                panLockedY = false
            }
    }

    /// Was the click within handle-grab distance of any of the
    /// selected drawing's handles? Returns the matching anchor or nil.
    /// Handle hit-radius is tighter than body hit-radius (handles are
    /// supposed to feel precise).
    private func hitTestHandle(
        of d: ChartDrawing,
        at location: CGPoint,
        plotOrigin: CGPoint,
        proxy: ChartProxy,
        threshold: CGFloat = 10
    ) -> ChartDrawing.Handle? {
        let p = CGPoint(x: location.x - plotOrigin.x, y: location.y - plotOrigin.y)
        let handles = handlePositions(for: d)
        let anchors = handleAnchors(for: d)
        for (hp, anchor) in zip(handles, anchors) {
            guard let hx: CGFloat = proxy.position(forX: hp.x),
                  let hy: CGFloat = proxy.position(forY: hp.y)
            else { continue }
            if hypot(p.x - hx, p.y - hy) <= threshold {
                return anchor
            }
        }
        return nil
    }

    /// Anchors that pair 1:1 with `handlePositions(for:)` — the
    /// rendering side just needs coordinates, but the gesture side
    /// needs to know which logical endpoint to mutate.
    private func handleAnchors(for d: ChartDrawing) -> [ChartDrawing.Handle] {
        switch d.kind {
        case .horizontalLine: return [.start]
        case .trendLine:      return [.start, .end]
        case .rectangle:      return [.topLeft, .topRight, .bottomLeft, .bottomRight]
        case .volumeProfile:  return [.topLeft, .topRight, .bottomLeft, .bottomRight]
        // Must stay positionally in step with `handlePositions(for:)`,
        // which omits handles for levels the position doesn't have —
        // `hitTestHandle` zips the two lists, so an unconditional list
        // here would map the target handle onto `.stop` when a position
        // has no stop.
        case .longPosition, .shortPosition:
            var anchors: [ChartDrawing.Handle] = [.entry]
            if d.stopPrice != nil   { anchors.append(.stop) }
            if d.targetPrice != nil { anchors.append(.target) }
            anchors.append(.timeEnd)
            return anchors
        }
    }

    /// Commit the in-flight resize. The drawing handed back to the
    /// dashboard carries the same `id` so `DrawingStore.update`
    /// replaces in place — no duplicate, no churn in the Layers
    /// popover ordering.
    private func handleResizeEnd() {
        defer {
            editingDrawingID = nil
            editingHandle = nil
            editingCursor = nil
        }
        guard let id = editingDrawingID,
              let original = drawings.first(where: { $0.id == id }),
              let anchor = editingHandle,
              let cursor = editingCursor
        else { return }
        let resized = original.resized(anchor: anchor, to: cursor)
        if resized == original { return }
        onMoveDrawing?(resized)
    }

    private func handlePanChange(_ value: DragGesture.Value, plotWidth: CGFloat, plotHeight: CGFloat) {
        if dragStartDomain == nil {
            dragStartDomain = effectiveXDomain
            // Anchor the price window too so a vertical drag shifts it
            // against a stable reference (mirrors the X anchor).
            dragStartYDomain = effectiveYDomain
            panLockedY = false
            // Drop the crosshair while panning — it'd flicker against
            // the moving series otherwise.
            hovered = nil
        }
        guard let start = dragStartDomain, plotWidth > 0 else { return }
        let span = start.upperBound - start.lowerBound
        let unitsPerPoint = span / Double(plotWidth)
        let delta = Double(value.translation.width) * unitsPerPoint
        // Drag right ⇒ pan into the past (lower indices), so subtract.
        xDomain = (start.lowerBound - delta) ... (start.upperBound - delta)

        // Vertical pan — shift the price window so the chart follows the
        // cursor up/down, TradingView-style. We only engage once the
        // drag has a genuine vertical component (>3pt), so a clean
        // horizontal pan leaves the auto-fit scale untouched; once
        // engaged the Y scale stays pinned until reset (double-click the
        // axis, the reset control, or a pair/timeframe change).
        if !panLockedY, abs(value.translation.height) > 3 { panLockedY = true }
        if panLockedY, let startY = dragStartYDomain, plotHeight > 0 {
            let ySpan = startY.upperBound - startY.lowerBound
            let pricePerPoint = ySpan / Double(plotHeight)
            // Drag down (+height) ⇒ raise the price window so higher
            // prices scroll in from the top and the candles track the
            // cursor downward.
            let shift = Double(value.translation.height) * pricePerPoint
            yDomain = (startY.lowerBound + shift) ... (startY.upperBound + shift)
        }
    }

    private func handleDrawChange(
        _ value: DragGesture.Value,
        plotOrigin: CGPoint,
        proxy: ChartProxy
    ) {
        if drawingStart == nil {
            drawingStart = drawingPoint(at: value.startLocation, plotOrigin: plotOrigin, proxy: proxy)
            // Suppress the crosshair while a drawing is in flight so it
            // doesn't fight the preview marks for visual attention.
            hovered = nil
        }
        drawingEnd = drawingPoint(at: value.location, plotOrigin: plotOrigin, proxy: proxy)
    }

    private func handleDrawEnd(
        _ value: DragGesture.Value,
        plotOrigin: CGPoint,
        proxy: ChartProxy
    ) {
        // Resolve endpoints (falling back to the gesture's own start/end
        // locations if `onChanged` never captured them — happens on a
        // very fast click).
        let startPoint = drawingStart ?? drawingPoint(at: value.startLocation, plotOrigin: plotOrigin, proxy: proxy)
        let endPoint   = drawingEnd   ?? drawingPoint(at: value.location,      plotOrigin: plotOrigin, proxy: proxy)
        drawingStart = nil
        drawingEnd = nil

        guard let start = startPoint else { return }
        let end = endPoint ?? start

        // Anything that needs two distinct points requires a minimum
        // drag distance, otherwise an accidental click would commit a
        // zero-size shape. ~4pt screen-space threshold.
        let dragDistSq = pow(value.translation.width, 2) + pow(value.translation.height, 2)
        let hasDrag = dragDistSq >= 16

        switch activeTool {
        case .none:
            return
        case .horizontalLine:
            // A horizontal line only needs a Y position; click *or*
            // drag works.
            onCommitDrawing?(ChartDrawing(kind: .horizontalLine, start: start, end: nil))
        case .trendLine:
            guard hasDrag else { return }
            onCommitDrawing?(ChartDrawing(kind: .trendLine, start: start, end: end))
        case .rectangle:
            guard hasDrag else { return }
            onCommitDrawing?(ChartDrawing(kind: .rectangle, start: start, end: end))
        case .volumeProfile:
            guard hasDrag else { return }
            onCommitDrawing?(ChartDrawing(kind: .volumeProfile, start: start, end: end))
        case .longPosition, .shortPosition:
            // Entry is where the drag began; its vertical extent sets
            // the stop distance so the box lands roughly where the user
            // gestured. A plain click (no drag) still commits, using a
            // default stop of 0.5% of price — otherwise a zero-height
            // position would divide by zero in the metrics.
            let dragged = abs(end.price - start.price)
            let stopDistance = dragged > 0 ? dragged : abs(start.price) * 0.005
            guard stopDistance > 0 else { return }
            // Give the box a visible width even on a click, and always
            // extend rightward regardless of drag direction.
            let rightDate = end.date > start.date
                ? end.date
                : defaultPositionRightEdge(from: start.date)
            onCommitDrawing?(ChartDrawing.position(
                long: activeTool == .longPosition,
                entry: start,
                end: DrawingPoint(date: rightDate, price: start.price),
                stopDistance: stopDistance,
                balance: defaultPositionBalance,
                riskPercent: defaultPositionRisk
            ))
        }
    }

    /// Account balance / risk % a freshly-drawn position starts with.
    /// Seeded from the Risk Calculator's stored settings so the two
    /// features agree out of the box; each position keeps its own copy
    /// afterwards and the inspector edits that.
    ///
    /// Read straight from `UserDefaults` rather than `@AppStorage`
    /// because these are only consulted inside a gesture handler —
    /// making them observable would invalidate an equatable view on
    /// every unrelated settings write.
    private var defaultPositionBalance: Double {
        let stored = UserDefaults.standard.double(forKey: "riskcalc.accountBalance")
        return stored > 0 ? stored : 10_000
    }

    private var defaultPositionRisk: Double {
        let stored = UserDefaults.standard.double(forKey: "riskcalc.riskPercent")
        return stored > 0 ? stored : 1.0
    }

    /// Right edge for a position committed without a horizontal drag —
    /// a fixed number of bars forward so the box is grabbable. Clamps to
    /// the last candle so the anchor always resolves to a real bar.
    private func defaultPositionRightEdge(from start: Date) -> Date {
        guard let startIdx = barIndex(forDate: start), !candles.isEmpty else { return start }
        let idx = min(candles.count - 1, Int(startIdx) + 20)
        return candles[idx].bucketStart
    }

    /// Drag-to-move: update the in-flight (time, price) delta. Both
    /// drawing endpoints will translate by this same delta when the
    /// chart re-renders. We compute delta in data space (rather than
    /// screen-space pixels) so the move follows the same scale as the
    /// chart's X/Y axes — important when the user has zoomed in.
    private func handleMoveChange(
        _ value: DragGesture.Value,
        plotOrigin: CGPoint,
        proxy: ChartProxy
    ) {
        guard let startPt = drawingPoint(at: value.startLocation, plotOrigin: plotOrigin, proxy: proxy),
              let nowPt   = drawingPoint(at: value.location,       plotOrigin: plotOrigin, proxy: proxy)
        else { return }
        movingDeltaTime  = nowPt.date.timeIntervalSince(startPt.date)
        movingDeltaPrice = nowPt.price - startPt.price
    }

    /// Drag-to-move: commit the translation. We rebuild the drawing
    /// (same `id`, kind, and `visible`; both endpoints offset by the
    /// accumulated delta) and hand it back to the dashboard, which
    /// calls `DrawingStore.update` to replace in place.
    private func handleMoveEnd() {
        defer {
            movingDrawingOriginal = nil
            movingDeltaTime = 0
            movingDeltaPrice = 0
        }
        guard let original = movingDrawingOriginal else { return }
        // No-op moves (a click on a drawing without dragging) shouldn't
        // round-trip through the store — saves a useless write.
        if movingDeltaTime == 0 && movingDeltaPrice == 0 { return }
        onMoveDrawing?(translated(original))
    }

    /// Apply the in-flight delta to a drawing. Used by both the live
    /// preview render and the final commit.
    /// Mutates a copy rather than rebuilding from scratch, so every
    /// field that isn't geometry (colour, line width, a position's risk
    /// settings) survives the move. Rebuilding used to silently reset
    /// the drawing's colour on every drag.
    private func translated(_ d: ChartDrawing) -> ChartDrawing {
        var copy = d
        copy.start = DrawingPoint(
            date: d.start.date.addingTimeInterval(movingDeltaTime),
            price: d.start.price + movingDeltaPrice
        )
        copy.end = d.end.map { e in
            DrawingPoint(
                date: e.date.addingTimeInterval(movingDeltaTime),
                price: e.price + movingDeltaPrice
            )
        }
        // A position's stop/target are absolute prices, not offsets, so
        // they have to travel with the entry or a drag would reshape
        // the trade instead of relocating it.
        if d.kind.isPosition {
            copy.stopPrice   = d.stopPrice.map   { $0 + movingDeltaPrice }
            copy.targetPrice = d.targetPrice.map { $0 + movingDeltaPrice }
        }
        return copy
    }

    /// Pick the topmost visible drawing within `threshold` screen
    /// points of `location`. Returns nil if nothing is close enough —
    /// lets the gesture dispatcher fall back to chart panning.
    private func hitTestDrawing(
        at location: CGPoint,
        plotOrigin: CGPoint,
        proxy: ChartProxy,
        threshold: CGFloat = 8
    ) -> ChartDrawing? {
        let p = CGPoint(x: location.x - plotOrigin.x, y: location.y - plotOrigin.y)
        // Iterate newest-last so the most-recently-drawn shape wins on
        // overlap — the user's "current" drawing is usually the one
        // they want to grab.
        var best: (ChartDrawing, CGFloat)?
        for d in drawings where d.visible {
            guard let dist = drawingDistance(d, at: p, proxy: proxy) else { continue }
            if dist <= threshold, best == nil || dist < best!.1 {
                best = (d, dist)
            }
        }
        return best?.0
    }

    /// Screen-space distance from `p` to a drawing's nearest pixel.
    /// Horizontal lines collapse to a y-distance; trend lines use
    /// point-to-segment; rectangles return 0 inside their bounds and
    /// distance-to-nearest-edge outside.
    private func drawingDistance(
        _ d: ChartDrawing,
        at p: CGPoint,
        proxy: ChartProxy
    ) -> CGFloat? {
        switch d.kind {
        case .horizontalLine:
            guard let lineY = proxy.position(forY: d.start.price) else { return nil }
            return abs(p.y - lineY)
        case .trendLine:
            guard let end = d.end,
                  let xs = barIndex(forDate: d.start.date),
                  let xe = barIndex(forDate: end.date),
                  let xsScreen: CGFloat = proxy.position(forX: xs),
                  let xeScreen: CGFloat = proxy.position(forX: xe),
                  let ysScreen = proxy.position(forY: d.start.price),
                  let yeScreen = proxy.position(forY: end.price)
            else { return nil }
            return Self.distanceToSegment(
                p,
                CGPoint(x: xsScreen, y: ysScreen),
                CGPoint(x: xeScreen, y: yeScreen)
            )
        case .rectangle:
            guard let end = d.end,
                  let xs = barIndex(forDate: d.start.date),
                  let xe = barIndex(forDate: end.date),
                  let xsScreen: CGFloat = proxy.position(forX: xs),
                  let xeScreen: CGFloat = proxy.position(forX: xe),
                  let ysScreen = proxy.position(forY: d.start.price),
                  let yeScreen = proxy.position(forY: end.price)
            else { return nil }
            let rect = CGRect(
                x: min(xsScreen, xeScreen),
                y: min(ysScreen, yeScreen),
                width:  abs(xeScreen - xsScreen),
                height: abs(yeScreen - ysScreen)
            )
            if rect.contains(p) { return 0 }
            let dx = max(rect.minX - p.x, 0, p.x - rect.maxX)
            let dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
            return hypot(dx, dy)
        case .volumeProfile:
            guard let end = d.end,
                  let xs = barIndex(forDate: d.start.date),
                  let xe = barIndex(forDate: end.date),
                  let xsScreen: CGFloat = proxy.position(forX: xs),
                  let xeScreen: CGFloat = proxy.position(forX: xe),
                  let ysScreen = proxy.position(forY: d.start.price),
                  let yeScreen = proxy.position(forY: end.price)
            else { return nil }
            let rect = CGRect(
                x: min(xsScreen, xeScreen), y: min(ysScreen, yeScreen),
                width: abs(xeScreen - xsScreen), height: abs(yeScreen - ysScreen)
            )
            if rect.contains(p) { return 0 }
            let dx = max(rect.minX - p.x, 0, p.x - rect.maxX)
            let dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
            return hypot(dx, dy)
        case .longPosition, .shortPosition:
            // Grab area spans the full box: stop edge to target edge
            // vertically, entry bar to right edge horizontally. Falls
            // back to the entry line alone if neither level is set.
            guard let end = d.end,
                  let xs = barIndex(forDate: d.start.date),
                  let xe = barIndex(forDate: end.date),
                  let xsScreen: CGFloat = proxy.position(forX: xs),
                  let xeScreen: CGFloat = proxy.position(forX: xe)
            else { return nil }
            let levels = [d.start.price, d.stopPrice, d.targetPrice].compactMap { $0 }
            guard let lo = levels.min(), let hi = levels.max(),
                  let loScreen = proxy.position(forY: lo),
                  let hiScreen = proxy.position(forY: hi)
            else { return nil }
            let rect = CGRect(
                x: min(xsScreen, xeScreen), y: min(loScreen, hiScreen),
                width: abs(xeScreen - xsScreen), height: abs(hiScreen - loScreen)
            )
            if rect.contains(p) { return 0 }
            let dx = max(rect.minX - p.x, 0, p.x - rect.maxX)
            let dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
            return hypot(dx, dy)
        }
    }

    /// Closest distance from point `p` to the line segment a–b. Used
    /// for trend-line hit testing.
    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        let projX = a.x + t * dx
        let projY = a.y + t * dy
        return hypot(p.x - projX, p.y - projY)
    }

    /// Translate a cursor location (in the gesture catcher's coord
    /// space, which is the GeometryReader's frame) into a date-anchored
    /// DrawingPoint. The X axis is bar-indexed, so we resolve the bar
    /// index from the proxy, clamp to the candle array, then look up
    /// that candle's `bucketStart` as the persisted anchor date.
    private func drawingPoint(
        at location: CGPoint,
        plotOrigin: CGPoint,
        proxy: ChartProxy
    ) -> DrawingPoint? {
        guard !candles.isEmpty else { return nil }
        let xInPlot = location.x - plotOrigin.x
        let yInPlot = location.y - plotOrigin.y
        guard let barX: Double = proxy.value(atX: xInPlot),
              let priceY: Double = proxy.value(atY: yInPlot)
        else { return nil }
        // Past either end of the series, project the date off the bar
        // spacing instead of clamping. Clamping pinned anything dragged
        // into the empty right margin onto the newest candle, so a
        // drawing could never be placed ahead of price — the usual spot
        // for a planned position.
        let lastIdx = candles.count - 1
        if let step = barIntervalSeconds {
            if barX > Double(lastIdx) {
                let ahead = barX - Double(lastIdx)
                return DrawingPoint(
                    date: candles[lastIdx].bucketStart.addingTimeInterval(ahead * step),
                    price: priceY
                )
            }
            if barX < 0 {
                return DrawingPoint(
                    date: candles[0].bucketStart.addingTimeInterval(barX * step),
                    price: priceY
                )
            }
        }
        let idx = max(0, min(lastIdx, Int(barX.rounded())))
        return DrawingPoint(date: candles[idx].bucketStart, price: priceY)
    }

    /// Resolve a persisted `Date` anchor back to its bar index on the
    /// current candle series. Returns the nearest-by-time index so a
    /// drawing made on 1h still renders sensibly when the user flips
    /// to 4h (it lands on whichever 4h bucket contains the same moment).
    /// Uses binary search — O(log n) instead of the prior O(n) linear scan.
    /// Returns nil for empty series.
    /// Seconds between consecutive bars, used to project dates past
    /// either end of the series.
    ///
    /// Takes the *median* of the recent spacings rather than the last
    /// one: a weekend or session gap sits at the end of the series
    /// often enough that the final diff is regularly 40× the true bar
    /// width, which would fling anything placed in the right margin far
    /// into the future.
    private var barIntervalSeconds: TimeInterval? {
        let n = candles.count
        guard n >= 2 else { return nil }
        var diffs: [TimeInterval] = []
        diffs.reserveCapacity(min(n - 1, 20))
        for i in max(1, n - 20)..<n {
            let d = candles[i].bucketStart.timeIntervalSince(candles[i - 1].bucketStart)
            if d > 0 { diffs.append(d) }
        }
        guard !diffs.isEmpty else { return nil }
        diffs.sort()
        return diffs[diffs.count / 2]
    }

    private func barIndex(forDate date: Date) -> Double? {
        guard !candles.isEmpty else { return nil }
        let ts = date.timeIntervalSince1970
        // Mirror of `drawingPoint`: a date outside the series maps to a
        // fractional index off the end rather than snapping to the edge
        // bar, so a drawing anchored ahead of price stays where it was
        // put instead of collapsing onto the last candle.
        if let step = barIntervalSeconds {
            let lastTS = candles[candles.count - 1].bucketStart.timeIntervalSince1970
            if ts > lastTS {
                return Double(candles.count - 1) + (ts - lastTS) / step
            }
            let firstTS = candles[0].bucketStart.timeIntervalSince1970
            if ts < firstTS {
                return (ts - firstTS) / step
            }
        }
        var lo = 0
        var hi = candles.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if candles[mid].bucketStart.timeIntervalSince1970 < ts {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        // lo is the first index >= date; check neighbours for nearest.
        if lo > 0 {
            let dLo = abs(candles[lo].bucketStart.timeIntervalSince(date))
            let dPrev = abs(candles[lo - 1].bucketStart.timeIntervalSince(date))
            if dPrev < dLo { return Double(lo - 1) }
        }
        return Double(lo)
    }

    /// Trackpad pinch-to-zoom. value > 1 ⇒ zoom in; < 1 ⇒ zoom out. We
    /// keep the centre of the current window fixed so the user's eye
    /// doesn't lose its reference point.
    private func magnificationGesture() -> some Gesture {
        MagnificationGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if magnifyStartDomain == nil {
                    magnifyStartDomain = effectiveXDomain
                    hovered = nil
                }
                guard let start = magnifyStartDomain else { return }
                let center = (start.lowerBound + start.upperBound) / 2
                let halfSpan = (start.upperBound - start.lowerBound) / 2
                // Clamp scale so a frantic pinch can't collapse the chart
                // to a point or blow it up past the entire history.
                let scale = max(0.05, min(50, Double(value)))
                let zoomedHalf = halfSpan / scale
                xDomain = (center - zoomedHalf) ... (center + zoomedHalf)
            }
            .onEnded { _ in magnifyStartDomain = nil }
    }

    /// X-domain actually handed to Charts. Falls back to the full bar
    /// span when the caller hasn't pinned a window. Adds half-bar padding
    /// at each edge so the first/last candles aren't drawn flush against
    /// the plot's vertical borders.
    private var effectiveXDomain: ClosedRange<Double> {
        if let d = xDomain { return d }
        // No pinned window → open on the most recent N bars (trading-app
        // convention) rather than dumping the entire (possibly multi-year)
        // series on screen. Pan left for history.
        return ChartWindow.defaultDomain(count: candles.count)
    }

    /// Bar indices to actually emit marks for this frame. Swift Charts
    /// draws every mark you hand it and clips afterward, so without this
    /// a deep series pins the main thread on pan/zoom. We render only the
    /// visible window (+margin), stride-decimated when zoomed way out.
    /// Marks still plot at the *global* bar index, so overlays/hover/
    /// replay keep working unchanged.
    private var renderIndices: [Int] {
        ChartWindow.renderIndices(domain: effectiveXDomain, count: candles.count)
    }

    /// News events resolved to bar indices and clipped to the visible
    /// window. Only events whose `eventAt` falls inside the loaded
    /// candle range get a bar; those outside the current pan/zoom
    /// domain are dropped so we don't draw off-screen flags. Recomputed
    /// per frame but cheap (binary search per event, and the list is
    /// already impact/currency-filtered).
    private var visibleNewsMarkers: [NewsChartMarker] {
        guard !newsEvents.isEmpty, candles.count > 1 else { return [] }
        let firstTs = candles.first!.bucketStart.timeIntervalSince1970
        // Extend the tail by one bar so an event on the latest bar still
        // qualifies (bucketStart is the bar's opening time).
        let barSpan = candles.count > 1
            ? candles[candles.count - 1].bucketStart.timeIntervalSince(candles[candles.count - 2].bucketStart)
            : 60
        let lastTs = candles.last!.bucketStart.timeIntervalSince1970 + max(barSpan, 1)
        let domain = effectiveXDomain
        var markers: [NewsChartMarker] = []
        for ev in newsEvents {
            guard let at = ev.eventAt else { continue }
            let ts = at.timeIntervalSince1970
            guard ts >= firstTs, ts <= lastTs else { continue }
            guard let bx = barIndex(forDate: at) else { continue }
            guard bx >= domain.lowerBound - 1, bx <= domain.upperBound + 1 else { continue }
            markers.append(NewsChartMarker(id: ev.id, barIndex: bx, event: ev))
        }
        return markers
    }

    // MARK: - Mark variants

    @ChartContentBuilder
    private var dayBoundaryMarks: some ChartContent {
        ForEach(
            ChartWindow.dayBoundaryPositions(candles: candles, domain: effectiveXDomain),
            id: \.self
        ) { x in
            RuleMark(x: .value("Day boundary", x))
                .foregroundStyle(Theme.Color.textMuted.opacity(0.20))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
    }

    @ChartContentBuilder
    private func lineMarks(indices: [Int]) -> some ChartContent {
        // Evaluate `displayCandles` ONCE here. It's a computed property
        // that rebuilds (HA transform + live-price array copy) on every
        // access, so indexing it inside the ForEach closure would re-run
        // that O(n) work per visible bar — quadratic on deep history.
        let cs = displayCandles
        ForEach(indices, id: \.self) { i in
            let c = cs[i]
            AreaMark(
                x: .value("Bar", Double(i)),
                y: .value("Close", c.close)
            )
            .foregroundStyle(LinearGradient(
                colors: [accent.opacity(0.4), accent.opacity(0)],
                startPoint: .top, endPoint: .bottom
            ))
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("Bar", Double(i)),
                y: .value("Close", c.close)
            )
            .foregroundStyle(accent)
            .lineStyle(StrokeStyle(lineWidth: 1.8, lineJoin: .round))
            .interpolationMethod(.monotone)
        }
        // Single-point series can't draw a line — drop a visible marker.
        if cs.count == 1, let only = cs.first {
            PointMark(
                x: .value("Bar", 0.0),
                y: .value("Close", only.close)
            )
            .foregroundStyle(accent)
            .symbolSize(120)
        }
    }

    /// Horizontal lines for support / resistance levels carried in
    /// `srLevels`. Support is green, resistance red; each gets a small
    /// "S" / "R" capsule at the right edge as a price tag.
    @ChartContentBuilder
    private var srLevelMarks: some ChartContent {
        ForEach(srLevels.support, id: \.self) { level in
            RuleMark(y: .value("Support", level))
                .foregroundStyle(Theme.Color.success.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 4]))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    srTag(price: level, isSupport: true)
                }
        }
        ForEach(srLevels.resistance, id: \.self) { level in
            RuleMark(y: .value("Resistance", level))
                .foregroundStyle(Theme.Color.danger.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 4]))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    srTag(price: level, isSupport: false)
                }
        }
    }

    /// FVG / iFVG zones rendered as translucent rectangles spanning the
    /// gap's three-candle bar range and its price band. Bullish gaps
    /// fill green; bearish fill red. iFVG (mitigated) zones overlay
    /// dashed top/bottom edges since `RectangleMark` has no native
    /// dashed stroke API.
    @ChartContentBuilder
    private var fvgMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(fvgZones) { zone in
            // Translate negative bar offsets (-1 = latest bar) onto the
            // chart's index X axis.
            let xStart = Double(lastIndex + zone.barOffsetStart)
            let xEnd   = Double(lastIndex + zone.barOffsetEnd)
            RectangleMark(
                xStart: .value("FVG start", xStart),
                xEnd:   .value("FVG end",   xEnd),
                yStart: .value("Zone low",  zone.low),
                yEnd:   .value("Zone high", zone.high)
            )
            .foregroundStyle((zone.isBullish ? Theme.Color.success : Theme.Color.danger)
                              .opacity(zone.isMitigated ? 0.10 : 0.18))
            if zone.isMitigated {
                // Dashed boundary lines for iFVG candidates so the user
                // can tell them apart from active FVGs at a glance.
                RuleMark(
                    xStart: .value("iFVG start hi", xStart),
                    xEnd:   .value("iFVG end hi",   xEnd),
                    y:      .value("iFVG hi",       zone.high)
                )
                .foregroundStyle((zone.isBullish ? Theme.Color.success : Theme.Color.danger).opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                RuleMark(
                    xStart: .value("iFVG start lo", xStart),
                    xEnd:   .value("iFVG end lo",   xEnd),
                    y:      .value("iFVG lo",       zone.low)
                )
                .foregroundStyle((zone.isBullish ? Theme.Color.success : Theme.Color.danger).opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
    }

    /// Supply & Demand zones rendered as translucent rectangles + a
    /// small "D" / "S" capsule pinned to the zone's right edge so
    /// the user can read intent without the legend. Strong zones
    /// get a thicker rule on top/bottom for emphasis; tested
    /// (`!isFresh`) zones drop to half opacity + dashed boundary
    /// since a re-entry on a tested zone is statistically weaker
    /// than a first test.
    @ChartContentBuilder
    private var supplyDemandMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(supplyDemandZones) { zone in
            let xStart = Double(lastIndex + zone.barOffsetStart)
            let xEnd   = Double(lastIndex + zone.barOffsetEnd)
            let baseColor: Color = zone.isDemand ? Theme.Color.success : Theme.Color.danger
            let fillOpacity: Double = {
                if !zone.isFresh { return 0.10 }
                switch zone.strength {
                case .weak:   return 0.14
                case .medium: return 0.20
                case .strong: return 0.28
                }
            }()
            RectangleMark(
                xStart: .value("Zone start", xStart),
                xEnd:   .value("Zone end",   xEnd),
                yStart: .value("Zone low",   zone.low),
                yEnd:   .value("Zone high",  zone.high)
            )
            .foregroundStyle(baseColor.opacity(fillOpacity))

            // Top + bottom boundary lines so the zone's edges
            // read clearly against the candles inside it. Solid
            // for fresh, dashed for tested. Line width scales
            // with strength.
            let lineWidth: CGFloat = {
                switch zone.strength {
                case .weak:   return 0.8
                case .medium: return 1.2
                case .strong: return 1.8
                }
            }()
            let dashStyle: [CGFloat] = zone.isFresh ? [] : [4, 3]
            RuleMark(
                xStart: .value("Zone start hi", xStart),
                xEnd:   .value("Zone end hi",   xEnd),
                y:      .value("Zone hi",       zone.high)
            )
            .foregroundStyle(baseColor.opacity(zone.isFresh ? 0.75 : 0.5))
            .lineStyle(StrokeStyle(lineWidth: lineWidth, dash: dashStyle))
            RuleMark(
                xStart: .value("Zone start lo", xStart),
                xEnd:   .value("Zone end lo",   xEnd),
                y:      .value("Zone lo",       zone.low)
            )
            .foregroundStyle(baseColor.opacity(zone.isFresh ? 0.75 : 0.5))
            .lineStyle(StrokeStyle(lineWidth: lineWidth, dash: dashStyle))

            // Tiny capsule at the right edge of the zone showing
            // direction + strength. "D⋅strong" / "S⋅medium" etc.
            // Sits on the high boundary so it doesn't crowd the
            // price action inside the zone.
            PointMark(
                x: .value("Zone end label", xEnd),
                y: .value("Zone hi",        zone.high)
            )
            .symbolSize(0)   // invisible anchor; we just want the annotation
            .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                Text("\(zone.isDemand ? "D" : "S")·\(zone.strength.rawValue.prefix(1).uppercased())")
                    .font(.system(size: 8, weight: .heavy).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(baseColor.opacity(zone.isFresh ? 0.95 : 0.6))
                    )
            }
        }
    }

    /// Trading-session overlays — one translucent high-low box per
    /// *current-day* session (see `sessionRuns`), with dotted high/low/
    /// average reference lines that run through to the live edge, optional
    /// dashed open/close lines, and a corner label (range / average /
    /// name). Each session keeps its own hue. The box itself is confined
    /// to the session's own bar range (`start...end`), but the high/low/
    /// average lines extend past it to the last bar on the chart — so
    /// e.g. Tokyo's range is still visible, dotted, in Tokyo's colour,
    /// while London or New York are trading. Mirrors the Pine "Trading
    /// Sessions" study, extended with the cross-session reference lines.
    /// The display toggles come from `indicatorConfig`.
    @ChartContentBuilder
    private var sessionMarks: some ChartContent {
        let cfg = indicatorConfig
        let lineEnd = Double(max(candles.count - 1, 0))
        ForEach(sessionRuns) { run in
            let xStart = Double(run.start)
            let xEnd   = Double(run.end)

            // The session's high-low region — low opacity so candles read
            // through it. Confined to the session's own bars, unlike the
            // high/low lines below.
            RectangleMark(
                xStart: .value("Session start", xStart),
                xEnd:   .value("Session end",   xEnd),
                yStart: .value("Session low",   run.low),
                yEnd:   .value("Session high",  run.high)
            )
            .foregroundStyle(run.color.opacity(0.12))

            // High & low as dotted reference lines carried through to the
            // live edge, in the session's own colour.
            RuleMark(
                xStart: .value("Sess high start", xStart),
                xEnd:   .value("Sess high end",   lineEnd),
                y:      .value("Sess high",       run.high)
            )
            .foregroundStyle(run.color.opacity(0.7))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [1, 3]))
            RuleMark(
                xStart: .value("Sess low start", xStart),
                xEnd:   .value("Sess low end",   lineEnd),
                y:      .value("Sess low",        run.low)
            )
            .foregroundStyle(run.color.opacity(0.7))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [1, 3]))

            if cfg.sessShowOpenClose {
                // Open & close as dashed rules spanning the session.
                RuleMark(
                    xStart: .value("Sess open start", xStart),
                    xEnd:   .value("Sess open end",   xEnd),
                    y:      .value("Sess open",       run.open)
                )
                .foregroundStyle(run.color.opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                RuleMark(
                    xStart: .value("Sess close start", xStart),
                    xEnd:   .value("Sess close end",   xEnd),
                    y:      .value("Sess close",       run.close)
                )
                .foregroundStyle(run.color.opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }

            if cfg.sessShowAverage {
                // Mean close — the Pine source's dotted average (middle)
                // line, carried through to the live edge like high/low.
                RuleMark(
                    xStart: .value("Sess avg start", xStart),
                    xEnd:   .value("Sess avg end",   lineEnd),
                    y:      .value("Sess avg",       run.average)
                )
                .foregroundStyle(run.color.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [1, 3]))
            }

            // Corner label at the box's lower-left, built from whichever
            // of range / average / name the user enabled.
            if let text = sessionLabelText(run) {
                PointMark(
                    x: .value("Sess label x", xStart),
                    y: .value("Sess label y", run.low)
                )
                .symbolSize(0)
                .annotation(position: .bottom, alignment: .leading, spacing: 1) {
                    Text(text)
                        .font(.system(size: 8, weight: .bold).monospacedDigit())
                        .foregroundStyle(run.color)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.Color.surfaceMax.opacity(0.7))
                        )
                        .fixedSize()
                }
            }
        }
    }

    /// Multi-line session label from the enabled display toggles, matching
    /// the Pine's "Range / Avg / Name" stack. nil when nothing is enabled
    /// (so we don't draw an empty chip).
    private func sessionLabelText(_ run: TradingSessions.SessionRun) -> String? {
        var lines: [String] = []
        if indicatorConfig.sessShowRange   { lines.append("Rng \(Self.priceShort(run.range))") }
        if indicatorConfig.sessShowAverage { lines.append("Avg \(Self.priceShort(run.average))") }
        if indicatorConfig.sessShowNames   { lines.append(run.name) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// NY Open Setup overlay — the opening-range box + high/low rays, and
    /// (once a breakout fires) the FVG gap plus the entry / SL / TP plan.
    /// Direction tints the OR + entry green (long) / red (short); a
    /// resolved plan ends its lines at the TP/SL bar, a live plan runs to
    /// the chart edge. Drawn behind the candles like the other zone
    /// overlays. See `NYOpenSetup` for the detection logic.
    @ChartContentBuilder
    private var setupMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(nySetupResults) { r in
            let dirColor = setupDirectionColor(r.direction)
            let orStart = Double(r.orStartIndex)
            let orEnd   = Double(r.orEndIndex)
            let rayEnd  = Double(r.resolveIndex ?? lastIndex)

            // Opening-range box.
            RectangleMark(
                xStart: .value("OR start", orStart),
                xEnd:   .value("OR end",   orEnd),
                yStart: .value("OR low",   r.orLow),
                yEnd:   .value("OR high",  r.orHigh)
            )
            .foregroundStyle(dirColor.opacity(0.14))

            // OR high/low reference rays — the breakout levels.
            RuleMark(xStart: .value("ORH s", orStart), xEnd: .value("ORH e", rayEnd),
                     y: .value("OR high", r.orHigh))
            .foregroundStyle(dirColor.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            RuleMark(xStart: .value("ORL s", orStart), xEnd: .value("ORL e", rayEnd),
                     y: .value("OR low", r.orLow))
            .foregroundStyle(dirColor.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))

            // Range-edge labels at the opening range's left side — "NY High"
            // above the high, "NY Low" below the low.
            PointMark(x: .value("NY High x", orStart), y: .value("NY High y", r.orHigh))
                .symbolSize(0)
                .annotation(position: .top, alignment: .leading, spacing: 1) {
                    setupTag("NY High", color: dirColor)
                }
            PointMark(x: .value("NY Low x", orStart), y: .value("NY Low y", r.orLow))
                .symbolSize(0)
                .annotation(position: .bottom, alignment: .leading, spacing: 1) {
                    setupTag("NY Low", color: dirColor)
                }

            // Breakout plan: FVG gap + entry/SL/TP, once a setup is found.
            if r.hasPlan,
               let fvgS = r.fvgStartIndex, let fvgE = r.fvgEndIndex,
               let fLo = r.fvgLow, let fHi = r.fvgHigh,
               let entry = r.entry, let sl = r.stopLoss, let tp = r.takeProfit {
                let planStart = Double(fvgE)
                let planEnd   = Double(r.resolveIndex ?? lastIndex)

                // The fair-value gap the breakout left behind.
                RectangleMark(
                    xStart: .value("FVG s", Double(fvgS)),
                    xEnd:   .value("FVG e", Double(fvgE)),
                    yStart: .value("FVG lo", fLo),
                    yEnd:   .value("FVG hi", fHi)
                )
                .foregroundStyle(dirColor.opacity(0.22))

                // Entry (dashed, direction-tinted), SL (red), TP (green).
                RuleMark(xStart: .value("E s", planStart), xEnd: .value("E e", planEnd),
                         y: .value("Entry", entry))
                .foregroundStyle(dirColor.opacity(0.9))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                RuleMark(xStart: .value("SL s", planStart), xEnd: .value("SL e", planEnd),
                         y: .value("SL", sl))
                .foregroundStyle(Theme.Color.danger.opacity(0.9))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                RuleMark(xStart: .value("TP s", planStart), xEnd: .value("TP e", planEnd),
                         y: .value("TP", tp))
                .foregroundStyle(Theme.Color.success.opacity(0.9))
                .lineStyle(StrokeStyle(lineWidth: 1.5))

                // Level labels at the plan's right end. Entry carries the
                // direction arrow + its tint; SL is red, TP green — matching
                // each line so the meaning reads at a glance.
                PointMark(x: .value("Entry lbl x", planEnd), y: .value("Entry lbl y", entry))
                    .symbolSize(0)
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        setupTag("Entry \(r.direction == .long ? "↑" : "↓")", color: dirColor)
                    }
                PointMark(x: .value("SL lbl x", planEnd), y: .value("SL lbl y", sl))
                    .symbolSize(0)
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        setupTag("SL", color: Theme.Color.danger)
                    }
                PointMark(x: .value("TP lbl x", planEnd), y: .value("TP lbl y", tp))
                    .symbolSize(0)
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        setupTag("TP", color: Theme.Color.success)
                    }

                // Retest fill marker.
                if let rt = r.retestIndex {
                    PointMark(x: .value("retest x", Double(rt)), y: .value("retest y", entry))
                        .symbolSize(40)
                        .foregroundStyle(dirColor)
                }
            }
        }
    }

    /// SP2L overlay — shows balance-break pressure, the resting first-
    /// pullback limit, SL and TP target.
    @ChartContentBuilder
    private var sp2lMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(sp2lResults) { r in
            let dirColor = sp2lDirectionColor(r.direction)
            let spikeStart = Double(r.spikeStartIndex)
            let spikeEnd = Double(r.spikeEndIndex)
            let planStart = Double(r.spikeEndIndex)
            let planEnd = Double(r.resolveIndex ?? lastIndex)

            RuleMark(
                xStart: .value("SP2L level start", Double(r.levelStartIndex)),
                xEnd: .value("SP2L level end", Double(r.followThroughIndex)),
                y: .value("SP2L broken level", r.brokenLevel)
            )
            .foregroundStyle(dirColor.opacity(0.85))
            .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [5, 3]))

            PointMark(
                x: .value("SP2L level label x", Double(r.levelStartIndex)),
                y: .value("SP2L level label y", r.brokenLevel)
            )
            .symbolSize(0)
            .annotation(position: .overlay, alignment: .leading, spacing: 0) {
                setupTag("Broken level", color: dirColor)
            }

            RectangleMark(
                xStart: .value("SP2L spike start", spikeStart),
                xEnd: .value("SP2L spike end", spikeEnd),
                yStart: .value("SP2L spike low", r.spikeLow),
                yEnd: .value("SP2L spike high", r.spikeHigh)
            )
            .foregroundStyle(dirColor.opacity(0.10))

            PointMark(
                x: .value("SP2L label x", spikeStart),
                y: .value("SP2L label y", r.spikeHigh)
            )
            .symbolSize(0)
            .annotation(position: .top, alignment: .leading, spacing: 1) {
                let direction = r.direction == .long ? "LONG" : "SHORT"
                let state = r.entryIndex == nil ? "SETUP" : "ENTRY"
                setupTag("SP2L \(state) \(direction)", color: dirColor)
            }

            if let entryIndex = r.entryIndex {
                PointMark(
                    x: .value("SP2L confirmed entry candle", Double(entryIndex)),
                    y: .value("SP2L confirmed entry price", r.entry)
                )
                .foregroundStyle(dirColor)
                .symbolSize(65)
                .annotation(position: .top, alignment: .center, spacing: 4) {
                    setupTag("ENTRY", color: dirColor)
                }
            }

            if let ema = r.emaValue {
                RuleMark(
                    xStart: .value("SP2L EMA start", spikeStart),
                    xEnd: .value("SP2L EMA end", spikeEnd),
                    y: .value("SP2L EMA context", ema)
                )
                .foregroundStyle(Theme.Color.warn.opacity(0.75))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }

            if r.hasPlan {
                let entry = r.entry
                let sl = r.stopLoss
                let targets = r.takeProfits(count: indicatorConfig.sp2lTargetCount)
                let isFilled = r.entryIndex != nil
                let entryOpacity = isFilled ? 0.9 : 0.55
                let entryDash: [CGFloat] = isFilled ? [5, 3] : [2, 4]

                RuleMark(
                    xStart: .value("SP2L entry start", planStart),
                    xEnd: .value("SP2L entry end", planEnd),
                    y: .value("SP2L entry", entry)
                )
                .foregroundStyle(dirColor.opacity(entryOpacity))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: entryDash))

                RuleMark(
                    xStart: .value("SP2L SL start", planStart),
                    xEnd: .value("SP2L SL end", planEnd),
                    y: .value("SP2L SL", sl)
                )
                .foregroundStyle(Theme.Color.danger.opacity(0.9))
                .lineStyle(StrokeStyle(lineWidth: 1.4))

                ForEach(Array(targets.enumerated()), id: \.offset) { offset, target in
                    RuleMark(
                        xStart: .value("SP2L TP\(offset + 1) start", planStart),
                        xEnd: .value("SP2L TP\(offset + 1) end", planEnd),
                        y: .value("SP2L TP\(offset + 1)", target)
                    )
                    .foregroundStyle(Theme.Color.success.opacity(0.9 - Double(offset) * 0.12))
                    .lineStyle(StrokeStyle(lineWidth: 1.4, dash: offset == 0 ? [] : [5, 3]))
                }

                if r.stage == .limitPending {
                    PointMark(
                        x: .value("SP2L pending label x", planEnd),
                        y: .value("SP2L pending label y", entry)
                    )
                    .symbolSize(0)
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        setupTag("Wait confirmation", color: dirColor)
                    }
                }
                PointMark(
                    x: .value("SP2L SL label x", planEnd),
                    y: .value("SP2L SL label y", sl)
                )
                .symbolSize(0)
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    setupTag("SL", color: Theme.Color.danger)
                }
                ForEach(Array(targets.enumerated()), id: \.offset) { offset, target in
                    PointMark(
                        x: .value("SP2L TP\(offset + 1) label x", planEnd),
                        y: .value("SP2L TP\(offset + 1) label y", target)
                    )
                    .symbolSize(0)
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        let ratio = indicatorConfig.sp2lRiskReward * Double(offset + 1)
                        setupTag(
                            "TP\(offset + 1) R\(String(format: "%.2g", ratio))",
                            color: Theme.Color.success
                        )
                    }
                }

            }
        }
    }

    /// Pin-bar confirmation overlay for SP2L and BTB. The tested level is
    /// kept visible from breakout through resolution, while the rejection
    /// candle anchors the entry/SL/TP plan.
    @ChartContentBuilder
    private var pinBarComboMarks: some ChartContent {
        let lastIndex = max(0, candles.count - 1)
        ForEach(pinBarComboResults) { result in
            let color = pinBarComboColor(result.direction)
            let start = Double(result.breakoutIndex)
            let confirmation = Double(result.confirmationIndex)
            let end = Double(result.resolveIndex ?? lastIndex)

            RuleMark(
                xStart: .value("Pin Bar level start", start),
                xEnd: .value("Pin Bar level end", end),
                y: .value("Pin Bar tested level", result.level)
            )
            .foregroundStyle(IndicatorKind.pinBarCombo.color.opacity(0.75))
            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 3]))

            RectangleMark(
                xStart: .value("Pin Bar candle start", confirmation - 0.34),
                xEnd: .value("Pin Bar candle end", confirmation + 0.34),
                yStart: .value("Pin Bar low", result.pinBarLow),
                yEnd: .value("Pin Bar high", result.pinBarHigh)
            )
            .foregroundStyle(color.opacity(0.16))

            PointMark(
                x: .value("Pin Bar confirmation x", confirmation),
                y: .value(
                    "Pin Bar confirmation y",
                    result.direction == .long ? result.pinBarLow : result.pinBarHigh
                )
            )
            .symbolSize(68)
            .foregroundStyle(color)
            .annotation(
                position: result.direction == .long ? .bottom : .top,
                alignment: .center,
                spacing: 3
            ) {
                setupTag(
                    result.kind == .sp2l ? "PIN · SP2L" : "PIN · BTB",
                    color: color
                )
            }

            RuleMark(
                xStart: .value("Pin Bar entry start", confirmation),
                xEnd: .value("Pin Bar entry end", end),
                y: .value("Pin Bar entry", result.entry)
            )
            .foregroundStyle(color.opacity(0.95))
            .lineStyle(StrokeStyle(lineWidth: 1.5))

            RuleMark(
                xStart: .value("Pin Bar SL start", confirmation),
                xEnd: .value("Pin Bar SL end", end),
                y: .value("Pin Bar SL", result.stopLoss)
            )
            .foregroundStyle(Theme.Color.danger.opacity(0.9))
            .lineStyle(StrokeStyle(lineWidth: 1.2))

            RuleMark(
                xStart: .value("Pin Bar TP start", confirmation),
                xEnd: .value("Pin Bar TP end", end),
                y: .value("Pin Bar TP", result.takeProfit)
            )
            .foregroundStyle(Theme.Color.success.opacity(0.9))
            .lineStyle(StrokeStyle(lineWidth: 1.2))

            PointMark(
                x: .value("Pin Bar entry label x", end),
                y: .value("Pin Bar entry label y", result.entry)
            )
            .symbolSize(0)
            .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                setupTag(pinBarComboStatusLabel(result), color: color)
            }

            PointMark(
                x: .value("Pin Bar SL label x", end),
                y: .value("Pin Bar SL label y", result.stopLoss)
            )
            .symbolSize(0)
            .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                setupTag("SL", color: Theme.Color.danger)
            }

            PointMark(
                x: .value("Pin Bar TP label x", end),
                y: .value("Pin Bar TP label y", result.takeProfit)
            )
            .symbolSize(0)
            .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                setupTag(
                    "TP R\(String(format: "%.2g", indicatorConfig.pinBarRiskReward))",
                    color: Theme.Color.success
                )
            }
        }
    }

    /// MicroMap overlay: spike context, micro-channel structure and the
    /// lifecycle of each close-confirmed attempt.
    @ChartContentBuilder
    private var microMapMarks: some ChartContent {
        let lastIndex = max(0, candles.count - 1)
        ForEach(microMapResults) { result in
            let color = microMapDirectionColor(result.direction)
            RectangleMark(
                xStart: .value("MicroMap spike start", Double(result.spikeStartIndex)),
                xEnd: .value("MicroMap spike end", Double(result.spikeEndIndex)),
                yStart: .value("MicroMap spike low", result.spikeLow),
                yEnd: .value("MicroMap spike high", result.spikeHigh)
            )
            .foregroundStyle(color.opacity(0.09))

            if let gap = result.confluence.pressureGap {
                RectangleMark(
                    xStart: .value("MicroMap pressure gap start", Double(gap.startIndex)),
                    xEnd: .value("MicroMap pressure gap end", Double(gap.endIndex)),
                    yStart: .value("MicroMap pressure gap low", gap.low),
                    yEnd: .value("MicroMap pressure gap high", gap.high)
                )
                .foregroundStyle(Theme.Color.accentStart.opacity(0.20))
            }

            ForEach(Array(result.microStartIndex...result.microEndIndex), id: \.self) { index in
                LineMark(
                    x: .value("MicroMap channel bar", Double(index)),
                    y: .value(
                        "MicroMap channel structure",
                        result.direction == .long ? candles[index].high : candles[index].low
                    ),
                    series: .value("MicroMap channel", "micromap-\(result.id)")
                )
                .foregroundStyle(color.opacity(0.75))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
            }

            PointMark(
                x: .value("MicroMap title x", Double(result.spikeStartIndex)),
                y: .value("MicroMap title y", result.spikeHigh)
            )
            .symbolSize(0)
            .annotation(position: .top, alignment: .leading, spacing: 1) {
                setupTag(
                    microMapTitle(result),
                    color: color
                )
            }

            ForEach(result.attempts) { attempt in
                let planStart = Double(attempt.anchorIndex ?? result.microEndIndex)
                let planEnd = Double(
                    attempt.targetIndex
                        ?? attempt.stopIndex
                        ?? result.endIndex
                        ?? lastIndex
                )
                let opacity = microMapAttemptOpacity(attempt.status)
                let dash = microMapAttemptDash(attempt.status)

                if let entry = attempt.entry,
                   let stop = attempt.stopLoss,
                   let target = attempt.takeProfit {
                    RuleMark(
                        xStart: .value("MicroMap entry start", planStart),
                        xEnd: .value("MicroMap entry end", planEnd),
                        y: .value("MicroMap entry", entry)
                    )
                    .foregroundStyle(color.opacity(opacity))
                    .lineStyle(StrokeStyle(lineWidth: attempt.status == .active ? 1.8 : 1.2, dash: dash))

                    RuleMark(
                        xStart: .value("MicroMap stop start", planStart),
                        xEnd: .value("MicroMap stop end", planEnd),
                        y: .value("MicroMap stop", stop)
                    )
                    .foregroundStyle(Theme.Color.danger.opacity(opacity))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: dash))

                    RuleMark(
                        xStart: .value("MicroMap target start", planStart),
                        xEnd: .value("MicroMap target end", planEnd),
                        y: .value("MicroMap target", target)
                    )
                    .foregroundStyle(Theme.Color.success.opacity(opacity))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: dash))

                    PointMark(
                        x: .value("MicroMap entry label x", planEnd),
                        y: .value("MicroMap entry label y", entry)
                    )
                    .symbolSize(0)
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        setupTag("Entry \(attempt.number)", color: color.opacity(opacity))
                    }
                } else {
                    RuleMark(
                        xStart: .value("MicroMap waiting start", planStart),
                        xEnd: .value("MicroMap waiting end", planEnd),
                        y: .value("MicroMap waiting trigger", attempt.triggerLevel)
                    )
                    .foregroundStyle(color.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 4]))

                    PointMark(
                        x: .value("MicroMap pending label x", planEnd),
                        y: .value("MicroMap pending label y", attempt.triggerLevel)
                    )
                    .symbolSize(0)
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        setupTag("Entry \(attempt.number) pending", color: color.opacity(0.7))
                    }
                }

                if let trigger = attempt.triggerIndex, let entry = attempt.entry {
                    PointMark(
                        x: .value("MicroMap fill x", Double(trigger)),
                        y: .value("MicroMap fill y", entry)
                    )
                    .symbolSize(46)
                    .foregroundStyle(color.opacity(opacity))
                }
            }

            if result.stage == .invalidated, let end = result.endIndex {
                PointMark(
                    x: .value("MicroMap invalid x", Double(end)),
                    y: .value(
                        "MicroMap invalid y",
                        result.direction == .long ? candles[end].low : candles[end].high
                    )
                )
                .symbolSize(60)
                .foregroundStyle(Theme.Color.danger)
                .annotation(
                    position: result.direction == .long ? .bottom : .top,
                    alignment: .center,
                    spacing: 2
                ) {
                    setupTag("INVALID x3", color: Theme.Color.danger)
                }
            }
        }
    }

    /// Major Trend Reversal overlay: prior channel, old extreme, second
    /// test, neckline confirmation and the resulting trade plan.
    @ChartContentBuilder
    private var mtrMarks: some ChartContent {
        let lastIndex = max(0, candles.count - 1)
        ForEach(mtrResults) { result in
            let color = mtrDirectionColor(result.direction)
            let isForming = result.stage == .forming
            let opacity = isForming ? 0.55 : (result.stage == .expired ? 0.30 : 0.90)
            let channelDelta = result.channelEndIndex - result.channelStartIndex
            let slope = channelDelta == 0 ? 0 :
                (result.channelEndPrice - result.channelStartPrice) / Double(channelDelta)
            let projectedMain = result.channelStartPrice
                + slope * Double(result.breakoutIndex - result.channelStartIndex)
            let parallelOffset = result.parallelStartPrice - result.channelStartPrice
            let projectedParallel = projectedMain + parallelOffset
            let planEnd = Double(result.resolveIndex ?? lastIndex)

            ForEach([0, 1], id: \.self) { endpoint in
                LineMark(
                    x: .value(
                        "MTR channel x",
                        endpoint == 0 ? Double(result.channelStartIndex) : Double(result.breakoutIndex)
                    ),
                    y: .value(
                        "MTR channel y",
                        endpoint == 0 ? result.channelStartPrice : projectedMain
                    ),
                    series: .value("MTR channel series", "mtr-main-\(result.id)")
                )
                .foregroundStyle(IndicatorKind.mtrStrategy.color.opacity(opacity))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))

                LineMark(
                    x: .value(
                        "MTR parallel x",
                        endpoint == 0 ? Double(result.channelStartIndex) : Double(result.breakoutIndex)
                    ),
                    y: .value(
                        "MTR parallel y",
                        endpoint == 0 ? result.parallelStartPrice : projectedParallel
                    ),
                    series: .value("MTR parallel series", "mtr-parallel-\(result.id)")
                )
                .foregroundStyle(IndicatorKind.mtrStrategy.color.opacity(opacity * 0.65))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            RuleMark(
                xStart: .value("MTR old extreme start", Double(result.trendExtremeIndex)),
                xEnd: .value("MTR old extreme end", Double(result.retestIndex)),
                y: .value("MTR old extreme", result.trendExtremePrice)
            )
            .foregroundStyle(color.opacity(opacity * 0.65))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))

            RuleMark(
                xStart: .value("MTR neckline start", Double(result.breakoutIndex)),
                xEnd: .value("MTR neckline end", planEnd),
                y: .value("MTR neckline", result.neckline)
            )
            .foregroundStyle(color.opacity(opacity))
            .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [5, 3]))

            PointMark(
                x: .value("MTR retest x", Double(result.retestIndex)),
                y: .value("MTR retest y", result.retestPrice)
            )
            .symbolSize(isForming ? 54 : 72)
            .foregroundStyle(color.opacity(opacity))
            .annotation(
                position: result.direction == .long ? .bottom : .top,
                alignment: .center,
                spacing: 3
            ) {
                setupTag("MTR · \(result.variant.label)", color: color.opacity(opacity))
            }

            if let confirmation = result.confirmationIndex {
                PointMark(
                    x: .value("MTR confirmation x", Double(confirmation)),
                    y: .value("MTR confirmation y", candles[confirmation].close)
                )
                .symbolSize(82)
                .foregroundStyle(color)
                .annotation(
                    position: result.direction == .long ? .top : .bottom,
                    alignment: .center,
                    spacing: 3
                ) {
                    setupTag(
                        result.direction == .long ? "MTR LONG confirmed" : "MTR SHORT confirmed",
                        color: color
                    )
                }
            }

            if let entry = result.entry,
               let stop = result.stopLoss,
               let target = result.takeProfit,
               let confirmation = result.confirmationIndex {
                let planStart = Double(confirmation)
                RuleMark(
                    xStart: .value("MTR entry start", planStart),
                    xEnd: .value("MTR entry end", planEnd),
                    y: .value("MTR entry", entry)
                )
                .foregroundStyle(color.opacity(opacity))
                .lineStyle(StrokeStyle(lineWidth: 1.5))

                RuleMark(
                    xStart: .value("MTR stop start", planStart),
                    xEnd: .value("MTR stop end", planEnd),
                    y: .value("MTR stop", stop)
                )
                .foregroundStyle(Theme.Color.danger.opacity(opacity))
                .lineStyle(StrokeStyle(lineWidth: 1.3))

                RuleMark(
                    xStart: .value("MTR target start", planStart),
                    xEnd: .value("MTR target end", planEnd),
                    y: .value("MTR target", target)
                )
                .foregroundStyle(Theme.Color.success.opacity(opacity))
                .lineStyle(StrokeStyle(lineWidth: 1.3))

                PointMark(x: .value("MTR status x", planEnd), y: .value("MTR status y", entry))
                    .symbolSize(0)
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        setupTag(mtrStatusLabel(result), color: color.opacity(opacity))
                    }
                PointMark(x: .value("MTR SL x", planEnd), y: .value("MTR SL y", stop))
                    .symbolSize(0)
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        setupTag("SL", color: Theme.Color.danger.opacity(opacity))
                    }
                PointMark(x: .value("MTR TP x", planEnd), y: .value("MTR TP y", target))
                    .symbolSize(0)
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        setupTag(
                            "TP R\(String(format: "%.2g", indicatorConfig.mtrRiskReward))",
                            color: Theme.Color.success.opacity(opacity)
                        )
                    }
            }
        }
    }

    private func mtrDirectionColor(_ direction: MTRSetup.Direction) -> Color {
        direction == .long ? Theme.Color.success : Theme.Color.danger
    }

    @ChartContentBuilder
    private var notificationFocusMarks: some ChartContent {
        if let focus = notificationFocus,
           let index = barIndex(closestTo: focus.candleDate) {
            RuleMark(x: .value("Notification candle", Double(index)))
                .foregroundStyle(Theme.Color.accentStart.opacity(0.65))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))

            PointMark(
                x: .value("Notification x", Double(index)),
                y: .value("Notification price", focus.price)
            )
            .symbolSize(150)
            .foregroundStyle(Theme.Color.accentStart)
            .annotation(position: .top, alignment: .center, spacing: 5) {
                setupTag(focus.label, color: Theme.Color.accentStart)
            }
        }
    }

    private func mtrStatusLabel(_ result: MTRSetup.Result) -> String {
        switch result.stage {
        case .forming: return "MTR forming"
        case .confirmed: return result.direction == .long ? "LONG active" : "SHORT active"
        case .hitTP: return "Target hit"
        case .hitSL: return "Stopped"
        case .expired: return "Expired"
        }
    }

    private func microMapDirectionColor(_ direction: MicroMapSetup.Direction) -> Color {
        direction == .long ? Theme.Color.success : Theme.Color.danger
    }

    private func microMapTitle(_ result: MicroMapSetup.Result) -> String {
        let direction = result.direction == .long ? "LONG" : "SHORT"
        let quality: String
        switch result.confluence.quality {
        case .standard: quality = "STANDARD"
        case .confirmed: quality = "CONFIRMED"
        case .strong: quality = "STRONG"
        }
        return "MICROMAP \(direction) · \(quality) \(result.confluence.score)/6"
    }

    private func microMapAttemptOpacity(_ status: MicroMapSetup.AttemptStatus) -> Double {
        switch status {
        case .waiting: return 0.55
        case .active: return 0.95
        case .stopped: return 0.35
        case .succeeded: return 0.85
        }
    }

    private func microMapAttemptDash(_ status: MicroMapSetup.AttemptStatus) -> [CGFloat] {
        switch status {
        case .waiting: return [3, 4]
        case .active, .succeeded: return []
        case .stopped: return [2, 3]
        }
    }

    private func setupDirectionColor(_ dir: NYOpenSetup.Direction?) -> Color {
        switch dir {
        case .long:  return Theme.Color.success
        case .short: return Theme.Color.danger
        case nil:    return Theme.Color.warn
        }
    }

    private func sp2lDirectionColor(_ dir: SP2LSetup.Direction) -> Color {
        switch dir {
        case .long:  return Theme.Color.success
        case .short: return Theme.Color.danger
        }
    }

    private func pinBarComboColor(_ direction: PinBarComboSetup.Direction) -> Color {
        direction == .long ? Theme.Color.success : Theme.Color.danger
    }

    private func pinBarComboStatusLabel(_ result: PinBarComboSetup.Result) -> String {
        switch result.status {
        case .active: return result.direction == .long ? "LONG active" : "SHORT active"
        case .hitTP: return "Target hit"
        case .hitSL: return "Stopped"
        case .expired: return "Time exit"
        }
    }

    /// Small filled capsule used for the setup's OR + status tags.
    private func setupTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.95)))
            .fixedSize()
    }

    private struct OrderOBStyle {
        let color: Color
        let tagColor: Color
        let fillOpacity: Double
        let borderOpacity: Double
        let borderStyle: StrokeStyle
        let midLineStyle: StrokeStyle
        let labelText: String
    }

    private func styleForOrderOB(
        _ zone: OrderBlocks.Zone,
        baseColor: Color
    ) -> OrderOBStyle {
        switch zone.status {
        case .fresh:
            return OrderOBStyle(
                color: baseColor,
                tagColor: baseColor.opacity(0.95),
                fillOpacity: 0.14,
                borderOpacity: 0.7,
                borderStyle: StrokeStyle(lineWidth: 1),
                midLineStyle: StrokeStyle(lineWidth: 1, dash: [3, 3]),
                labelText: zone.isBullish ? "OB↑" : "OB↓"
            )
        case .tested:
            return OrderOBStyle(
                color: baseColor.opacity(0.7),
                tagColor: baseColor.opacity(0.7),
                fillOpacity: 0.07,
                borderOpacity: 0.35,
                borderStyle: StrokeStyle(lineWidth: 0.9, dash: [2, 2]),
                midLineStyle: StrokeStyle(lineWidth: 0.9, dash: [2, 4]),
                labelText: zone.isBullish ? "OB↑ · Tested" : "OB↓ · Tested"
            )
        case .exhausted:
            return OrderOBStyle(
                color: Theme.Color.textMuted,
                tagColor: Theme.Color.textMuted.opacity(0.8),
                fillOpacity: 0.03,
                borderOpacity: 0.18,
                borderStyle: StrokeStyle(lineWidth: 0.8, dash: [2, 6]),
                midLineStyle: StrokeStyle(lineWidth: 0.8, dash: [1, 8]),
                labelText: zone.isBullish ? "OB↑ · Exhausted" : "OB↓ · Exhausted"
            )
        }
    }

    @ChartContentBuilder
    private func orderOBMark(for zone: OrderBlocks.Zone, lastIndex: Int) -> some ChartContent {
        let baseColor: Color = zone.isBullish ? Theme.Color.success : Theme.Color.danger
        let xStart = Double(zone.index)
        let xEnd   = Double(lastIndex)
        
        let style = styleForOrderOB(zone, baseColor: baseColor)
        
        RectangleMark(
            xStart: .value("OB start", xStart),
            xEnd:   .value("OB end",   xEnd),
            yStart: .value("OB low",   zone.low),
            yEnd:   .value("OB high",  zone.high)
        )
        .foregroundStyle(style.color.opacity(style.fillOpacity))

        // Top + bottom edges so the block reads clearly against the
        // candles sitting inside it.
        RuleMark(
            xStart: .value("OB start hi", xStart),
            xEnd:   .value("OB end hi",   xEnd),
            y:      .value("OB hi",       zone.high)
        )
        .foregroundStyle(style.color.opacity(style.borderOpacity))
        .lineStyle(style.borderStyle)
        RuleMark(
            xStart: .value("OB start lo", xStart),
            xEnd:   .value("OB end lo",   xEnd),
            y:      .value("OB lo",       zone.low)
        )
        .foregroundStyle(style.color.opacity(style.borderOpacity))
        .lineStyle(style.borderStyle)

        // Equilibrium (avg) — the Pine source's solid channel; dashed
        // here so it reads as the "interaction" line, not an edge.
        RuleMark(
            xStart: .value("OB start avg", xStart),
            xEnd:   .value("OB end avg",   xEnd),
            y:      .value("OB avg",       zone.avg)
        )
        .foregroundStyle(style.color.opacity(style.borderOpacity * 0.7))
        .lineStyle(style.midLineStyle)

        // Direction tag pinned to the right edge of the zone.
        PointMark(
            x: .value("OB label", xEnd),
            y: .value("OB hi",    zone.high)
        )
        .symbolSize(0)
        .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
            Text(style.labelText)
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(style.tagColor))
        }
    }

    /// Order Block zones — translucent rectangles extending from the
    /// originating candle to the right edge of the chart (so a block
    /// stays visible as a level until price revisits it). Bullish blocks
    /// fill green, bearish red. Top/bottom edges plus a dashed
    /// equilibrium (avg) midline mirror the Pine source's channel, and a
    /// small "OB↑"/"OB↓" capsule pins the direction to the right edge.
    @ChartContentBuilder
    private var orderBlockMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(orderBlockZones) { zone in
            orderOBMark(for: zone, lastIndex: lastIndex)
        }
    }

    /// Steroid Order Block zones — order blocks on steroids (volume-profile validated).
    @ChartContentBuilder
    private var steroidOrderBlockMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(steroidOrderBlockZones) { zone in
            steroidOBMark(for: zone, lastIndex: lastIndex)
        }
    }

    private struct SteroidOBStyle {
        let color: Color
        let tagColor: Color
        let fillOpacity: Double
        let borderOpacity: Double
        let borderStyle: StrokeStyle
        let midLineStyle: StrokeStyle
        let labelText: String
    }

    private func styleForSteroidOB(
        _ zone: SteroidOrderBlocks.Zone,
        baseColor: Color,
        accentColor: Color
    ) -> SteroidOBStyle {
        switch zone.status {
        case .fresh:
            return SteroidOBStyle(
                color: baseColor,
                tagColor: accentColor,
                fillOpacity: 0.18,
                borderOpacity: 0.85,
                borderStyle: StrokeStyle(lineWidth: 1.2),
                midLineStyle: StrokeStyle(lineWidth: 1.2, dash: [4, 2]),
                labelText: zone.isBullish ? "⚡ SOB↑" : "⚡ SOB↓"
            )
        case .tested:
            return SteroidOBStyle(
                color: baseColor.opacity(0.7),
                tagColor: accentColor.opacity(0.7),
                fillOpacity: 0.09,
                borderOpacity: 0.45,
                borderStyle: StrokeStyle(lineWidth: 1.0, dash: [3, 3]),
                midLineStyle: StrokeStyle(lineWidth: 1.0, dash: [2, 4]),
                labelText: zone.isBullish ? "⚡ SOB↑ · Tested" : "⚡ SOB↓ · Tested"
            )
        case .exhausted:
            return SteroidOBStyle(
                color: Theme.Color.textMuted,
                tagColor: Theme.Color.textMuted.opacity(0.8),
                fillOpacity: 0.03,
                borderOpacity: 0.18,
                borderStyle: StrokeStyle(lineWidth: 0.8, dash: [2, 6]),
                midLineStyle: StrokeStyle(lineWidth: 0.8, dash: [1, 8]),
                labelText: zone.isBullish ? "⚡ SOB↑ · Exhausted" : "⚡ SOB↓ · Exhausted"
            )
        }
    }

    @ChartContentBuilder
    private func steroidOBMark(for zone: SteroidOrderBlocks.Zone, lastIndex: Int) -> some ChartContent {
        let baseColor: Color = zone.isBullish ? Theme.Color.success : Theme.Color.danger
        let accentColor = IndicatorKind.steroidOrderBlock.color
        let xStart = Double(zone.index)
        let xEnd   = Double(lastIndex)
        
        let style = styleForSteroidOB(zone, baseColor: baseColor, accentColor: accentColor)
        
        RectangleMark(
            xStart: .value("SOB start", xStart),
            xEnd:   .value("SOB end",   xEnd),
            yStart: .value("SOB low",   zone.low),
            yEnd:   .value("SOB high",  zone.high)
        )
        .foregroundStyle(style.color.opacity(style.fillOpacity))

        // Top + bottom edges
        RuleMark(
            xStart: .value("SOB start hi", xStart),
            xEnd:   .value("SOB end hi",   xEnd),
            y:      .value("SOB hi",       zone.high)
        )
        .foregroundStyle(style.color.opacity(style.borderOpacity))
        .lineStyle(style.borderStyle)
        
        RuleMark(
            xStart: .value("SOB start lo", xStart),
            xEnd:   .value("SOB end lo",   xEnd),
            y:      .value("SOB lo",       zone.low)
        )
        .foregroundStyle(style.color.opacity(style.borderOpacity))
        .lineStyle(style.borderStyle)

        // Equilibrium (avg) midline in the indicator's distinct accent color
        RuleMark(
            xStart: .value("SOB start avg", xStart),
            xEnd:   .value("SOB end avg",   xEnd),
            y:      .value("SOB avg",       zone.avg)
        )
        .foregroundStyle(style.tagColor.opacity(0.8))
        .lineStyle(style.midLineStyle)

        // Direction tag with lightning bolt and color weighting
        PointMark(
            x: .value("SOB label", xEnd),
            y: .value("SOB hi",    zone.high)
        )
        .symbolSize(0)
        .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
            Text(style.labelText)
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(style.tagColor))
        }
    }


    /// Sonarlab Order Block zones — momentum-based OB detection via ROC
    /// of opens over 4 bars. Like the standard OBs, each block is a
    /// translucent rectangle extending from the originating candle to
    /// the right edge. Uses the Sonarlab-specific violet accent for the
    /// midline tag to distinguish from the standard OB layer.
    @ChartContentBuilder
    private var sonarlabOBMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(sonarlabOBZones) { zone in
            sonarlabOBMark(for: zone, lastIndex: lastIndex)
        }
    }

    @ChartContentBuilder
    private func sonarlabOBMark(for zone: SonarlabOrderBlocks.Zone, lastIndex: Int) -> some ChartContent {
        let baseColor: Color = zone.isBullish ? Theme.Color.success : Theme.Color.danger
        let accentColor = IndicatorKind.sonarlabOrderBlock.color
        let xStart = Double(zone.index)
        let xEnd   = Double(lastIndex)

        // Fill
        RectangleMark(
            xStart: .value("SOB start", xStart),
            xEnd:   .value("SOB end",   xEnd),
            yStart: .value("SOB low",   zone.low),
            yEnd:   .value("SOB high",  zone.high)
        )
        .foregroundStyle(baseColor.opacity(0.12))

        // Top edge
        RuleMark(
            xStart: .value("SOB start hi", xStart),
            xEnd:   .value("SOB end hi",   xEnd),
            y:      .value("SOB hi",       zone.high)
        )
        .foregroundStyle(baseColor.opacity(0.70))
        .lineStyle(StrokeStyle(lineWidth: 1.0))

        // Bottom edge
        RuleMark(
            xStart: .value("SOB start lo", xStart),
            xEnd:   .value("SOB end lo",   xEnd),
            y:      .value("SOB lo",       zone.low)
        )
        .foregroundStyle(baseColor.opacity(0.70))
        .lineStyle(StrokeStyle(lineWidth: 1.0))

        // Direction tag at the right edge
        let tagText = zone.isBullish ? "SOB↑" : "SOB↓"
        PointMark(
            x: .value("SOB label", xEnd),
            y: .value("SOB hi",    zone.high)
        )
        .symbolSize(0)
        .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
            Text(tagText)
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(accentColor))
        }
    }



    // MARK: - Ranked order block marks

    /// Ranked Order Blocks. Unlike the other OB layers these carry a
    /// grade: A zones are drawn boldly, B at half strength, C in
    /// neutral grey. A breaker (price traded through it) stops at the
    /// break bar and switches to a dashed grey outline.
    @ChartContentBuilder
    private var rankedOBMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(rankedOBZones) { zone in
            rankedOBMark(for: zone, lastIndex: lastIndex)
        }
    }

    @ChartContentBuilder
    private func rankedOBMark(for zone: RankedOrderBlocks.Zone, lastIndex: Int) -> some ChartContent {
        let style = Self.rankedOBStyle(for: zone)
        let xStart = Double(zone.startIndex)
        let xEnd   = Double(min(zone.endIndex, lastIndex))
        let edge = StrokeStyle(
            lineWidth: zone.isCombined ? 2 : 1,
            dash: zone.isBreaker ? [4, 3] : []
        )

        RectangleMark(
            xStart: .value("ROB start", xStart),
            xEnd:   .value("ROB end",   xEnd),
            yStart: .value("ROB low",   zone.bottom),
            yEnd:   .value("ROB high",  zone.top)
        )
        .foregroundStyle(style.base.opacity(style.fillOpacity))

        RuleMark(
            xStart: .value("ROB start hi", xStart),
            xEnd:   .value("ROB end hi",   xEnd),
            y:      .value("ROB hi",       zone.top)
        )
        .foregroundStyle(style.base.opacity(style.borderOpacity))
        .lineStyle(edge)

        RuleMark(
            xStart: .value("ROB start lo", xStart),
            xEnd:   .value("ROB end lo",   xEnd),
            y:      .value("ROB lo",       zone.bottom)
        )
        .foregroundStyle(style.base.opacity(style.borderOpacity))
        .lineStyle(edge)

        // Badge sits centred inside the zone, like the Pine original's
        // box text. Anchoring it at the right edge (as the other OB
        // layers do) puts it flush against the price axis, where the
        // plot area clips it away entirely.
        if indicatorConfig.robShowLabels {
            PointMark(
                x: .value("ROB label x", Self.rankedOBLabelX(
                    xStart: xStart, xEnd: xEnd, domain: effectiveXDomain
                )),
                y: .value("ROB label y", (zone.top + zone.bottom) / 2)
            )
            .symbolSize(0)
            .annotation(position: .overlay, alignment: .center, spacing: 0) {
                // `.fixedSize()` is load-bearing: an overlay annotation on
                // a zero-size PointMark is proposed zero width, which
                // truncates the badge down to an unreadable sliver.
                Text(Self.rankedOBBadge(for: zone))
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(style.base.opacity(0.85)))
            }
        }
    }

    /// Where along the zone to park its badge. Zones run from the order
    /// block to the right edge of the chart, so a plain midpoint lands
    /// off-screen on an old zone once the user pans. Clamp it into the
    /// part of the zone that is actually visible, inset from the plot
    /// edges so the capsule isn't clipped.
    private static func rankedOBLabelX(
        xStart: Double,
        xEnd: Double,
        domain: ClosedRange<Double>
    ) -> Double {
        let inset = (domain.upperBound - domain.lowerBound) * 0.05
        let lo = max(xStart, domain.lowerBound + inset)
        let hi = min(xEnd, domain.upperBound - inset)
        return lo <= hi ? (lo + hi) / 2 : (xStart + xEnd) / 2
    }

    /// Badge text: grade + score, with the zone's lifecycle state
    /// appended so a merged or broken zone reads at a glance.
    private static func rankedOBBadge(for zone: RankedOrderBlocks.Zone) -> String {
        var text = zone.badge
        if zone.isCombined { text += " ·M" }
        if zone.isBreaker  { text += " ·BRK" }
        return text
    }

    /// Grade → colour weight. Breakers desaturate to grey whatever grade
    /// they held; C-grade zones are grey from the start.
    private static func rankedOBStyle(
        for zone: RankedOrderBlocks.Zone
    ) -> (base: Color, fillOpacity: Double, borderOpacity: Double) {
        guard !zone.isBreaker else {
            return (Theme.Color.textMuted, 0.08, 0.55)
        }
        let directional = zone.isBullish ? Theme.Color.success : Theme.Color.danger
        switch zone.grade {
        case .a:        return (directional, 0.22, 0.95)
        case .b:        return (directional, 0.12, 0.65)
        case .c:        return (Theme.Color.textMuted, 0.10, 0.50)
        case .unranked: return (IndicatorKind.rankedOrderBlock.color, 0.12, 0.65)
        }
    }

    /// Change of Character overlays. For every CHoCH we always draw the
    /// broken-structure line + a "CHoCH↑/↓" capsule at the break bar; the
    /// order block, the displacement FVG and the inverse FVG each draw as
    /// their own rectangle, gated by the indicator's show-OB / show-FVG /
    /// show-iFVG toggles.
    @ChartContentBuilder
    private var chochMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(chochZones) { zone in
            chochMark(for: zone, lastIndex: lastIndex)
        }
    }

    /// One tinted zone rectangle (fill + top/bottom edges + a right-edge
    /// letter tag), shared by the OB / FVG / iFVG layers.
    @ChartContentBuilder
    private func chochZoneRect(
        id: String, xStart: Double, xEnd: Double,
        low: Double, high: Double, color: Color,
        fill: Double, dashed: Bool, tag: String
    ) -> some ChartContent {
        let edge: StrokeStyle = dashed
            ? StrokeStyle(lineWidth: 1.0, dash: [4, 3])
            : StrokeStyle(lineWidth: 1.0)
        RectangleMark(
            xStart: .value("\(id) x0", xStart), xEnd: .value("\(id) x1", xEnd),
            yStart: .value("\(id) y0", low),    yEnd: .value("\(id) y1", high)
        )
        .foregroundStyle(color.opacity(fill))
        RuleMark(xStart: .value("\(id) hx0", xStart), xEnd: .value("\(id) hx1", xEnd), y: .value("\(id) hy", high))
            .foregroundStyle(color.opacity(0.6)).lineStyle(edge)
        RuleMark(xStart: .value("\(id) lx0", xStart), xEnd: .value("\(id) lx1", xEnd), y: .value("\(id) ly", low))
            .foregroundStyle(color.opacity(0.6)).lineStyle(edge)
        PointMark(x: .value("\(id) tx", xEnd), y: .value("\(id) ty", high))
            .symbolSize(0)
            .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                Text(tag)
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(Capsule().fill(color))
            }
    }

    @ChartContentBuilder
    private func chochMark(for zone: ChangeOfCharacter.Zone, lastIndex: Int) -> some ChartContent {
        let baseColor: Color = zone.isBullish ? Theme.Color.success : Theme.Color.danger
        let accentColor = IndicatorKind.changeOfCharacter.color
        let fvgColor = Color(red: 0.30, green: 0.80, blue: 0.75)   // teal, matches FVG indicator
        let xEnd = Double(lastIndex)
        let dim = zone.status == .fresh ? 1.0 : 0.6

        // Order block layer.
        if indicatorConfig.chochShowOB {
            chochZoneRect(
                id: "\(zone.id)-OB", xStart: Double(zone.obIndex), xEnd: xEnd,
                low: zone.obLow, high: zone.obHigh, color: baseColor,
                fill: 0.12 * dim, dashed: !zone.hasFVG, tag: "OB"
            )
        }
        // Displacement FVG layer.
        if indicatorConfig.chochShowFVG, let fl = zone.fvgLow, let fh = zone.fvgHigh, let fi = zone.fvgIndex {
            chochZoneRect(
                id: "\(zone.id)-FVG", xStart: Double(fi), xEnd: xEnd,
                low: fl, high: fh, color: fvgColor, fill: 0.16 * dim, dashed: false, tag: "FVG"
            )
        }
        // Inverse FVG layer (dashed to read as flipped).
        if indicatorConfig.chochShowIFVG, let il = zone.ifvgLow, let ih = zone.ifvgHigh, let ii = zone.ifvgIndex {
            chochZoneRect(
                id: "\(zone.id)-IFVG", xStart: Double(ii), xEnd: xEnd,
                low: il, high: ih, color: accentColor, fill: 0.10 * dim, dashed: true, tag: "iFVG"
            )
        }

        // Broken-structure level — dashed rule from the OB across to the break.
        RuleMark(
            xStart: .value("CHoCH lvl start", Double(zone.obIndex)),
            xEnd:   .value("CHoCH lvl end",   Double(zone.chochIndex)),
            y:      .value("CHoCH lvl",       zone.brokenLevel)
        )
        .foregroundStyle(accentColor.opacity(0.8))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))

        // Break marker + label at the CHoCH bar.
        let tagText = zone.isBullish ? "CHoCH↑" : "CHoCH↓"
        PointMark(
            x: .value("CHoCH label x", Double(zone.chochIndex)),
            y: .value("CHoCH label y", zone.brokenLevel)
        )
        .symbolSize(0)
        .annotation(position: zone.isBullish ? .top : .bottom, alignment: .center, spacing: 2) {
            Text(tagText)
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(accentColor))
        }
    }

    /// Higher-timeframe CHoCH overlays. Same OB / FVG / iFVG / level /
    /// label vocabulary as `chochMark`, but each element's X positions are
    /// mapped from wall-clock dates onto this timeframe's bar-index axis
    /// (`barIndex(forDate:)`), and everything is drawn muted + dashed with
    /// a "·HTF" tag so it reads as secondary reference structure rather
    /// than a live signal on the timeframe in view.
    @ChartContentBuilder
    private var htfChochMarks: some ChartContent {
        let xEnd = Double(max(0, candles.count - 1))
        ForEach(htfChochZones) { zone in
            htfChochMark(for: zone, xEnd: xEnd)
        }
    }

    @ChartContentBuilder
    private func htfChochMark(for zone: ChangeOfCharacter.DatedZone, xEnd: Double) -> some ChartContent {
        let baseColor: Color = zone.isBullish ? Theme.Color.success : Theme.Color.danger
        let accentColor = IndicatorKind.changeOfCharacter.color
        let fvgColor = Color(red: 0.30, green: 0.80, blue: 0.75)
        // HTF zones are context, not the live signal — halve every fill so
        // they sit visibly behind the current-timeframe CHoCH zones.
        let dim = (zone.status == .fresh ? 1.0 : 0.6) * 0.5
        let obX = barIndex(forDate: zone.obDate)
        let chochX = barIndex(forDate: zone.chochDate)

        // Order block layer.
        if indicatorConfig.chochShowOB, let obX {
            chochZoneRect(
                id: "\(zone.id)-HTFOB", xStart: obX, xEnd: xEnd,
                low: zone.obLow, high: zone.obHigh, color: baseColor,
                fill: 0.12 * dim, dashed: true, tag: "OB·HTF"
            )
        }
        // Displacement FVG layer.
        if indicatorConfig.chochShowFVG,
           let fl = zone.fvgLow, let fh = zone.fvgHigh,
           let fd = zone.fvgDate, let fx = barIndex(forDate: fd) {
            chochZoneRect(
                id: "\(zone.id)-HTFFVG", xStart: fx, xEnd: xEnd,
                low: fl, high: fh, color: fvgColor, fill: 0.16 * dim, dashed: true, tag: "FVG·HTF"
            )
        }
        // Inverse FVG layer.
        if indicatorConfig.chochShowIFVG,
           let il = zone.ifvgLow, let ih = zone.ifvgHigh,
           let idt = zone.ifvgDate, let ix = barIndex(forDate: idt) {
            chochZoneRect(
                id: "\(zone.id)-HTFIFVG", xStart: ix, xEnd: xEnd,
                low: il, high: ih, color: accentColor, fill: 0.10 * dim, dashed: true, tag: "iFVG·HTF"
            )
        }

        // Broken-structure level — dashed rule from the OB across to the break.
        if let obX, let chochX {
            RuleMark(
                xStart: .value("HTF CHoCH lvl start", obX),
                xEnd:   .value("HTF CHoCH lvl end",   chochX),
                y:      .value("HTF CHoCH lvl",       zone.brokenLevel)
            )
            .foregroundStyle(accentColor.opacity(0.5))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }

        // Break marker + label at the CHoCH bar.
        if let chochX {
            let tagText = zone.isBullish ? "CHoCH↑ HTF" : "CHoCH↓ HTF"
            PointMark(
                x: .value("HTF CHoCH label x", chochX),
                y: .value("HTF CHoCH label y", zone.brokenLevel)
            )
            .symbolSize(0)
            .annotation(position: zone.isBullish ? .top : .bottom, alignment: .center, spacing: 2) {
                Text(tagText)
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(accentColor.opacity(0.85)))
            }
        }
    }

    /// Volume Profile — three modes, switched by `indicatorConfig.vpMode`:
    /// "session" (per-trading-day histograms), "zigzag" (last trend
    /// segment, right margin) and "visible" (visible window + ranked
    /// high-volume levels).
    @ChartContentBuilder
    private var volumeProfileMarks: some ChartContent {
        switch indicatorConfig.vpMode {
        case "session": sessionVPMarks
        case "visible": visibleRangeVPMarks
        default:        zigzagVPMarks
        }
    }

    /// Right margin geometry shared by the margin-anchored modes
    /// (zigzag + visible): the histogram hugs the visible right edge so
    /// it stays on screen while panning, sized relative to the visible
    /// span instead of a fixed bar count.
    private var vpMargin: (rightEdge: Double, width: Double) {
        let domain = effectiveXDomain
        let width = max(6, min(24, (domain.upperBound - domain.lowerBound) * 0.18))
        return (domain.upperBound, width)
    }

    /// Two-tone histogram bars, right-anchored at `rightEdge` and
    /// extending leftward by up to `maxWidth` bar units. Up-volume
    /// (close ≥ open) renders success-tinted, down-volume danger-tinted;
    /// buckets outside the value area are dimmed, the POC row is
    /// emphasised. POC/VA membership comes from the precomputed indices
    /// — no float comparisons against derived prices.
    @ChartContentBuilder
    private func vpHistogramMarks(
        buckets: [VolumeProfile.Bucket],
        bucketSize: Double,
        pocIndex: Int,
        vaLowIndex: Int,
        vaHighIndex: Int,
        rightEdge: Double,
        maxWidth: Double,
        tag: String
    ) -> some ChartContent {
        let maxVol = buckets.map(\.volume).max() ?? 1
        ForEach(Array(buckets.enumerated()), id: \.offset) { idx, bucket in
            let totalW = maxWidth * (bucket.volume / maxVol)
            let upW = maxWidth * (bucket.upVolume / maxVol)
            let inVA = idx >= vaLowIndex && idx <= vaHighIndex
            let opacity: Double = idx == pocIndex ? 0.85 : (inVA ? 0.55 : 0.25)
            // Down segment (left), up segment (right).
            RectangleMark(
                xStart: .value("\(tag) d0", rightEdge - totalW),
                xEnd:   .value("\(tag) d1", rightEdge - upW),
                yStart: .value("\(tag) dy0", bucket.priceLevel),
                yEnd:   .value("\(tag) dy1", bucket.priceLevel + bucketSize * 0.92)
            )
            .foregroundStyle(Theme.Color.danger.opacity(opacity))
            RectangleMark(
                xStart: .value("\(tag) u0", rightEdge - upW),
                xEnd:   .value("\(tag) u1", rightEdge),
                yStart: .value("\(tag) uy0", bucket.priceLevel),
                yEnd:   .value("\(tag) uy1", bucket.priceLevel + bucketSize * 0.92)
            )
            .foregroundStyle(Theme.Color.success.opacity(opacity))
        }
    }

    /// Small "no volume data" note — when every candle lacked volume
    /// the profile is time-at-price (TPO-style), not true volume; say
    /// so once instead of silently degrading.
    @ChartContentBuilder
    private func vpTPONote(x: Double, y: Double) -> some ChartContent {
        PointMark(x: .value("VP TPO x", x), y: .value("VP TPO y", y))
            .symbolSize(0)
            .annotation(position: .top, alignment: .trailing, spacing: 2) {
                Text("TPO · no volume data")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.Color.textMuted)
            }
    }

    /// Visible-range VP: histogram in the right margin plus ranked
    /// high-volume levels drawn across the profiled bar range.
    @ChartContentBuilder
    private var visibleRangeVPMarks: some ChartContent {
        if let vp = visibleRangeVP {
            let margin = vpMargin

            vpHistogramMarks(
                buckets: vp.buckets,
                bucketSize: vp.bucketSize,
                pocIndex: vp.pocIndex,
                vaLowIndex: vp.vaLowIndex,
                vaHighIndex: vp.vaHighIndex,
                rightEdge: margin.rightEdge,
                maxWidth: margin.width,
                tag: "VRVP"
            )

            // Ranked volume levels — line weight and opacity scale with
            // relative volume; the POC level is the accent one.
            ForEach(vp.levels, id: \.price) { level in
                RuleMark(
                    xStart: .value("VR L x0", Double(vp.startBar)),
                    xEnd:   .value("VR L x1", Double(vp.endBar)),
                    y:      .value("VR L y", level.price)
                )
                .foregroundStyle(
                    level.isPOC
                        ? Color(red: 0.96, green: 0.36, blue: 0.36).opacity(0.9)
                        : Theme.Color.info.opacity(0.25 + 0.55 * level.strength)
                )
                .lineStyle(StrokeStyle(
                    lineWidth: level.isPOC ? 2 : 1 + level.strength,
                    dash: level.isPOC ? [] : [6, 3]
                ))
                .annotation(position: .top, alignment: .trailing, spacing: 0) {
                    Text(Self.priceExact(level.price))
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(
                            level.isPOC ? Color(red: 0.96, green: 0.36, blue: 0.36) : Theme.Color.textMuted
                        )
                        .padding(.horizontal, 3)
                        .background(
                            Theme.Color.surfaceMax.opacity(0.85),
                            in: RoundedRectangle(cornerRadius: 3)
                        )
                }
            }

            if !vp.hasRealVolume {
                vpTPONote(x: margin.rightEdge, y: vp.vah)
            }
        }
    }

    /// ZigZag-based VP: a single histogram for the last trend segment,
    /// anchored to the visible right edge so it doesn't overlap the
    /// price action.
    @ChartContentBuilder
    private var zigzagVPMarks: some ChartContent {
        if let vp = zigzagTrendVP {
            let margin = vpMargin
            let lastBar = Double(candles.count - 1)

            vpHistogramMarks(
                buckets: vp.buckets,
                bucketSize: vp.bucketSize,
                pocIndex: vp.pocIndex,
                vaLowIndex: vp.vaLowIndex,
                vaHighIndex: vp.vaHighIndex,
                rightEdge: margin.rightEdge,
                maxWidth: margin.width,
                tag: "ZVP"
            )

            // POC — developing ray from the trend start to the visible
            // right edge.
            RuleMark(
                xStart: .value("ZVP POC x0", Double(vp.startBar)),
                xEnd:   .value("ZVP POC x1", margin.rightEdge),
                y:      .value("ZVP POC", vp.poc)
            )
            .foregroundStyle(Color(red: 0.96, green: 0.36, blue: 0.36))
            .lineStyle(StrokeStyle(lineWidth: 1.5))

            // VAH / VAL — scoped to the trend segment.
            RuleMark(
                xStart: .value("ZVP VAH x0", Double(vp.startBar)),
                xEnd:   .value("ZVP VAH x1", lastBar),
                y:      .value("ZVP VAH", vp.vah)
            )
            .foregroundStyle(Theme.Color.info.opacity(0.7))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

            RuleMark(
                xStart: .value("ZVP VAL x0", Double(vp.startBar)),
                xEnd:   .value("ZVP VAL x1", lastBar),
                y:      .value("ZVP VAL", vp.val)
            )
            .foregroundStyle(Theme.Color.info.opacity(0.7))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

            if !vp.hasRealVolume {
                vpTPONote(x: margin.rightEdge, y: vp.vah)
            }
        }
    }

    /// Session-based VP: per-trading-day histograms. POC/VAH/VAL are
    /// scoped to their own session's bar range (only the latest session
    /// extends a few bars as developing levels) so older sessions don't
    /// spray full-width lines across the chart.
    @ChartContentBuilder
    private var sessionVPMarks: some ChartContent {
        let sessions = volumeProfileSessions
        let lastBar = Double(candles.count - 1)
        ForEach(sessions) { session in
            let sessionWidth = Double(session.endBar - session.startBar)
            let maxBarWidth = max(2, sessionWidth * 0.25)
            let rightEdge = Double(session.endBar)
            let isLatest = session.id == sessions.last?.id
            // Latest session's levels project a few bars forward —
            // they're the actionable, still-developing ones.
            let lineEnd = isLatest ? lastBar + 8 : rightEdge

            vpHistogramMarks(
                buckets: session.buckets,
                bucketSize: session.bucketSize,
                pocIndex: session.pocIndex,
                vaLowIndex: session.vaLowIndex,
                vaHighIndex: session.vaHighIndex,
                rightEdge: rightEdge,
                maxWidth: maxBarWidth,
                tag: "VP\(session.id)"
            )

            // POC line — solid
            RuleMark(
                xStart: .value("VP POC x0", Double(session.startBar)),
                xEnd:   .value("VP POC x1", lineEnd),
                y:      .value("VP POC", session.poc)
            )
            .foregroundStyle(Color(red: 0.96, green: 0.36, blue: 0.36))
            .lineStyle(StrokeStyle(lineWidth: 1.5))

            // VAH line — dashed
            RuleMark(
                xStart: .value("VP VAH x0", Double(session.startBar)),
                xEnd:   .value("VP VAH x1", lineEnd),
                y:      .value("VP VAH", session.vah)
            )
            .foregroundStyle(Theme.Color.info.opacity(0.7))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

            // VAL line — dashed
            RuleMark(
                xStart: .value("VP VAL x0", Double(session.startBar)),
                xEnd:   .value("VP VAL x1", lineEnd),
                y:      .value("VP VAL", session.val)
            )
            .foregroundStyle(Theme.Color.info.opacity(0.7))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

            // Session boundary — faint vertical
            if session.startBar > 0 {
                RuleMark(x: .value("VP sep", Double(session.startBar) - 0.5))
                    .foregroundStyle(Theme.Color.textMuted.opacity(0.15))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }
        }
        if let latest = sessions.last, !latest.hasRealVolume {
            vpTPONote(x: Double(latest.endBar), y: latest.vah)
        }
    }

    /// ZigZag line overlay — connects consecutive swing pivots with
    /// alternating colored lines. Only rendered when VP is in zigzag
    /// mode and "Show ZigZag lines" is enabled.
    @ChartContentBuilder
    private var zigzagLineMarks: some ChartContent {
        let pivots = zigzagPivots
        if pivots.count >= 2 {
            ForEach(0..<(pivots.count - 1), id: \.self) { i in
                let p0 = pivots[i]
                let p1 = pivots[i + 1]
                let color = p1.isHigh
                    ? Color(red: 0.96, green: 0.36, blue: 0.36)  // red for swing high
                    : Color(red: 0.30, green: 0.80, blue: 0.40)  // green for swing low
                LineMark(
                    x: .value("ZZ x0", Double(p0.barIndex)),
                    y: .value("ZZ y0", p0.price),
                    series: .value("ZZ", i)
                )
                .foregroundStyle(color.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                LineMark(
                    x: .value("ZZ x1", Double(p1.barIndex)),
                    y: .value("ZZ y1", p1.price),
                    series: .value("ZZ", i)
                )
                .foregroundStyle(color.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            // Pivot dots
            ForEach(pivots) { pivot in
                let color = pivot.isHigh
                    ? Color(red: 0.96, green: 0.36, blue: 0.36)
                    : Color(red: 0.30, green: 0.80, blue: 0.40)
                PointMark(
                    x: .value("ZZ dot x", Double(pivot.barIndex)),
                    y: .value("ZZ dot y", pivot.price)
                )
                .foregroundStyle(color)
                .symbolSize(18)
            }
        }
    }

    /// Indicator-computed FVG zones. Each gap is a translucent rectangle
    /// from the bar where it formed to the right edge of the chart
    /// (extending into the future so the user can watch price approach).
    /// Mitigated zones (price closed back inside) render at lower opacity
    /// with dashed boundary lines — same visual grammar as AI `fvgMarks`.
    @ChartContentBuilder
    private var indicatorFvgMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(indicatorFvgZones) { zone in
            let color: Color = zone.isBullish ? Theme.Color.success : Theme.Color.danger
            let xStart = Double(zone.index)
            let xEnd   = Double(lastIndex)
            RectangleMark(
                xStart: .value("FVG start", xStart),
                xEnd:   .value("FVG end",   xEnd),
                yStart: .value("FVG low",   zone.low),
                yEnd:   .value("FVG high",  zone.high)
            )
            .foregroundStyle(color.opacity(zone.isMitigated ? 0.08 : 0.16))

            // Boundary lines so the zone edges read clearly.
            RuleMark(
                xStart: .value("FVG hi start", xStart),
                xEnd:   .value("FVG hi end",   xEnd),
                y:      .value("FVG hi",        zone.high)
            )
            .foregroundStyle(color.opacity(zone.isMitigated ? 0.35 : 0.65))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: zone.isMitigated ? [4, 3] : []))

            RuleMark(
                xStart: .value("FVG lo start", xStart),
                xEnd:   .value("FVG lo end",   xEnd),
                y:      .value("FVG lo",        zone.low)
            )
            .foregroundStyle(color.opacity(zone.isMitigated ? 0.35 : 0.65))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: zone.isMitigated ? [4, 3] : []))

            // Midline — the 50% equilibrium level traders watch for entries.
            RuleMark(
                xStart: .value("FVG mid start", xStart),
                xEnd:   .value("FVG mid end",   xEnd),
                y:      .value("FVG mid",        zone.mid)
            )
            .foregroundStyle(color.opacity(0.35))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // "FVG↑" / "FVG↓" direction capsule on the right edge.
            PointMark(
                x: .value("FVG label", xEnd),
                y: .value("FVG hi",    zone.high)
            )
            .symbolSize(0)
            .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                Text(zone.isBullish ? "FVG↑" : "FVG↓")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(color.opacity(zone.isMitigated ? 0.55 : 0.95)))
            }
        }
    }

    /// Scenario marks: TP + SL + (optional) entry lines plus a bias
    /// capsule pinned to the entry rule (or TP rule if entry is missing
    /// — older history entries don't carry an entry price). Positions
    /// all use `.overlay`/`.trailing` so capsules sit inside the plot
    /// area, matching the last-price tag's strategy.
    @ChartContentBuilder
    private var scenarioMarks: some ChartContent {
        if let scenario = taScenario {
            scenarioOverlay(scenario, isAlt: false)
        }
        if let alt = taAltScenario {
            scenarioOverlay(alt, isAlt: true)
        }
    }

    /// Renders one scenario's TP / SL / entry rules + capsules. `isAlt`
    /// shifts the styling down a notch (lower opacity, thinner lines,
    /// "ALT" tag on the bias capsule) so the alternative plan reads
    /// as the secondary one when both are on screen together.
    @ChartContentBuilder
    private func scenarioOverlay(
        _ scenario: PromptBuilder.TAScenario,
        isAlt: Bool
    ) -> some ChartContent {
        // Visual treatment per variant. Alt: dimmer, thinner, sparser
        // dash pattern so the eye picks the main lines first.
        let tpOpacity: Double = isAlt ? 0.40 : 0.75
        let slOpacity: Double = isAlt ? 0.40 : 0.75
        let entryOpacity: Double = isAlt ? 0.55 : 0.85
        let lineWidth: CGFloat = isAlt ? 0.9 : 1.2
        let entryLineWidth: CGFloat = isAlt ? 1.0 : 1.4
        let dashPattern: [CGFloat] = isAlt ? [2, 5] : [4, 4]
        let entryDash:   [CGFloat] = isAlt ? [1, 4] : [2, 3]
        let tpPrefix = isAlt ? "ALT TP" : "TP"
        let slPrefix = isAlt ? "ALT SL" : "SL"

        RuleMark(y: .value(tpPrefix, scenario.takeProfit))
            .foregroundStyle(Theme.Color.success.opacity(tpOpacity))
            .lineStyle(StrokeStyle(lineWidth: lineWidth, dash: dashPattern))
            .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                levelTag(text: "\(tpPrefix) \(Self.priceShort(scenario.takeProfit))",
                         color: Theme.Color.success.opacity(isAlt ? 0.7 : 1))
            }
        RuleMark(y: .value(slPrefix, scenario.stopLoss))
            .foregroundStyle(Theme.Color.danger.opacity(slOpacity))
            .lineStyle(StrokeStyle(lineWidth: lineWidth, dash: dashPattern))
            .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                levelTag(text: "\(slPrefix) \(Self.priceShort(scenario.stopLoss))",
                         color: Theme.Color.danger.opacity(isAlt ? 0.7 : 1))
            }
        if let entry = scenario.entry {
            RuleMark(y: .value(isAlt ? "Alt Entry" : "Entry", entry))
                .foregroundStyle(Theme.Color.warn.opacity(entryOpacity))
                .lineStyle(StrokeStyle(lineWidth: entryLineWidth, dash: entryDash))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    scenarioEntryTag(scenario: scenario, entry: entry, isAlt: isAlt)
                }
        }
    }

    /// Paper-trade overlay: one set of entry / TP / SL lines per open
    /// trade. Active trades render solid with live P/L on the entry
    /// capsule; pending trades render dashed-amber until price fills
    /// them. Closed trades aren't passed in (DashboardView filters
    /// them out via `TradeStore.openVisibleTrades`).
    @ChartContentBuilder
    private var tradeMarks: some ChartContent {
        ForEach(trades) { trade in
            // Entry — the most important line: shows the trade's
            // cost basis (active) or its trigger (pending). The
            // capsule on this line carries the side / status / live
            // P/L so it's the user's at-a-glance "how am I doing?"
            // readout.
            RuleMark(y: .value("Trade entry", trade.fillPrice ?? trade.entry))
                .foregroundStyle(tradeEntryColor(trade))
                .lineStyle(StrokeStyle(
                    lineWidth: trade.status == .active ? 1.6 : 1.3,
                    dash: trade.status == .pending ? [3, 3] : []
                ))
                .annotation(position: .overlay, alignment: .leading, spacing: 0) {
                    tradeEntryTag(trade)
                }

            // Take-profit
            RuleMark(y: .value("Trade TP", trade.takeProfit))
                .foregroundStyle(Theme.Color.success.opacity(0.6))
                .lineStyle(StrokeStyle(
                    lineWidth: 1.0,
                    dash: trade.status == .pending ? [3, 3] : [4, 4]
                ))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    levelTag(text: "TP \(Self.priceShort(trade.takeProfit))",
                             color: Theme.Color.success)
                }

            // Stop-loss
            RuleMark(y: .value("Trade SL", trade.stopLoss))
                .foregroundStyle(Theme.Color.danger.opacity(0.6))
                .lineStyle(StrokeStyle(
                    lineWidth: 1.0,
                    dash: trade.status == .pending ? [3, 3] : [4, 4]
                ))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    levelTag(text: "SL \(Self.priceShort(trade.stopLoss))",
                             color: Theme.Color.danger)
                }
        }
    }

    /// Resolves the bar index of the candle whose `bucketStart` is
    /// closest to `date`. Binary search — O(log n).
    /// Returns nil when the candle list is empty.
    private func barIndex(closestTo date: Date) -> Int? {
        guard !candles.isEmpty else { return nil }
        let ts = date.timeIntervalSince1970
        var lo = 0
        var hi = candles.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if candles[mid].bucketStart.timeIntervalSince1970 < ts {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo > 0 {
            let dLo = abs(candles[lo].bucketStart.timeIntervalSince(date))
            let dPrev = abs(candles[lo - 1].bucketStart.timeIntervalSince(date))
            if dPrev < dLo { return lo - 1 }
        }
        return lo
    }

    /// Finds the bar index of the candle where `price` first fell inside
    /// the candle's [low, high] range, searching backward from `fromIndex`.
    /// Used to locate the open candle when we only have the entry price
    /// (no open timestamp — typical for cTrader imports).
    private func barIndexForEntryPrice(_ price: Double, before fromIndex: Int) -> Int? {
        guard fromIndex >= 0, fromIndex < candles.count else { return nil }
        for i in stride(from: fromIndex, through: 0, by: -1) {
            let c = candles[i]
            if price >= c.low && price <= c.high { return i }
        }
        return nil
    }

    /// TradingView-style journal overlay:
    ///
    ///   Green box  — entry → TP  (profit zone)
    ///   Red box    — entry → SL  (loss zone)
    ///   Both boxes span from the open candle to the close candle on X.
    ///
    ///   Solid entry rule across the trade span.
    ///   ▲/▼ arrow at the open candle; ● exit dot at the close candle.
    ///   Right-edge label tags for TP, SL, Entry prices.
    ///   P/L badge anchored to the exit dot.
    @ChartContentBuilder
    private var journalMarks: some ChartContent {
        ForEach(journalEntries) { je in
            let sideColor: Color = je.side == .short ? Theme.Color.danger : Theme.Color.success

            // ── Locate candle positions ───────────────────────────
            let closeIdx: Int? = barIndex(closestTo: je.date)
            let openIdx: Int? = {
                if let od = je.openDate { return barIndex(closestTo: od) }
                guard let ci = closeIdx, let ep = je.entry else { return nil }
                return barIndexForEntryPrice(ep, before: ci)
            }()

            let xOpen  = Double(openIdx  ?? 0)
            let xClose = Double(closeIdx ?? max(0, candles.count - 1))
            let hasSpan = openIdx != nil && closeIdx != nil && openIdx != closeIdx

            // ── Green box: entry → TP ─────────────────────────────
            if let ep = je.entry, let tp = je.takeProfit, hasSpan {
                RectangleMark(
                    xStart: .value("Open",  xOpen),
                    xEnd:   .value("Close", xClose),
                    yStart: .value("Entry", ep),
                    yEnd:   .value("TP",    tp)
                )
                .foregroundStyle(Theme.Color.success.opacity(0.12))

                // TP border line
                RuleMark(
                    xStart: .value("Open",  xOpen),
                    xEnd:   .value("Close", xClose),
                    y:      .value("TP",    tp)
                )
                .foregroundStyle(Theme.Color.success.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1.2))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    journalLevelTag(text: "TP  \(Self.priceShort(tp))",
                                    bg: Theme.Color.success)
                }
            } else if let tp = je.takeProfit {
                // No span — full-width dashed line
                RuleMark(y: .value("TP", tp))
                    .foregroundStyle(Theme.Color.success.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.0, dash: [4, 4]))
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        journalLevelTag(text: "TP  \(Self.priceShort(tp))",
                                        bg: Theme.Color.success)
                    }
            }

            // ── Red box: entry → SL ───────────────────────────────
            if let ep = je.entry, let sl = je.stopLoss, hasSpan {
                RectangleMark(
                    xStart: .value("Open",  xOpen),
                    xEnd:   .value("Close", xClose),
                    yStart: .value("Entry", ep),
                    yEnd:   .value("SL",    sl)
                )
                .foregroundStyle(Theme.Color.danger.opacity(0.12))

                // SL border line
                RuleMark(
                    xStart: .value("Open",  xOpen),
                    xEnd:   .value("Close", xClose),
                    y:      .value("SL",    sl)
                )
                .foregroundStyle(Theme.Color.danger.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1.2))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    journalLevelTag(text: "SL  \(Self.priceShort(sl))",
                                    bg: Theme.Color.danger)
                }
            } else if let sl = je.stopLoss {
                RuleMark(y: .value("SL", sl))
                    .foregroundStyle(Theme.Color.danger.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.0, dash: [4, 4]))
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        journalLevelTag(text: "SL  \(Self.priceShort(sl))",
                                        bg: Theme.Color.danger)
                    }
            }

            // ── Entry solid rule across the trade span ────────────
            if let ep = je.entry {
                if hasSpan {
                    RuleMark(
                        xStart: .value("Open",  xOpen),
                        xEnd:   .value("Close", xClose),
                        y:      .value("Entry", ep)
                    )
                    .foregroundStyle(sideColor.opacity(0.95))
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        journalLevelTag(text: "Entry  \(Self.priceShort(ep))",
                                        bg: sideColor)
                    }
                } else {
                    RuleMark(y: .value("Entry", ep))
                        .foregroundStyle(sideColor.opacity(0.85))
                        .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
                        .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                            journalLevelTag(text: "Entry  \(Self.priceShort(ep))",
                                            bg: sideColor)
                        }
                }
            }

            // ── Open candle: entry arrow ▲/▼ ─────────────────────
            if let ep = je.entry, let oi = openIdx {
                let offset = (je.side == .long ? -1.0 : 1.0) * (ep * 0.0009)
                PointMark(
                    x: .value("Open bar",   Double(oi)),
                    y: .value("Open price", ep + offset)
                )
                .symbolSize(55)
                .foregroundStyle(sideColor)
                .symbol {
                    Image(systemName: je.side == .long
                          ? "arrowtriangle.up.fill"
                          : "arrowtriangle.down.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(sideColor)
                }
                .annotation(position: je.side == .long ? .bottom : .top,
                             alignment: .center, spacing: 1) {
                    Text(je.side.label.uppercased())
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(sideColor))
                }
            }

            // ── Close candle: exit dot + P/L badge ───────────────
            if let ci = closeIdx {
                let exitPrice = je.closePrice ?? je.entry ?? 0
                let plColor = je.profitLoss >= 0 ? Theme.Color.success : Theme.Color.danger
                PointMark(
                    x: .value("Close bar",   Double(ci)),
                    y: .value("Close price", exitPrice)
                )
                .symbolSize(48)
                .foregroundStyle(plColor)
                .symbol(.circle)
                .annotation(position: je.side == .long ? .top : .bottom,
                             alignment: .center, spacing: 2) {
                    HStack(spacing: 3) {
                        Text(String(format: "%+.2f", je.profitLoss))
                            .font(.system(size: 8, weight: .bold).monospacedDigit())
                            .foregroundStyle(plColor)
                        Text(je.result.label.uppercased())
                            .font(.system(size: 7, weight: .black))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Capsule().fill(plColor))
                    }
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.Color.surface.opacity(0.9))
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(plColor.opacity(0.4), lineWidth: 0.7))
                    )
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                }
            }
        }
    }

    /// Right-edge price tag for TP / SL / Entry lines — solid colour
    /// background like TradingView's level labels.
    private func journalLevelTag(text: String, bg: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(bg.opacity(0.85)))
    }

    /// Entry-line colour keys to the trade's state: amber when
    /// pending, success/danger for active long/short.
    private func tradeEntryColor(_ t: Trade) -> Color {
        switch t.status {
        case .pending:        return Theme.Color.warn
        case .active:         return t.side == .short ? Theme.Color.danger : Theme.Color.success
        default:              return Theme.Color.textMuted
        }
    }

    /// Wide capsule pinned to the entry rule: bias chip, lot size,
    /// status, and live P/L for active trades.
    private func tradeEntryTag(_ t: Trade) -> some View {
        let pl: Double = livePrice.map { t.currentPL(at: $0) } ?? 0
        let plText: String? = {
            guard t.status == .active, livePrice != nil else { return nil }
            let sign = pl >= 0 ? "+" : "−"
            return "\(sign)$\(String(format: "%.2f", abs(pl)))"
        }()
        return HStack(spacing: 4) {
            Text(t.sideLabel)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(tradeEntryColor(t)))
            Text("\(String(format: "%.2f", t.lots)) · \(t.statusLabel.uppercased())")
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
            if let plText = plText {
                Text(plText)
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(pl >= 0 ? Theme.Color.success : Theme.Color.danger)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(Color.black.opacity(0.6))
        )
    }

    /// User-drawn shapes from the per-pair DrawingStore. Date-anchored
    /// points are resolved to bar indices at render time, so a trend
    /// line drawn on yesterday's bars stays glued to those bars when
    /// new candles arrive. Skips shapes whose endpoints can't be
    /// resolved (e.g. when the series is empty or the timeframe was
    /// flipped to a window that doesn't contain the anchor date).
    /// Drawings to draw on the chart this frame: every visible
    /// committed drawing, with the in-flight moving one swapped for
    /// its translated preview. Keeps the IDs identical so ForEach
    /// diffs stably and the move feels like in-place movement rather
    /// than a delete-and-redraw.
    private var renderableDrawings: [ChartDrawing] {
        let movingID = movingDrawingOriginal?.id
        let editingID = editingDrawingID
        var out = drawings.filter { d in
            d.visible && d.id != movingID && d.id != editingID
        }
        if let moving = movingDrawingOriginal, moving.visible {
            out.append(translated(moving))
        }
        // For the drawing whose handle is being dragged, render the
        // resized preview rather than the original geometry — same
        // pattern as the move case so exactly one instance is on the
        // chart at any time.
        if let id = editingID,
           let original = drawings.first(where: { $0.id == id }),
           original.visible,
           let cursor = editingCursor,
           let anchor = editingHandle
        {
            out.append(original.resized(anchor: anchor, to: cursor))
        }
        return out
    }

    @ChartContentBuilder
    private var drawingMarks: some ChartContent {
        // While the user is dragging an existing drawing, swap the
        // original for a translated copy so exactly one instance of
        // the shape sits on the chart — the live one under the cursor.
        // Keeping the IDs identical lets ForEach diff stably.
        ForEach(renderableDrawings) { d in
            let stroke = d.color.color
            let lw = CGFloat(d.lineWidth)
            switch d.kind {
            case .horizontalLine:
                RuleMark(y: .value("Drawing", d.start.price))
                    .foregroundStyle(stroke)
                    .lineStyle(StrokeStyle(lineWidth: lw, dash: [6, 3]))
            case .trendLine:
                if let end = d.end,
                   let xs = barIndex(forDate: d.start.date),
                   let xe = barIndex(forDate: end.date)
                {
                    LineMark(
                        x: .value("Bar", xs),
                        y: .value("Price", d.start.price),
                        series: .value("Drawing", d.id.uuidString)
                    )
                    .foregroundStyle(stroke)
                    .lineStyle(StrokeStyle(lineWidth: lw))
                    LineMark(
                        x: .value("Bar", xe),
                        y: .value("Price", end.price),
                        series: .value("Drawing", d.id.uuidString)
                    )
                    .foregroundStyle(stroke)
                    .lineStyle(StrokeStyle(lineWidth: lw))
                }
            case .rectangle:
                if let end = d.end,
                   let xs = barIndex(forDate: d.start.date),
                   let xe = barIndex(forDate: end.date)
                {
                    let x0 = min(xs, xe), x1 = max(xs, xe)
                    let y0 = min(d.start.price, end.price)
                    let y1 = max(d.start.price, end.price)
                    // Translucent fill — 1 RectangleMark
                    RectangleMark(
                        xStart: .value("X0", x0), xEnd: .value("X1", x1),
                        yStart: .value("Y0", y0), yEnd: .value("Y1", y1)
                    )
                    .foregroundStyle(stroke.opacity(d.color.alpha * 0.18))
                    // Border — 4 RuleMarks (top/bottom/left/right)
                    // instead of the prior 8 LineMarks.
                    let borderStyle = StrokeStyle(lineWidth: lw)
                    RuleMark(xStart: .value("T", x0), xEnd: .value("T", x1),
                             y: .value("Top", y1))
                        .foregroundStyle(stroke).lineStyle(borderStyle)
                    RuleMark(xStart: .value("B", x0), xEnd: .value("B", x1),
                             y: .value("Bot", y0))
                        .foregroundStyle(stroke).lineStyle(borderStyle)
                    RuleMark(x: .value("L", x0),
                             yStart: .value("L0", y0), yEnd: .value("L1", y1))
                        .foregroundStyle(stroke).lineStyle(borderStyle)
                    RuleMark(x: .value("R", x1),
                             yStart: .value("R0", y0), yEnd: .value("R1", y1))
                        .foregroundStyle(stroke).lineStyle(borderStyle)
                }
            case .volumeProfile:
                if let end = d.end,
                   let xs = barIndex(forDate: d.start.date),
                   let xe = barIndex(forDate: end.date)
                {
                    vpMarks(for: d, end: end, xs: xs, xe: xe, stroke: stroke, lw: lw)
                }
            case .longPosition, .shortPosition:
                if let end = d.end,
                   let xs = barIndex(forDate: d.start.date),
                   let xe = barIndex(forDate: end.date)
                {
                    positionMarks(for: d, xs: xs, xe: xe)
                }
            }
        }

        // Selection handles — rendered last so they sit on top of every
        // committed mark. Only the selected drawing gets handles; click
        // anywhere else to deselect.
        selectionHandleMarks
    }

    // MARK: - Position tool

    /// A long/short position box: a green reward zone from entry to
    /// target, a red risk zone from entry to stop, the entry line
    /// between them, and a label carrying lot size + P/L.
    ///
    /// Zones are drawn from the entry outward rather than as one box so
    /// each side keeps its own colour even when the user drags a level
    /// through the entry (an inverted setup still renders truthfully
    /// instead of flipping colours).
    @ChartContentBuilder
    private func positionMarks(for d: ChartDrawing, xs: Double, xe: Double) -> some ChartContent {
        let x0 = min(xs, xe), x1 = max(xs, xe)
        let entry = d.start.price

        // ── Reward zone ─────────────────────────────────────────────
        if let target = d.targetPrice {
            RectangleMark(
                xStart: .value("X0", x0), xEnd: .value("X1", x1),
                yStart: .value("Y0", entry), yEnd: .value("Y1", target)
            )
            .foregroundStyle(DrawingPalette.profit.opacity(DrawingPalette.zoneAlpha))
            RuleMark(xStart: .value("T0", x0), xEnd: .value("T1", x1),
                     y: .value("Target", target))
                .foregroundStyle(DrawingPalette.profit)
                .lineStyle(StrokeStyle(lineWidth: 1))
        }

        // ── Risk zone ───────────────────────────────────────────────
        if let stop = d.stopPrice {
            RectangleMark(
                xStart: .value("X0", x0), xEnd: .value("X1", x1),
                yStart: .value("Y0", entry), yEnd: .value("Y1", stop)
            )
            .foregroundStyle(DrawingPalette.loss.opacity(DrawingPalette.zoneAlpha))
            RuleMark(xStart: .value("S0", x0), xEnd: .value("S1", x1),
                     y: .value("Stop", stop))
                .foregroundStyle(DrawingPalette.loss)
                .lineStyle(StrokeStyle(lineWidth: 1))
        }

        // ── Entry ───────────────────────────────────────────────────
        RuleMark(xStart: .value("E0", x0), xEnd: .value("E1", x1),
                 y: .value("Entry", entry))
            .foregroundStyle(DrawingPalette.entryLine)
            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
            .annotation(position: .topLeading, spacing: 2) {
                positionLabel(for: d)
            }
    }

    /// Lot size, risk, reward and R:R for a position box. Rendered as a
    /// chart annotation so it tracks the entry line as the user drags.
    @ViewBuilder
    private func positionLabel(for d: ChartDrawing) -> some View {
        let metrics = d.positionMetrics(spec: contractSpec)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(d.kind.isLong ? "LONG" : "SHORT")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(d.kind.isLong ? DrawingPalette.profit : DrawingPalette.loss)
                if let m = metrics {
                    Text(String(format: "%.3f lots", m.lots))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.Color.textPrimary)
                }
            }
            if let m = metrics {
                HStack(spacing: 5) {
                    Text("−" + Self.moneyShort(m.riskAmount))
                        .foregroundStyle(DrawingPalette.loss)
                    if let reward = m.reward {
                        Text("+" + Self.moneyShort(reward))
                            .foregroundStyle(DrawingPalette.profit)
                    }
                    if let rr = m.rr {
                        Text(String(format: "%.2fR", rr))
                            .foregroundStyle(Theme.Color.textMuted)
                    }
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                // A size no broker will accept is worth saying out loud
                // rather than leaving the trader to notice the decimals.
                if m.belowMinLot {
                    Text("below min lot")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Color.warn)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.Color.surfaceMax.opacity(0.85))
        )
    }

    /// Compact money formatting for the position label — "$1.2k" keeps
    /// the annotation narrow enough not to cover price action.
    static func moneyShort(_ v: Double) -> String {
        let a = abs(v)
        if a >= 1_000_000 { return String(format: "$%.2fM", v / 1_000_000) }
        if a >= 1_000     { return String(format: "$%.1fk", v / 1_000) }
        return String(format: "$%.0f", v)
    }

    /// Small square handles drawn at the selected drawing's endpoints
    /// or corners. These are the grab targets for the reshape gesture.
    /// While a handle is being dragged we render an additional handle
    /// at the *live* cursor position via `editingPreviewMarks` so the
    /// user sees where they're moving the endpoint to.
    @ChartContentBuilder
    private var selectionHandleMarks: some ChartContent {
        if let sel = selectionTargetDrawing {
            ForEach(handlePositions(for: sel), id: \.self) { hp in
                PointMark(
                    x: .value("Handle X", hp.x),
                    y: .value("Handle Y", hp.y)
                )
                .symbol(.square)
                .symbolSize(70)
                .foregroundStyle(Color.white)
            }
        }
        // Live-preview handle for the endpoint the user is currently
        // dragging — sits on top of the others so the active endpoint
        // visually leads the gesture.
        if let cursor = editingCursor,
           let id = editingDrawingID,
           let _ = drawings.first(where: { $0.id == id }),
           let xs = barIndex(forDate: cursor.date)
        {
            PointMark(
                x: .value("Edit X", xs),
                y: .value("Edit Y", cursor.price)
            )
            .symbol(.circle)
            .symbolSize(90)
            .foregroundStyle(Color.white)
        }
    }

    /// The drawing whose handles should be shown — the selected one,
    /// or the in-flight edit target so the handle being dragged stays
    /// rendered even if `selectedDrawingID` was cleared elsewhere.
    private var selectionTargetDrawing: ChartDrawing? {
        if let id = editingDrawingID,
           let d = drawings.first(where: { $0.id == id })
        {
            return resizedPreview(of: d) ?? d
        }
        if let id = selectedDrawingID,
           let d = drawings.first(where: { $0.id == id }),
           d.visible
        {
            return d
        }
        return nil
    }

    /// Bar-index + price coordinates for each handle of a drawing.
    /// Returns the empty list when the drawing's endpoints can't be
    /// resolved (e.g. the anchor date is far outside the current
    /// candle window).
    private func handlePositions(for d: ChartDrawing) -> [HandlePoint] {
        switch d.kind {
        case .horizontalLine:
            // Single handle pinned to the right edge of the visible
            // window so the user always has something to grab.
            return [HandlePoint(x: effectiveXDomain.upperBound - 0.5, y: d.start.price)]
        case .trendLine:
            guard let end = d.end,
                  let xs = barIndex(forDate: d.start.date),
                  let xe = barIndex(forDate: end.date)
            else { return [] }
            return [
                HandlePoint(x: xs, y: d.start.price),
                HandlePoint(x: xe, y: end.price)
            ]
        case .rectangle, .volumeProfile:
            guard let end = d.end,
                  let xs = barIndex(forDate: d.start.date),
                  let xe = barIndex(forDate: end.date)
            else { return [] }
            return [
                HandlePoint(x: xs, y: d.start.price),
                HandlePoint(x: xe, y: d.start.price),
                HandlePoint(x: xs, y: end.price),
                HandlePoint(x: xe, y: end.price)
            ]
        case .longPosition, .shortPosition:
            guard let end = d.end,
                  let xs = barIndex(forDate: d.start.date),
                  let xe = barIndex(forDate: end.date)
            else { return [] }
            // Entry / stop / target grab points sit on the left edge so
            // they never collide with the time handle on the right.
            // Levels the position doesn't have simply get no handle.
            var pts = [HandlePoint(x: xs, y: d.start.price)]
            if let stop = d.stopPrice     { pts.append(HandlePoint(x: xs, y: stop)) }
            if let target = d.targetPrice { pts.append(HandlePoint(x: xs, y: target)) }
            pts.append(HandlePoint(x: xe, y: d.start.price))
            return pts
        }
    }

    /// Coordinate pair for a selection handle, plottable on the chart.
    /// Hashable so `ForEach(id: \.self)` can identify it without an
    /// explicit Identifiable wrapper — there are at most four handles
    /// in flight at once, so naive hashing is fine.
    struct HandlePoint: Hashable {
        let x: Double
        let y: Double
    }

    /// Apply the in-flight handle drag (if any) to produce a preview
    /// of the drawing in its new shape. Returns nil when no edit is
    /// active or the cursor hasn't resolved to a valid point yet.
    private func resizedPreview(of d: ChartDrawing) -> ChartDrawing? {
        guard editingDrawingID == d.id,
              let anchor = editingHandle,
              let cursor = editingCursor
        else { return nil }
        return d.resized(anchor: anchor, to: cursor)
    }

    /// Translucent live preview of the shape being drawn right now.
    /// Falls back to nothing if the user hasn't started a draw — the
    /// `drawingStart` state is the canonical "is the user actively
    /// drawing" flag.
    @ChartContentBuilder
    private var drawingPreviewMarks: some ChartContent {
        if let s = drawingStart {
            switch activeTool {
            case .none:
                // Unreachable in practice — handleDrawChange only sets
                // drawingStart when a tool is armed.
                RuleMark(y: .value("noop", s.price))
                    .opacity(0)
            case .horizontalLine:
                RuleMark(y: .value("Preview", s.price))
                    .foregroundStyle(DrawingPalette.preview)
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
            case .trendLine:
                if let e = drawingEnd,
                   let xs = barIndex(forDate: s.date),
                   let xe = barIndex(forDate: e.date)
                {
                    LineMark(
                        x: .value("Bar", xs),
                        y: .value("Price", s.price),
                        series: .value("Preview", "drawing-preview")
                    )
                    .foregroundStyle(DrawingPalette.preview)
                    .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
                    LineMark(
                        x: .value("Bar", xe),
                        y: .value("Price", e.price),
                        series: .value("Preview", "drawing-preview")
                    )
                    .foregroundStyle(DrawingPalette.preview)
                    .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
                }
            case .rectangle:
                if let e = drawingEnd,
                   let xs = barIndex(forDate: s.date),
                   let xe = barIndex(forDate: e.date)
                {
                    RectangleMark(
                        xStart: .value("Preview X start", min(xs, xe)),
                        xEnd:   .value("Preview X end",   max(xs, xe)),
                        yStart: .value("Preview Y start", min(s.price, e.price)),
                        yEnd:   .value("Preview Y end",   max(s.price, e.price))
                    )
                    .foregroundStyle(DrawingPalette.fill.opacity(0.6))
                }
            case .volumeProfile:
                // Preview as a dashed rectangle outline while dragging
                if let e = drawingEnd,
                   let xs = barIndex(forDate: s.date),
                   let xe = barIndex(forDate: e.date)
                {
                    RectangleMark(
                        xStart: .value("VP Preview x0", min(xs, xe)),
                        xEnd:   .value("VP Preview x1", max(xs, xe)),
                        yStart: .value("VP Preview y0", min(s.price, e.price)),
                        yEnd:   .value("VP Preview y1", max(s.price, e.price))
                    )
                    .foregroundStyle(DrawingPalette.fill.opacity(0.25))
                }
            case .longPosition, .shortPosition:
                // Preview the risk/reward split the drag will produce:
                // the drag height becomes the stop distance, and the
                // target sits 2R the other side of entry (matching
                // `ChartDrawing.position`).
                if let e = drawingEnd,
                   let xs = barIndex(forDate: s.date),
                   let xe = barIndex(forDate: e.date)
                {
                    let long = activeTool == .longPosition
                    let dist = abs(e.price - s.price)
                    let stop   = long ? s.price - dist : s.price + dist
                    let target = long ? s.price + dist * 2 : s.price - dist * 2
                    RectangleMark(
                        xStart: .value("Pos preview x0", min(xs, xe)),
                        xEnd:   .value("Pos preview x1", max(xs, xe)),
                        yStart: .value("Pos preview y0", s.price),
                        yEnd:   .value("Pos preview y1", target)
                    )
                    .foregroundStyle(DrawingPalette.profit.opacity(0.14))
                    RectangleMark(
                        xStart: .value("Pos preview x2", min(xs, xe)),
                        xEnd:   .value("Pos preview x3", max(xs, xe)),
                        yStart: .value("Pos preview y2", s.price),
                        yEnd:   .value("Pos preview y3", stop)
                    )
                    .foregroundStyle(DrawingPalette.loss.opacity(0.14))
                }
            }
        }
    }

    /// Bias + entry capsule. Sits on the entry line. Renders the bias
    /// chip ("LONG"/"SHORT"/"NEUTRAL") next to "ENTRY <price>" plus a
    /// validity badge so the user can see at a glance whether the
    /// plan is still in play (green ✓ VALID) or has been invalidated
    /// by current price (red ✗ INVALID, with entry text struck
    /// through). `isAlt` slips an "ALT" prefix before the bias so
    /// stacked main+alt capsules read cleanly.
    private func scenarioEntryTag(
        scenario: PromptBuilder.TAScenario,
        entry: Double,
        isAlt: Bool
    ) -> some View {
        let biasLabel: String
        let biasColor: Color
        switch scenario.bias {
        case .long:    biasLabel = "LONG";    biasColor = Theme.Color.success
        case .short:   biasLabel = "SHORT";   biasColor = Theme.Color.danger
        case .neutral: biasLabel = "NEUTRAL"; biasColor = Theme.Color.textSecondary
        }
        let prefix = isAlt ? "ALT · " : ""
        // Validity verdict. Without a live price we lean toward
        // "still valid" so the badge doesn't false-positive on cold
        // start; the moment a price arrives the badge becomes
        // authoritative.
        let valid: Bool = livePrice.map { scenario.isValid(at: $0) } ?? true
        return HStack(spacing: 4) {
            Text(prefix + biasLabel)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(biasColor.opacity(isAlt ? 0.7 : 1)))
            Text("ENTRY \(Self.priceShort(entry))")
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .strikethrough(!valid, color: Theme.Color.danger)
            validityBadge(valid: valid)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(Color.black.opacity(0.55))
        )
    }

    /// Tiny VALID / INVALID pill stacked next to the entry text on
    /// each scenario tag. Green when the plan's SL hasn't been
    /// touched, red when it has.
    private func validityBadge(valid: Bool) -> some View {
        Text(valid ? "✓ VALID" : "✗ INVALID")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(valid
                               ? Theme.Color.success.opacity(0.85)
                               : Theme.Color.danger.opacity(0.85))
            )
    }

    /// Compact level capsule used for TP / SL labels. Single colour,
    /// single line of text so the three scenario tags read consistently
    /// when stacked at the right edge.
    private func levelTag(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(color.opacity(0.85))
            )
    }

    /// Small price-tag capsule. Mirrors the last-price tag's overlay
    /// position so it sits inline on the rule rather than escaping past
    /// the plot edge (where the chart's `.clipped()` would chop it).
    private func srTag(price: Double, isSupport: Bool) -> some View {
        HStack(spacing: 3) {
            Text(isSupport ? "S" : "R")
                .font(.system(size: 8, weight: .bold))
            Text(Self.priceShort(price))
                .font(.system(size: 9, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(isSupport ? Theme.Color.success : Theme.Color.danger)
        )
    }

    /// UT Bot trailing-stop line + buy/sell signal labels. Returns no
    /// content when the indicator is toggled off.
    @ChartContentBuilder
    private func utBotMarks(indices: [Int], visible: Set<Int>) -> some ChartContent {
        if let out = utBotOutput {
            // Trailing stop: amber stepped line across all bars where
            // the stop is defined. Toggled by the user via the UT Bot
            // settings — when off, only the buy/sell labels remain.
            if indicatorConfig.utShowTrailingStop {
                ForEach(indices, id: \.self) { i in
                    if i < out.trailingStop.count, let v = out.trailingStop[i] {
                        LineMark(
                            x: .value("Bar", Double(i)),
                            y: .value("UT Stop", v),
                            series: .value("Series", "utbot-trail")
                        )
                        .foregroundStyle(IndicatorKind.utBot.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.4, lineJoin: .miter))
                        .interpolationMethod(.stepStart)
                    }
                }
            }
            // Buy/Sell labels — positioned just below (buy) or above
            // (sell) the candle's actual extreme so the marker doesn't
            // sit on top of the wick.
            let cs = displayCandles
            ForEach(out.signals.filter { visible.contains($0.index) }) { sig in
                let c = cs[sig.index]
                PointMark(
                    x: .value("Bar", Double(sig.index)),
                    y: .value("Signal", sig.isBuy ? c.low : c.high)
                )
                .symbol(.circle)
                .symbolSize(0)   // hide the point itself; we just want the annotation
                .annotation(
                    position: sig.isBuy ? .bottom : .top,
                    alignment: .center,
                    spacing: 2
                ) {
                    Text(sig.isBuy ? "BUY" : "SELL")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(sig.isBuy
                                           ? Theme.Color.success
                                           : Theme.Color.danger)
                        )
                }
            }
        }
    }

    /// Indicator overlays. Each enabled indicator becomes one or more
    /// `LineMark` series keyed by `series:` so Apple Charts treats the
    /// points as a single connected line (rather than a per-point disjoint
    /// segment).
    @ChartContentBuilder
    private func indicatorMarks(visible: Set<Int>) -> some ChartContent {
        let instances = indicatorInstances.isEmpty
            ? indicators.map { Self.makeIndicatorInstance(kind: $0, config: indicatorConfig) }
            : indicatorInstances
        let computed = derived.indicators(instances: instances, candles: candles)
        ForEach(computed, id: \.instance.id) { entry in
            ForEach(entry.points.filter { visible.contains($0.index) }) { p in
                LineMark(
                    x: .value("Bar", Double(p.index)),
                    y: .value("Indicator", p.value),
                    series: .value("Series", "\(entry.instance.id)-\(p.band)")
                )
                .foregroundStyle(indicatorColor(for: entry.instance.kind, band: p.band))
                .lineStyle(StrokeStyle(
                    lineWidth: indicatorLineWidth(for: p.band),
                    dash: p.band == "bb_mid" ? [3, 3] : []
                ))
                .interpolationMethod(.monotone)
            }
        }
    }

    /// Bollinger upper/lower share the indicator's accent; middle uses a
    /// muted version so the band is visually clearly the "envelope".
    private func indicatorColor(for kind: IndicatorKind, band: String) -> Color {
        switch band {
        case "bb_upper", "bb_lower": return kind.color
        case "bb_mid":               return kind.color.opacity(0.55)
        default:                     return kind.color
        }
    }

    /// Slightly thinner middle Bollinger line; everything else 1.6pt.
    private func indicatorLineWidth(for band: String) -> CGFloat {
        band == "bb_mid" ? 1 : 1.6
    }

    // Ichimoku component colours — kept close to the traditional TradingView
    // palette so the overlay reads familiarly.
    private static let ichiTenkanColor = Color(red: 0.30, green: 0.65, blue: 1.00)
    private static let ichiKijunColor  = Color(red: 0.95, green: 0.45, blue: 0.35)
    private static let ichiSpanAColor  = Color(red: 0.30, green: 0.78, blue: 0.52)
    private static let ichiSpanBColor  = Color(red: 0.88, green: 0.38, blue: 0.44)
    private static let ichiChikouColor = Color(red: 0.72, green: 0.55, blue: 0.95)

    /// Ichimoku Cloud — the shaded Kumo (two-tone `AreaMark` ribbon)
    /// behind the five component lines. Displacement is already baked into
    /// each point's plot index, so we just filter to the visible window
    /// and plot. The forward-projected tail past the last candle sits
    /// outside the x-domain and is clipped.
    @ChartContentBuilder
    private func ichimokuMarks(visible: Set<Int>) -> some ChartContent {
        let out = ichimokuOutput
        // Kumo fill first so the lines read on top of it.
        if indicatorConfig.ichiShowCloud {
            ForEach(out.cloud.filter { visible.contains($0.index) }) { c in
                AreaMark(
                    x: .value("Bar", Double(c.index)),
                    yStart: .value("Span B", c.spanB),
                    yEnd: .value("Span A", c.spanA)
                )
                .foregroundStyle(
                    (c.isBullish ? Self.ichiSpanAColor : Self.ichiSpanBColor).opacity(0.14)
                )
                .interpolationMethod(.monotone)
            }
        }
        ichimokuLine(out.senkouA, band: "ichiA", color: Self.ichiSpanAColor, width: 1, visible: visible)
        ichimokuLine(out.senkouB, band: "ichiB", color: Self.ichiSpanBColor, width: 1, visible: visible)
        ichimokuLine(out.tenkan, band: "ichiTenkan", color: Self.ichiTenkanColor, width: 1.4, visible: visible)
        ichimokuLine(out.kijun, band: "ichiKijun", color: Self.ichiKijunColor, width: 1.6, visible: visible)
        if indicatorConfig.ichiShowChikou {
            ichimokuLine(out.chikou, band: "ichiChikou", color: Self.ichiChikouColor, width: 1, visible: visible)
        }
    }

    /// One Ichimoku line series, keyed by `band` so Charts connects it as
    /// a single line rather than disjoint segments.
    @ChartContentBuilder
    private func ichimokuLine(
        _ points: [Ichimoku.LinePoint],
        band: String,
        color: Color,
        width: CGFloat,
        visible: Set<Int>
    ) -> some ChartContent {
        ForEach(points.filter { visible.contains($0.index) }) { p in
            LineMark(
                x: .value("Bar", Double(p.index)),
                y: .value("Ichimoku", p.value),
                series: .value("Series", band)
            )
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: width))
            .interpolationMethod(.monotone)
        }
    }

    /// Ichimoku-confluence Order Block zones — like the plain order-block
    /// overlay but tagged with the confluence score and the components it
    /// lined up with.
    @ChartContentBuilder
    private var ichimokuOBMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(ichimokuOBZones) { zone in
            ichimokuOBMark(for: zone, lastIndex: lastIndex)
        }
    }

    @ChartContentBuilder
    private func ichimokuOBMark(for zone: IchimokuOrderBlocks.Zone, lastIndex: Int) -> some ChartContent {
        let baseColor: Color = zone.isBullish ? Theme.Color.success : Theme.Color.danger
        let xStart = Double(zone.index)
        let xEnd   = Double(lastIndex)
        // Stronger confluence → more opaque fill.
        let fillOpacity = min(0.30, 0.08 + Double(zone.confluenceScore) * 0.05)

        RectangleMark(
            xStart: .value("iOB start", xStart),
            xEnd:   .value("iOB end",   xEnd),
            yStart: .value("iOB low",   zone.low),
            yEnd:   .value("iOB high",  zone.high)
        )
        .foregroundStyle(baseColor.opacity(fillOpacity))

        RuleMark(
            xStart: .value("iOB s hi", xStart), xEnd: .value("iOB e hi", xEnd),
            y: .value("iOB hi", zone.high)
        )
        .foregroundStyle(baseColor.opacity(0.7))
        .lineStyle(StrokeStyle(lineWidth: 1))
        RuleMark(
            xStart: .value("iOB s lo", xStart), xEnd: .value("iOB e lo", xEnd),
            y: .value("iOB lo", zone.low)
        )
        .foregroundStyle(baseColor.opacity(0.7))
        .lineStyle(StrokeStyle(lineWidth: 1))

        PointMark(
            x: .value("iOB label", xEnd),
            y: .value("iOB hi", zone.high)
        )
        .symbolSize(0)
        .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
            let tag = zone.isBullish ? "☁OB↑" : "☁OB↓"
            let detail = zone.reasons.isEmpty ? "" : " · " + zone.reasons.joined(separator: "·")
            Text("\(tag) \(zone.confluenceScore)\(detail)")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(baseColor.opacity(0.95)))
        }
    }

    // MARK: - Volume-Filtered Order Blocks

    @ChartContentBuilder
    private var volumeFilteredOBMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(volumeFilteredOBZones) { zone in
            volumeFilteredOBMark(zone, lastIndex: lastIndex)
        }
    }

    @ChartContentBuilder
    private func volumeFilteredOBMark(_ zone: VolumeFilteredOrderBlocks.Zone, lastIndex: Int) -> some ChartContent {
        let base: Color = zone.isBullish ? Theme.Color.success : Theme.Color.danger
        let fillOp = zone.breaker ? 0.08 : 0.20
        let borderOp = zone.breaker ? 0.35 : 0.75
        let xStart = Double(zone.startIndex)
        let xEnd   = Double(min(zone.endIndex, lastIndex))

        RectangleMark(
            xStart: .value("VFOB x0", xStart), xEnd: .value("VFOB x1", xEnd),
            yStart: .value("VFOB y0", zone.bottom), yEnd: .value("VFOB y1", zone.top)
        )
        .foregroundStyle(base.opacity(fillOp))

        RuleMark(xStart: .value("VFOB t0", xStart), xEnd: .value("VFOB t1", xEnd), y: .value("VFOB top", zone.top))
            .foregroundStyle(base.opacity(borderOp))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: zone.breaker ? [3, 3] : []))
        RuleMark(xStart: .value("VFOB b0", xStart), xEnd: .value("VFOB b1", xEnd), y: .value("VFOB bot", zone.bottom))
            .foregroundStyle(base.opacity(borderOp))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: zone.breaker ? [3, 3] : []))

        // Volumetric split — an up-volume (top half) and down-volume
        // (bottom half) bar anchored at the block's left edge, widths ∝
        // each share of the block's total volume.
        if indicatorConfig.vfobVolumetricInfo, zone.volume > 0 {
            let mid = (zone.top + zone.bottom) / 2
            let span = max(1.0, xEnd - xStart)
            let barMax = min(span * 0.5, 8.0)
            let upW = barMax * (zone.highVolume / zone.volume)
            let dnW = barMax * (zone.lowVolume / zone.volume)
            RectangleMark(
                xStart: .value("VFOB uv0", xStart), xEnd: .value("VFOB uv1", xStart + upW),
                yStart: .value("VFOB uvy0", mid), yEnd: .value("VFOB uvy1", zone.top)
            )
            .foregroundStyle(Theme.Color.success.opacity(0.55))
            RectangleMark(
                xStart: .value("VFOB dv0", xStart), xEnd: .value("VFOB dv1", xStart + dnW),
                yStart: .value("VFOB dvy0", zone.bottom), yEnd: .value("VFOB dvy1", mid)
            )
            .foregroundStyle(Theme.Color.danger.opacity(0.55))

            PointMark(x: .value("VFOB lbl x", xEnd), y: .value("VFOB lbl y", zone.top))
                .symbolSize(0)
                .annotation(position: .overlay, alignment: .topTrailing, spacing: 0) {
                    Text("\(Self.volumeShort(zone.volume)) (\(zone.balancePct)%)")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(base.opacity(0.9)))
                }
        }
    }

    /// Compact volume formatter (1.2K / 3.4M / 5.1B) for the OB labels.
    private static func volumeShort(_ v: Double) -> String {
        let a = abs(v)
        switch a {
        case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
        case 1_000_000...:     return String(format: "%.1fM", v / 1_000_000)
        case 1_000...:         return String(format: "%.1fK", v / 1_000)
        default:               return String(format: "%.0f", v)
        }
    }

    private static func makeIndicatorInstance(kind: IndicatorKind, config: OscillatorConfig) -> IndicatorInstance {
        let raw = kind.rawValue
        let padded = raw.padding(toLength: 12, withPad: "0", startingAt: 0)
        let stableID = UUID(uuidString: "00000000-0000-0000-0000-\(padded)") ?? UUID()
        var params: [String: ParamValue] = [:]
        switch kind {
        case .sma20:  params["period"] = .double(20)
        case .sma50:  params["period"] = .double(50)
        case .sma200: params["period"] = .double(200)
        case .ema9:   params["period"] = .double(9)
        case .ema21:  params["period"] = .double(21)
        case .bollinger:
            params["period"] = .double(20)
            params["stdDev"] = .double(2)
        case .utBot:
            params["keyValue"]      = .double(config.utKeyValue)
            params["atrPeriod"]     = .double(Double(config.utATRPeriod))
            params["useHeikinAshi"] = .bool(config.utUseHeikinAshi)
        case .sp2lStrategy:
            params["minSpikeBars"]        = .double(Double(config.sp2lMinSpikeBars))
            params["maxSpikeBars"]        = .double(Double(config.sp2lMaxSpikeBars))
            params["rangeBars"]           = .double(Double(config.sp2lRangeBars))
            params["atrPeriod"]           = .double(Double(config.sp2lATRPeriod))
            params["minSpikeATR"]         = .double(config.sp2lMinSpikeATR)
            params["maxSpikeATR"]         = .double(config.sp2lMaxSpikeATR)
            params["maxRangeATR"]         = .double(config.sp2lMaxRangeATR)
            params["minGapPct"]           = .double(config.sp2lMinGapPct)
            params["maxPressureGapBar"]   = .double(Double(config.sp2lMaxPressureGapBar))
            params["emaPeriod"]           = .double(Double(config.sp2lEMAPeriod))
            params["useEMAContext"]       = .bool(config.sp2lUseEMAContext)
            params["maxEMADistanceATR"]   = .double(config.sp2lMaxEMADistanceATR)
            params["maxPullbackBars"]     = .double(Double(config.sp2lMaxPullbackBars))
            params["maxContinuationBars"] = .double(Double(config.sp2lMaxContinuationBars))
            params["riskReward"]          = .double(config.sp2lRiskReward)
            params["targetCount"]         = .double(Double(config.sp2lTargetCount))
        case .pinBarCombo:
            params["enableSP2L"]            = .bool(config.pinBarEnableSP2L)
            params["enableBTB"]             = .bool(config.pinBarEnableBTB)
            params["atrPeriod"]             = .double(Double(config.pinBarATRPeriod))
            params["minWickBodyRatio"]      = .double(config.pinBarMinWickBodyRatio)
            params["minWickRangeRatio"]     = .double(config.pinBarMinWickRangeRatio)
            params["maxBodyRangeRatio"]     = .double(config.pinBarMaxBodyRangeRatio)
            params["minCloseLocation"]      = .double(config.pinBarMinCloseLocation)
            params["oppositeWickDominance"] = .double(config.pinBarOppositeWickDominance)
            params["touchToleranceATR"]     = .double(config.pinBarTouchToleranceATR)
            params["stopBufferATR"]         = .double(config.pinBarStopBufferATR)
            params["maxConfirmationBars"]   = .double(Double(config.pinBarMaxConfirmationBars))
            params["btbLookbackBars"]       = .double(Double(config.pinBarBTBLookbackBars))
            params["minBreakoutBodyATR"]    = .double(config.pinBarMinBreakoutBodyATR)
            params["riskReward"]            = .double(config.pinBarRiskReward)
            params["maxContinuationBars"]   = .double(Double(config.pinBarMaxContinuationBars))
        case .microMapStrategy:
            params["atrPeriod"]             = .double(Double(config.microMapATRPeriod))
            params["minSpikeBars"]          = .double(Double(config.microMapMinSpikeBars))
            params["maxSpikeBars"]          = .double(Double(config.microMapMaxSpikeBars))
            params["minSpikeATR"]           = .double(config.microMapMinSpikeATR)
            params["minDirectionalRatio"]  = .double(config.microMapMinDirectionalRatio)
            params["minBodyRatio"]          = .double(config.microMapMinBodyRatio)
            params["maxCloseFromExtreme"]  = .double(config.microMapMaxCloseFromExtreme)
            params["minMicroBars"]          = .double(Double(config.microMapMinMicroBars))
            params["maxMicroBars"]          = .double(Double(config.microMapMaxMicroBars))
            params["maxMicroRangeRatio"]   = .double(config.microMapMaxMicroRangeRatio)
            params["maxRetracement"]        = .double(config.microMapMaxRetracement)
            params["structureToleranceATR"] = .double(config.microMapStructureToleranceATR)
            params["maxReentryBars"]        = .double(Double(config.microMapMaxReentryBars))
            params["riskReward"]             = .double(config.microMapRiskReward)
            params["confluenceBalanceBars"] = .double(Double(config.microMapConfluenceBalanceBars))
            params["confluenceEMAPeriod"]   = .double(Double(config.microMapConfluenceEMAPeriod))
            params["minPressureGapPct"]     = .double(config.microMapMinPressureGapPct)
            params["maxPressureGapBar"]     = .double(Double(config.microMapMaxPressureGapBar))
            params["requirePressureGap"]    = .bool(config.microMapRequirePressureGap)
            params["requireKeyLevelBreak"] = .bool(config.microMapRequireKeyLevelBreak)
            params["minConfluenceScore"]   = .double(Double(config.microMapMinConfluenceScore))
            params["notifyEvents"]           = .bool(config.microMapNotifyEvents)
        case .mtrStrategy:
            params["pivotDepth"]          = .double(Double(config.mtrPivotDepth))
            params["atrPeriod"]           = .double(Double(config.mtrATRPeriod))
            params["minTrendLegATR"]      = .double(config.mtrMinTrendLegATR)
            params["breakBufferATR"]      = .double(config.mtrBreakBufferATR)
            params["retestToleranceATR"]  = .double(config.mtrRetestToleranceATR)
            params["maxFailedBreakATR"]   = .double(config.mtrMaxFailedBreakATR)
            params["maxRetestBars"]       = .double(Double(config.mtrMaxRetestBars))
            params["maxConfirmationBars"] = .double(Double(config.mtrMaxConfirmationBars))
            params["stopBufferATR"]       = .double(config.mtrStopBufferATR)
            params["riskReward"]          = .double(config.mtrRiskReward)
            params["maxTradeBars"]        = .double(Double(config.mtrMaxTradeBars))
            params["maxResults"]          = .double(Double(config.mtrMaxResults))
        default:
            break
        }
        return IndicatorInstance(id: stableID, kind: kind, params: params)
    }

    @ChartContentBuilder
    private func candleMarks(indices: [Int]) -> some ChartContent {
        // See `lineMarks`: bind `displayCandles` once to avoid the
        // quadratic per-bar rebuild on deep history.
        let cs = displayCandles
        ForEach(indices, id: \.self) { i in
            let c = cs[i]
            // Wick — full high-to-low range.
            RuleMark(
                x: .value("Bar", Double(i)),
                yStart: .value("Low", c.low),
                yEnd: .value("High", c.high)
            )
            .foregroundStyle(c.close >= c.open ? Theme.Color.success : Theme.Color.danger)
            .lineStyle(StrokeStyle(lineWidth: 1))

            // Body — open to close. Width scales inversely with bar
            // count so dense charts don't smear together and sparse
            // ones don't look like toothpicks.
            RectangleMark(
                x: .value("Bar", Double(i)),
                yStart: .value("Body lo", min(c.open, c.close)),
                yEnd: .value("Body hi", max(c.open, c.close)),
                width: .fixed(candleBodyWidth)
            )
            .foregroundStyle(c.close >= c.open ? Theme.Color.success : Theme.Color.danger)
            .cornerRadius(1)
        }
    }

    // MARK: - Axes

    private func xAxis() -> some AxisContent {
        // Custom evenly-spaced label values based on bar indices. Apple
        // Charts can't auto-derive date labels for an index axis, so we
        // hand it the exact indices we want labels at, then look up each
        // candle's real date for the formatted text.
        AxisMarks(preset: .aligned, values: xAxisLabelValues) { value in
            AxisGridLine()
                .foregroundStyle(Color.white.opacity(0.04))
            AxisTick()
                .foregroundStyle(Color.white.opacity(0.08))
            AxisValueLabel {
                if let idx = value.as(Double.self),
                   let label = labelForIndex(idx)
                {
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.Color.textMuted)
                }
            }
        }
    }

    /// Pick ~6 evenly-spaced indices across the *visible* domain (so
    /// labels redistribute as you pan/zoom). Returns Doubles so they
    /// align exactly with the chart's X plottable type.
    private var xAxisLabelValues: [Double] {
        let domain = effectiveXDomain
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return [] }
        let count = 6
        return (0...count).map { i in
            domain.lowerBound + (span * Double(i) / Double(count))
        }
    }

    /// Format the date of the candle nearest `idx`. Out-of-range indices
    /// (e.g. pan past data) return nil so no label is drawn.
    private func labelForIndex(_ idx: Double) -> String? {
        let rounded = Int(idx.rounded())
        guard candles.indices.contains(rounded) else { return nil }
        return Self.axisFormatter.string(from: candles[rounded].bucketStart)
    }

    /// Compact axis label format: "10:30" / "Mon 10:30" — picked by
    /// looking at the visible time span elsewhere if we ever want to
    /// adapt it. For now, time-of-day is fine because charts default to
    /// recent windows.
    static let axisFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        return f
    }()

    private func yAxis() -> some AxisContent {
        AxisMarks(position: .trailing, values: .automatic(desiredCount: 6)) { value in
            AxisGridLine()
                .foregroundStyle(Color.white.opacity(0.04))
            AxisValueLabel {
                if let d = value.as(Double.self) {
                    Text(Self.priceShort(d))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.Color.textMuted)
                }
            }
        }
    }

    // MARK: - Hover tooltip

    @ViewBuilder
    private var hoverTooltip: some View {
        if let h = hovered {
            let c = h.candle
            let delta = c.close - c.open
            let pct = c.open > 0 ? (delta / c.open) * 100 : 0
            let isUp = c.close >= c.open

            VStack(alignment: .leading, spacing: 4) {
                Text(Self.dateFormatter.string(from: c.bucketStart))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Color.textMuted)
                HStack(spacing: 12) {
                    ohlcCell("O", c.open)
                    ohlcCell("H", c.high)
                    ohlcCell("L", c.low)
                    ohlcCell("C", c.close)
                }
                HStack(spacing: 4) {
                    Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("\(isUp ? "+" : "")\(Self.priceShort(delta)) (\(String(format: "%+.2f", pct))%)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(isUp ? Theme.Color.success : Theme.Color.danger)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.Color.surfaceMax.opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Theme.Color.border, lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 72))
            .transition(.opacity.animation(.easeOut(duration: 0.1)))
        }
    }

    private func ohlcCell(_ label: String, _ v: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.Color.textMuted)
            Text(Self.priceExact(v))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.Color.textPrimary)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        // During replay an empty chart almost always means the cursor
        // predates the stored history for this timeframe (1m only goes
        // back ~8 days, 5m ~1 month). Point the user at the fix instead
        // of the generic "wait for the next fetch" message.
        let replaying = replayActive
        return VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: replaying ? "clock.badge.exclamationmark" : "chart.xyaxis.line")
                .font(.system(size: 40))
                .foregroundStyle(replaying ? Theme.Color.warn.opacity(0.8) : Theme.Color.textMuted)
            Text(replaying ? "No stored bars this far back" : "No data for this timeframe")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Color.textSecondary)
            Text(replaying
                 ? "This timeframe's history doesn't reach the replay point. Switch to a higher timeframe (5m+) or pick a more recent start."
                 : "Wait for the next fetch cycle, or import older history.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Price-axis vertical scaling

    /// Transparent gesture column over the trailing price-axis gutter.
    /// Dragging it vertically scales the Y axis (TradingView's price-
    /// scale drag): drag DOWN to zoom out (compress candles), UP to zoom
    /// in (stretch them). Double-click clears the manual scale and hands
    /// the axis back to auto-fit. Width roughly matches the axis label
    /// gutter so it doesn't eat the chart canvas's pan/hover area.
    private var priceAxisScaleStrip: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .gesture(priceScaleDrag(plotHeight: geo.size.height))
                // Double-click the axis → back to auto-fit, matching
                // TradingView (and the chart's own reset control).
                .onTapGesture(count: 2) { yDomain = nil }
                // Resize cursor on hover so the column reads as draggable.
                .onHover { inside in
                    if inside { NSCursor.resizeUpDown.push() }
                    else      { NSCursor.pop() }
                }
        }
        .frame(width: 48)
    }

    /// Vertical drag → Y-axis scale. Anchors on the price window captured
    /// at drag start (`yScaleStartDomain`) and keeps its centre fixed, so
    /// the candles grow/shrink around the middle of the view rather than
    /// drifting. The factor is exponential in drag distance so the feel
    /// is consistent whether zoomed in or out.
    private func priceScaleDrag(plotHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if yScaleStartDomain == nil {
                    yScaleStartDomain = effectiveYDomain
                    hovered = nil
                }
                guard let start = yScaleStartDomain, plotHeight > 0 else { return }
                let center = (start.lowerBound + start.upperBound) / 2
                let halfSpan = (start.upperBound - start.lowerBound) / 2
                guard halfSpan > 0 else { return }
                // Drag down (+height) ⇒ factor > 1 ⇒ wider price window ⇒
                // smaller candles. Drag up ⇒ factor < 1 ⇒ zoom in. Clamp
                // so a frantic drag can't collapse or explode the scale.
                let raw = exp(Double(value.translation.height) / Double(plotHeight) * 1.6)
                let factor = min(max(raw, 0.1), 10)
                let newHalf = halfSpan * factor
                yDomain = (center - newHalf) ... (center + newHalf)
            }
            .onEnded { _ in yScaleStartDomain = nil }
    }

    /// Transparent gesture strip over the bottom time-axis gutter.
    /// Dragging it horizontally scales the X axis (TradingView's time-
    /// scale drag): drag LEFT to zoom out (compress candles), RIGHT to
    /// zoom in (stretch them). Double-click clears the manual window and
    /// hands the axis back to the default view. Trailing padding leaves
    /// the price-axis column's corner alone. Height roughly matches the
    /// axis-label gutter so it doesn't eat the chart canvas's pan area.
    private var timeAxisScaleStrip: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .gesture(timeScaleDrag(plotWidth: geo.size.width))
                // Double-click the axis → back to the default window,
                // matching the price axis's double-click-to-auto-fit.
                .onTapGesture(count: 2) { xDomain = nil }
                // Resize cursor on hover so the strip reads as draggable.
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() }
                    else      { NSCursor.pop() }
                }
        }
        .frame(height: 28)
        // Keep clear of the trailing price-axis scale column so a corner
        // drag doesn't fight between the two gestures.
        .padding(.trailing, 48)
    }

    /// Horizontal drag → X-axis scale. Anchors on the bar window captured
    /// at drag start (`xScaleStartDomain`) and keeps its centre fixed, so
    /// candles grow/shrink around the middle of the view. The factor is
    /// exponential in drag distance so the feel is consistent whether
    /// zoomed in or out (mirrors `priceScaleDrag`).
    private func timeScaleDrag(plotWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if xScaleStartDomain == nil {
                    xScaleStartDomain = effectiveXDomain
                    hovered = nil
                }
                guard let start = xScaleStartDomain, plotWidth > 0 else { return }
                let center = (start.lowerBound + start.upperBound) / 2
                let halfSpan = (start.upperBound - start.lowerBound) / 2
                guard halfSpan > 0 else { return }
                // Drag left (−width) ⇒ factor > 1 ⇒ wider time window ⇒
                // smaller candles. Drag right ⇒ factor < 1 ⇒ zoom in.
                // Clamp so a frantic drag can't collapse or explode it.
                let raw = exp(Double(-value.translation.width) / Double(plotWidth) * 1.6)
                let factor = min(max(raw, 0.1), 10)
                let newHalf = halfSpan * factor
                xDomain = (center - newHalf) ... (center + newHalf)
            }
            .onEnded { _ in xScaleStartDomain = nil }
    }

    // MARK: - Volume Profile

    @ChartContentBuilder
    private func vpMarks(
        for d: ChartDrawing, end: DrawingPoint,
        xs: Double, xe: Double,
        stroke: Color, lw: CGFloat
    ) -> some ChartContent {
        let buckets = computeVP(start: d.start.date, end: end.date)
        let maxVol  = buckets.map(\.volume).max() ?? 1
        if !buckets.isEmpty && maxVol > 0 {
            let rangeWidth  = abs(xe - xs)
            let maxBarWidth = rangeWidth * 0.28
            let bucketSize  = buckets.count > 1
                ? (buckets[1].priceLevel - buckets[0].priceLevel)
                : buckets[0].priceLevel * 0.001
            let pocLevel  = buckets.max(by: { $0.volume < $1.volume })?.priceLevel
            let rightEdge = max(xs, xe)
            let sid       = d.id.uuidString

            ForEach(Array(buckets.enumerated()), id: \.offset) { _, bucket in
                let barWidth = maxBarWidth * (bucket.volume / maxVol)
                let isPOC   = bucket.priceLevel == pocLevel
                let barColor: Color = isPOC
                    ? Color(red: 0.96, green: 0.36, blue: 0.36)
                    : stroke.opacity(0.75)
                RectangleMark(
                    xStart: .value("VP x0", rightEdge - barWidth),
                    xEnd:   .value("VP x1", rightEdge),
                    yStart: .value("VP y0", bucket.priceLevel),
                    yEnd:   .value("VP y1", bucket.priceLevel + bucketSize * 0.92)
                )
                .foregroundStyle(barColor.opacity(isPOC ? 0.85 : 0.55))
            }
            // Right-edge border
            LineMark(x: .value("VPr", rightEdge), y: .value("VPr0", d.start.price),
                     series: .value("S", "vpr0-\(sid)"))
                .foregroundStyle(stroke.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1))
            LineMark(x: .value("VPr", rightEdge), y: .value("VPr1", end.price),
                     series: .value("S", "vpr0-\(sid)"))
                .foregroundStyle(stroke.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1))
        }
    }

    struct VPBucket {
        let priceLevel: Double  // floor of the bucket
        let volume: Double
    }

    /// Compute a Fixed Range Volume Profile for the candles whose
    /// `bucketStart` falls in [start, end]. Divides the price range
    /// into `bucketCount` equal bands and sums each candle's volume
    /// into the band that contains its typical price ((H+L+C)/3).
    private func computeVP(start: Date, end: Date, bucketCount: Int = 30) -> [VPBucket] {
        let lo = min(start, end)
        let hi = max(start, end)
        let inRange = candles.filter { $0.bucketStart >= lo && $0.bucketStart <= hi }
        guard !inRange.isEmpty else { return [] }

        let priceMin = inRange.map(\.low).min()!
        let priceMax = inRange.map(\.high).max()!
        guard priceMax > priceMin else { return [] }

        let bucketSize = (priceMax - priceMin) / Double(bucketCount)
        var volumes = [Double](repeating: 0, count: bucketCount)

        for c in inRange {
            let typical = (c.high + c.low + c.close) / 3
            let idx = min(bucketCount - 1, Int((typical - priceMin) / bucketSize))
            let vol = c.volume ?? 0
            volumes[idx] += vol > 0 ? vol : 1
        }

        return (0..<bucketCount).map { i in
            VPBucket(priceLevel: priceMin + Double(i) * bucketSize,
                     volume: volumes[i])
        }
    }

    // MARK: - Derived

    /// Y-axis domain actually handed to Charts. A user-pinned manual
    /// scale (from dragging the price axis) wins; otherwise we auto-fit
    /// to the visible data via `autoYDomain`.
    private var effectiveYDomain: ClosedRange<Double> {
        yDomain ?? autoYDomain
    }

    /// Auto-fit Y-axis domain that hugs the actual data range with ~5%
    /// padding. Without this, Apple Charts sometimes pins the lower bound
    /// at 0, which compresses million-toman prices into a single pixel.
    /// Also folds in indicator/overlay extremes so e.g. the upper
    /// Bollinger band doesn't get clipped off the top.
    ///
    /// Overlay extremes (S/R, FVG, OB, drawings, trades, journal) are
    /// cached in ChartDerivedCache — they don't depend on the visible
    /// window, so the expensive multi-loop scan only runs when overlay
    /// data actually changes (AI result, trade edit, drawing add), not
    /// on every pan/zoom frame. (Pan/zoom Performance Fix.)
    private var autoYDomain: ClosedRange<Double> {
        // Fit Y to only the *visible* bar window — otherwise the axis
        // hugs the entire (possibly multi-year) range and the recent
        // price action gets squashed into a few pixels. HA values can
        // exceed raw OHLC at the edges, so fit to displayCandles.
        let bounds = ChartWindow.visibleBounds(
            domain: effectiveXDomain, count: displayCandles.count
        )
        let visibleCandles: ArraySlice<Candle>
        if let b = bounds {
            visibleCandles = displayCandles[b.lo ... b.hi]
        } else {
            visibleCandles = displayCandles[...]
        }
        
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        for c in visibleCandles {
            if c.low < lo { lo = c.low }
            if c.high > hi { hi = c.high }
        }
        if visibleCandles.isEmpty { lo = 0; hi = 1 }

        // Overlay + indicator extremes — cached in ChartDerivedCache.
        // The expensive scan (all indicator points + all overlay zone
        // arrays) only runs when the overlay data actually changes
        // (new AI result, trade edit, drawing add). During pan/zoom
        // this hits the cache synchronously — no loop, no allocations.
        let overlay = derived.overlayExtremes(.init(
            candles: candles,
            indicatorInstances: indicatorInstances,
            indicatorConfig: indicatorConfig,
            indicators: indicators,
            srLevels: srLevels,
            fvgZones: fvgZones,
            supplyDemandZones: supplyDemandZones,
            indicatorFvgZones: indicatorFvgZones,
            orderBlockZones: orderBlockZones,
            steroidOrderBlockZones: steroidOrderBlockZones,
            sonarlabOBZones: sonarlabOBZones,
            ichimokuOutput: ichimokuOutput,
            ichimokuOBZones: ichimokuOBZones,
            rankedOBZones: rankedOBZones,
            volumeFilteredOBZones: volumeFilteredOBZones,
            chochZones: chochZones,
            htfChochZones: htfChochZones,
            sessionRuns: sessionRuns,
            nySetupResults: nySetupResults,
            sp2lResults: sp2lResults,
            pinBarComboResults: pinBarComboResults,
            microMapResults: microMapResults,
            mtrResults: mtrResults,
            volumeProfileSessions: volumeProfileSessions,
            zigzagTrendVP: zigzagTrendVP,
            visibleRangeVP: visibleRangeVP,
            zigzagPivots: zigzagPivots,
            taScenario: taScenario,
            taAltScenario: taAltScenario,
            drawings: drawings,
            trades: trades,
            journalEntries: journalEntries
        ))
        if overlay.lo < lo { lo = overlay.lo }
        if overlay.hi > hi { hi = overlay.hi }
        if let focus = notificationFocus {
            if focus.price < lo { lo = focus.price }
            if focus.price > hi { hi = focus.price }
        }

        guard visibleCandles.isEmpty == false else { return 0...1 }
        let span = hi - lo
        if span <= 0 || visibleCandles.count == 1 {
            // Single bar → expand ±0.5% so it has visible vertical
            // extent rather than collapsing to a 1px line.
            let pad = max(hi * 0.005, 1)
            return (lo - pad)...(hi + pad)
        }
        let pad = span * 0.05
        return (lo - pad)...(hi + pad)
    }

    /// Body width tuned to the *visible* bar count so candles get fatter
    /// as the user zooms in (via pinch, scroll, or the +/- buttons) and
    /// thinner as they zoom out — instead of being permanently pegged to
    /// whatever the full series happens to contain.
    private var candleBodyWidth: CGFloat {
        let span = effectiveXDomain.upperBound - effectiveXDomain.lowerBound
        let visible = max(1, Int(span.rounded()))
        switch visible {
        case 0...3:    return 28
        case 4...10:   return 18
        case 11...30:  return 11
        case 31...80:  return 7
        case 81...200: return 4
        default:       return 2
        }
    }

    // MARK: - Formatting

    /// Compact price label: 19,634,000 → "19.6M"; 4,675 → "4,675";
    /// 0.0234 → "0.0234". K/M/B suffixes once values exceed 4 digits so
    /// the Y-axis labels stay narrow. Used for tick labels where a long
    /// number would crowd the axis; the last-price tag and crosshair
    /// labels use `priceExact` instead so the user can read the actual
    /// figure.
    static func priceShort(_ v: Double) -> String {
        let abs = Swift.abs(v)
        if abs >= 1_000_000_000 { return String(format: "%.2fB", v / 1_000_000_000) }
        if abs >= 1_000_000     { return String(format: "%.2fM", v / 1_000_000) }
        if abs >= 10_000        { return String(format: "%.0fK", v / 1_000) }
        if abs >= 100           { return v.formatted(.number.precision(.fractionLength(0))) }
        if abs >= 1             { return v.formatted(.number.precision(.fractionLength(2))) }
        return String(format: "%.4f", v)
    }

    /// Exact price with thousands separators and up to 4 decimals.
    /// Used wherever the user is trying to read the actual figure off
    /// the chart — the live-price tag, the hover tooltip's OHLC cells,
    /// and the crosshair Y-axis label. Decimal width scales with
    /// magnitude so we don't render meaningless ".00" suffixes on
    /// millions-of-toman quotes, but we always show enough precision
    /// to distinguish two consecutive ticks on small-priced pairs.
    static func priceExact(_ v: Double) -> String {
        let abs = Swift.abs(v)
        let digits: Int
        if abs >= 1_000_000 { digits = 0 }
        else if abs >= 100  { digits = 2 }
        else if abs >= 1    { digits = 4 }
        else                { digits = 5 }
        return v.formatted(.number.precision(.fractionLength(digits)))
    }

    /// Compact human-readable timestamp for the hover tooltip.
    /// Local time, no year — finance UIs almost never need it.
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d · HH:mm"
        return f
    }()
}

// MARK: - Equatable (re-render isolation)

/// `ChartView` is expensive (Apple Charts re-lays out its whole mark tree
/// on every body evaluation), and it's re-evaluated far more often than
/// its *drawn* inputs actually change: every `YahooScheduler`
/// `objectWillChange` (≈1 Hz, plus every unrelated `@Published` field —
/// `isFetching`, `backfilling`, other pairs' prices…) invalidates the
/// owning `DashboardView` / `ChartPaneView`, which cascades a re-eval down
/// into this chart even when nothing here moved. In grid mode that cost is
/// paid N× (one price chart per pane, plus volume + oscillator sub-charts),
/// which is the dominant source of split-screen lag.
///
/// Conforming to `Equatable` and wrapping the call sites in `.equatable()`
/// lets SwiftUI skip re-invoking `body` (and thus the Charts layout pass)
/// whenever none of the render-affecting inputs changed. Closures
/// (`onCommitDrawing`, …) and internal `@State` (hover, in-flight drawing)
/// are deliberately excluded: closures don't affect what's drawn (and are
/// re-captured whenever `==` returns false anyway), and self-`@State`
/// changes bypass this gate entirely — hover crosshair and live drawing
/// previews still redraw normally.
///
/// The candle series is compared via `Candle.seriesEqual` (O(1)) rather
/// than a full element-wise `==`, so this stays cheap even on the hot
/// pan/zoom path (which changes `xDomain` and legitimately forces a
/// redraw) with years of history loaded.
extension ChartView: Equatable {
    static func == (l: ChartView, r: ChartView) -> Bool {
        Candle.seriesEqual(l.candles, r.candles)
            && l.chartType == r.chartType
            && l.accent == r.accent
            && l.xDomain == r.xDomain
            && l.yDomain == r.yDomain
            && l.indicators == r.indicators
            && l.indicatorConfig == r.indicatorConfig
            && l.indicatorInstances == r.indicatorInstances
            && l.htfChochZones == r.htfChochZones
            && l.srLevels == r.srLevels
            && l.fvgZones == r.fvgZones
            && l.supplyDemandZones == r.supplyDemandZones
            && l.taScenario == r.taScenario
            && l.taAltScenario == r.taAltScenario
            && l.drawings == r.drawings
            && l.activeTool == r.activeTool
            && l.selectedDrawingID == r.selectedDrawingID
            && l.trades == r.trades
            && l.journalEntries == r.journalEntries
            && l.livePrice == r.livePrice
            && l.replayActive == r.replayActive
            && l.isPickingReplayAnchor == r.isPickingReplayAnchor
            && l.showHoverTooltip == r.showHoverTooltip
            && Self.newsEqual(l.newsEvents, r.newsEvents)
            && l.newsTimeZone == r.newsTimeZone
    }

    /// Cheap news-list comparison for the Equatable perf gate: same
    /// ids in the same order, and the same `actual` values (so a
    /// freshly-scraped actual re-renders the open popover). Avoids a
    /// full `ForexFactoryEvent` compare on every 1 Hz tick.
    private static func newsEqual(_ a: [ForexFactoryEvent], _ b: [ForexFactoryEvent]) -> Bool {
        guard a.count == b.count else { return false }
        for i in a.indices where a[i].id != b[i].id || a[i].actual != b[i].actual {
            return false
        }
        return true
    }
}
