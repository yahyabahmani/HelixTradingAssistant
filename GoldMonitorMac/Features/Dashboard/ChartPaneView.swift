import SwiftUI
import Combine

/// One independent chart in the multi-chart split-screen grid: its own
/// pair, timeframe, chart type, and indicator/oscillator selection.
/// Deliberately lighter than the primary dashboard chart — no AI
/// overlays, trade markers, replay, or journal pins; those stay on the
/// single-chart view (`DashboardView.chartCard`). Drawings ARE
/// supported (tools live in the right-click menu) since they're a
/// property of the pair, shared with the primary chart via the same
/// `DrawingStore`. Candle loading mirrors `DashboardView.reloadCandles`
/// / `refreshTrailingCandles` but scoped to this pane's own pair +
/// timeframe via the shared `OHLCCandleLoader`.
struct ChartPaneView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var yahoo: YahooScheduler
    /// Shared economic-calendar feed — the grid panes plot the same
    /// news flags as the primary chart (see `NewsChartLayer`).
    @EnvironmentObject private var news: NewsStore

    /// News-flag layer toggle — the same `dashboard.showNews` key the
    /// primary chart uses, so hiding news there hides it in every pane.
    @AppStorage("dashboard.showNews") private var showNews: Bool = true

    let pane: ChartPane
    /// Indicator-parameter config (RSI period, UT Bot key value, etc.)
    /// is a global app setting, not per-pane — every pane reads the
    /// same `OscillatorConfig` the primary chart's settings sheet
    /// edits, so tuning a period there updates every open pane too.
    let indicatorConfig: OscillatorConfig
    /// Same store the primary chart uses, keyed by `pane.pairID` — a
    /// line drawn here shows up on the primary chart for that pair too.
    @ObservedObject var drawingStore: DrawingStore
    /// True while this pane is the one expanded to fill the whole grid
    /// area (every sibling pane, the sidebar, and the pair header hide
    /// — see `ChartGridView`). Toggled by the header's fullscreen
    /// button or the right-click menu's "Fullscreen" item.
    @Binding var isFullscreen: Bool
    /// True when the grid stacks two full rows of panes (`.twoRow` /
    /// `.grid2x2`) — those layouts need roughly double the vertical
    /// budget of a single-row layout, so this trims chart/volume/
    /// oscillator minimums and padding to help both rows actually fit
    /// the window instead of overflowing it.
    var isCompact: Bool = false
    /// False while a *sibling* pane is fullscreen, collapsing this one
    /// to zero size (see `ChartGridView.paneSlot`'s `isHidden`). The
    /// view stays mounted either way — only the tick-driven candle
    /// refresh pauses (see `body`'s `onReceive`). Skipping that refresh
    /// while invisible avoids rebuilding this pane's `ChartView` (candle
    /// marks, Order Block / Steroid OB scans, oscillators — the
    /// expensive part) on every live price tick for a chart nobody can
    /// see; a plain grid with N mounted panes was paying that cost N×
    /// even with only one pane on screen.
    var isVisible: Bool = true
    /// External drawing tool binding from the parent (ChartGridView /
    /// DashboardView). When the pane is fullscreen, this binding is
    /// used instead of the internal @State so the fullscreen toolbar's
    /// drawing picker and the pane's gesture handler share the same
    /// state. (Grid fullscreen drawing fix.)
    @Binding var fullscreenDrawingTool: DrawingTool
    /// Fired on any click inside the pane — the parent (ChartGridView)
    /// uses it to make this pane the sidebar's symbol-change target
    /// (`MultiChartLayoutStore.focusedPaneID`) while `syncSymbol` is off.
    var onFocus: () -> Void = {}
    let onUpdate: (ChartPane) -> Void

    @State private var candles: [Candle] = []
    @State private var xDomain: ClosedRange<Double>?
    @State private var yDomain: ClosedRange<Double>?
    /// Armed drawing tool for this pane's next drag gesture on the
    /// chart. `.none` = normal pan/zoom cursor. Mirrors
    /// `DashboardView.activeDrawingTool`, just scoped per pane instead
    /// of to the whole dashboard.
    @State private var activeDrawingTool: DrawingTool = .none
    @State private var selectedDrawingID: UUID?
    /// Whether the chart-corner indicator legend is expanded. Mirrors
    /// `DashboardView.indicatorLegendExpanded` but scoped per pane.
    @State private var indicatorLegendExpanded: Bool = true
    /// Which indicator/oscillator instance (if any) has its floating
    /// settings panel open. Mirrors DashboardView's editing-ID pattern.
    @State private var editingIndicatorID: UUID?
    @State private var editingOscillatorID: UUID?

    /// The active drawing tool — reads from the external binding when
    /// fullscreen (so the fullscreen toolbar works), falls back to the
    /// internal @State when not fullscreen.
    private var effectiveDrawingTool: DrawingTool {
        isFullscreen ? fullscreenDrawingTool : activeDrawingTool
    }

    /// Set the drawing tool on both internal state and external binding.
    private func setDrawingTool(_ tool: DrawingTool) {
        activeDrawingTool = tool
        fullscreenDrawingTool = tool
    }

    private var pair: TradingPair? { app.pairs.first(where: { $0.id == pane.pairID }) }

    var body: some View {
        content
            // Focus-on-click: simultaneous so it never steals the event
            // from the chart's own pan/draw gestures or header buttons —
            // any interaction anywhere in the pane marks it focused.
            .simultaneousGesture(TapGesture().onEnded { onFocus() })
            .task(id: "\(pane.pairID)|\(pane.timeframe.rawValue)") {
                guard isVisible else { return }
                await load()
            }
            .onReceive(
                // Same 1 Hz throttle as `DashboardView`'s trailing refresh —
                // see the comment there for why 5 Hz raw ticks would pin
                // the main thread across N panes.
                yahoo.$lastUpdateAt
                    .compactMap { $0 }
                    .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            ) { _ in
                guard isVisible else { return }
                Task { await refreshTrailing() }
            }
            .onChange(of: yahoo.dataResetToken) { _ in
                Task { await load() }
            }
            // Catch up on whatever ticks were skipped while a sibling
            // pane was fullscreen. If this pane never got to load (its
            // initial `.task` bailed on the `guard isVisible` because it
            // was hidden behind a fullscreen sibling), `candles` is still
            // empty — do a full `load()` so exiting fullscreen doesn't
            // leave a blank chart. Otherwise a cheap trailing refresh is
            // enough (refreshTrailing's `margin` lookback covers ordinary
            // durations).
            .onChange(of: isVisible) { visible in
                guard visible else { return }
                Task {
                    if candles.isEmpty { await load() }
                    else { await refreshTrailing() }
                }
            }
    }

    private var content: some View {
        // Fullscreen drops the Card chrome (rounded corners, padding,
        // surface fill) the same way the primary chart's own
        // `isChartFull` does — the chart's edges meet the window edges
        // so it truly fills the space with nothing else visible. A
        // single, unconditional `Card` call (chrome + padding vary by
        // value) instead of `if isFullscreen { chartStack } else {
        // Card { chartStack } }` — that `if/else` would tear down and
        // rebuild `chartStack`'s `ChartView` (and its indicator cache)
        // on every fullscreen toggle. See `Card.chromeless`.
        Card(padding: isFullscreen ? 0 : (isCompact ? Theme.Spacing.md : Theme.Spacing.xl), chromeless: isFullscreen) {
            chartStack.padding(isFullscreen ? 0 : Theme.Spacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chartStack: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            header
            if let pair {
                let chartContent = Group {
                    #if os(iOS)
                    ChartViewiPad(
                        candles: candles,
                        chartType: pane.chartType,
                        accent: pair.color,
                        xDomain: $xDomain,
                        yDomain: $yDomain,
                        indicators: Set(visibleIndicatorInstances.map(\.kind)),
                        indicatorConfig: indicatorConfig,
                        drawings: drawingStore.drawings(for: pane.pairID),
                        activeTool: effectiveDrawingTool,
                        contractSpec: .forPair(id: pane.pairID),
                        onCommitDrawing: { drawing in
                            drawingStore.add(drawing, for: pane.pairID)
                            setDrawingTool(.none)
                            selectedDrawingID = drawing.id
                        },
                        onMoveDrawing: { drawing in
                            drawingStore.update(drawing, for: pane.pairID)
                        },
                        selectedDrawingID: selectedDrawingID,
                        onSelectDrawing: { id in
                            selectedDrawingID = id
                        },
                        livePrice: yahoo.latestPrices[pane.pairID],
                        newsEvents: showNews ? news.chartEvents : [],
                        newsTimeZone: news.effectiveTimeZone
                    )
                    #else
                    ChartView(
                        candles: candles,
                        chartType: pane.chartType,
                        accent: pair.color,
                        xDomain: $xDomain,
                        yDomain: $yDomain,
                        indicators: Set(visibleIndicatorInstances.map(\.kind)),
                        indicatorConfig: indicatorConfig,
                        indicatorInstances: visibleIndicatorInstances,
                        drawings: drawingStore.drawings(for: pane.pairID),
                        activeTool: effectiveDrawingTool,
                        contractSpec: .forPair(id: pane.pairID),
                        onCommitDrawing: { drawing in
                            drawingStore.add(drawing, for: pane.pairID)
                            setDrawingTool(.none)
                            selectedDrawingID = drawing.id
                        },
                        onMoveDrawing: { drawing in
                            drawingStore.update(drawing, for: pane.pairID)
                        },
                        selectedDrawingID: selectedDrawingID,
                        onSelectDrawing: { id in
                            selectedDrawingID = id
                        },
                        livePrice: yahoo.latestPrices[pane.pairID],
                        showHoverTooltip: isFullscreen,
                        newsEvents: showNews ? news.chartEvents : [],
                        newsTimeZone: news.effectiveTimeZone
                    )
                    // Skip re-laying-out the price chart when a parent
                    // re-render (a live tick, a sibling pane, an unrelated
                    // yahoo @Published change) didn't actually move any of
                    // this chart's drawn inputs — the core grid-lag fix.
                    // See `ChartView`'s Equatable note.
                    .equatable()
                    // Mouse-wheel / two-finger trackpad scroll zooms this
                    // pane, anchored on the cursor's X position — same
                    // modifier the primary single chart uses (the pinch
                    // gesture lives inside ChartView; wheel events need
                    // this AppKit monitor). Attached before `.clipped()`
                    // below so the modifier's GeometryReader sees the
                    // chart's actual frame in global coords.
                    .scrollZoom(xDomain: $xDomain, totalCandles: candles.count)
                    #endif
                }
                chartContent
                    .frame(minHeight: isCompact ? 130 : 200, maxHeight: .infinity)
                    .clipped()
                // TradingView-style indicator legend — top-left of the
                // chart. Lists every indicator/oscillator on this pane
                // with a hide/show (eye) toggle and a settings (gear)
                // button. Mirrors `DashboardView.indicatorLegendOverlay`
                // but scoped to this pane. Applied after `.clipped()` so
                // it floats freely over the plot area.
                .overlay(alignment: .topLeading) {
                    indicatorLegendOverlay
                        .padding(.top, 6)
                        .padding(.leading, 8)
                }
                // Floating per-instance settings panels, opened by the
                // legend's gear buttons.
                .overlay(alignment: .topLeading) {
                    if let id = editingIndicatorID,
                       let idx = pane.indicatorInstances.firstIndex(where: { $0.id == id }) {
                        IndicatorSettingsPanel(
                            instance: Binding(
                                get: { pane.indicatorInstances[idx] },
                                set: { updateIndicatorInstance($0) }
                            ),
                            onUpdate: { updateIndicatorInstance($0) },
                            onClose: { editingIndicatorID = nil }
                        )
                        .padding(.leading, Theme.Spacing.md)
                        .padding(.top, Theme.Spacing.md)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let id = editingOscillatorID,
                       let idx = pane.oscillatorInstances.firstIndex(where: { $0.id == id }) {
                        OscillatorSettingsPanel(
                            instance: Binding(
                                get: { pane.oscillatorInstances[idx] },
                                set: { updateOscillatorInstance($0) }
                            ),
                            onUpdate: { updateOscillatorInstance($0) },
                            onClose: { editingOscillatorID = nil }
                        )
                        .padding(.leading, Theme.Spacing.md)
                        .padding(.top, Theme.Spacing.md)
                    }
                }
                #if !os(iOS)
                .drawingDeleteKey(selectedDrawingID: $selectedDrawingID, drawingStore: drawingStore, pairID: pane.pairID)
                #endif
                .contextMenu { optionsMenu }
                // Scroll-to-latest puck — same as the single chart's.
                .overlay(alignment: .bottomLeading) {
                    if !isViewingLatest {
                        Button { scrollToLatest() } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(Theme.accentGradient))
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                        }
                        .buttonStyle(.plain)
                        .help("Scroll to latest")
                        .padding(.leading, Theme.Spacing.sm)
                        .padding(.bottom, Theme.Spacing.sm)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: isViewingLatest)

                if pane.showVolume {
                    VolumeBarsView(candles: candles, accent: pair.color, xDomain: xDomain)
                        .equatable()
                        .frame(height: isCompact ? 28 : 36)
                }
                ForEach(visibleOscillatorInstances) { inst in
                    OscillatorPanel(instance: inst, candles: candles, xDomain: xDomain)
                        .equatable()
                        .frame(height: isCompact ? 56 : 80)
                }
            } else {
                Text("Pair unavailable")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ── Header ────────────────────────────────────────────────────
    //
    // Deliberately minimal — read-only pair/price/timeframe info plus
    // the one control that needs a discoverable, always-visible button
    // (fullscreen). Every other option (pair, timeframe, chart type,
    // indicators, oscillators, volume) now lives in `optionsMenu`,
    // reached by right-clicking the chart.

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(pair?.color ?? Theme.Color.textMuted).frame(width: 8, height: 8)
            Text(pair?.symbol ?? "—")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
            if let pair {
                Text(displayedPrice(pair))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.Color.textMuted)
            }

            indicatorsMenu

            Spacer()

            if effectiveDrawingTool != .none {
                armedToolBadge
            }

            // Timeframe + chart type selectors — same controls as the
            // single chart's toolbar, bound to this pane's state.
            TimeframeSelector(selected: timeframeBinding)
            ChartTypeToggle(selected: chartTypeBinding, isDisabled: false)

            fullscreenButton
        }
    }

    /// Binding for TimeframeSelector — reads from pane, writes via onUpdate.
    private var timeframeBinding: Binding<Timeframe> {
        Binding(
            get: { pane.timeframe },
            set: { newTF in
                var updated = pane
                updated.timeframe = newTF
                onUpdate(updated)
            }
        )
    }

    /// Binding for ChartTypeToggle — reads from pane, writes via onUpdate.
    private var chartTypeBinding: Binding<ChartType> {
        Binding(
            get: { pane.chartType },
            set: { newCT in
                var updated = pane
                updated.chartType = newCT
                onUpdate(updated)
            }
        )
    }

    /// Shown only while a drawing tool is armed — there's no persistent
    /// toolbar row anymore (options moved to right-click), so this is
    /// the only visual cue that the next drag on the chart draws a
    /// shape instead of panning. Tapping it disarms back to the cursor.
    private var armedToolBadge: some View {
        Button {
            setDrawingTool(.none)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: effectiveDrawingTool.systemImage)
                Text(effectiveDrawingTool.label)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.accentGradient))
        }
        .buttonStyle(.plain)
        .help("Drawing \(activeDrawingTool.label) — click to cancel")
    }

    private var fullscreenButton: some View {
        Button {
            isFullscreen.toggle()
        } label: {
            Image(systemName: isFullscreen
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(isFullscreen ? "Exit fullscreen" : "Fullscreen")
    }

    private var indicatorsMenu: some View {
        ChartPaneIndicatorsMenu(pane: pane, onUpdate: onUpdate)
            .equatable()
    }

    // ── Indicator legend (top-left overlay) ───────────────────────────
    //
    // TradingView-style floating legend listing every indicator /
    // oscillator on this pane, each with a hide/show (eye) toggle and a
    // settings (gear) button. Mirrors `DashboardView`'s
    // `indicatorLegendOverlay` / `legendInstanceRow` / `legendOscillatorRow`
    // but scoped to this pane's `ChartPane` (edits flow back via `onUpdate`).

    /// Only the non-hidden indicators are drawn on the chart — hiding one
    /// in the legend keeps it in the pane's config but removes its marks.
    private var visibleIndicatorInstances: [IndicatorInstance] {
        pane.indicatorInstances.filter { !$0.hidden }
    }

    /// Same for oscillator sub-panels.
    private var visibleOscillatorInstances: [OscillatorInstance] {
        pane.oscillatorInstances.filter { !$0.hidden }
    }

    @ViewBuilder
    private var indicatorLegendOverlay: some View {
        if !pane.indicatorInstances.isEmpty || !pane.oscillatorInstances.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        indicatorLegendExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        if indicatorLegendExpanded {
                            Text("Indicators")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.Color.textMuted)
                        }
                        Image(systemName: indicatorLegendExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.Color.textMuted)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Theme.Color.surface.opacity(0.85))
                    )
                }
                .buttonStyle(.plain)

                if indicatorLegendExpanded {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(pane.indicatorInstances) { inst in
                            legendInstanceRow(for: inst)
                        }
                        ForEach(pane.oscillatorInstances) { inst in
                            legendOscillatorRow(for: inst)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    /// One legend row for an indicator: color swatch, label, eye toggle,
    /// gear button.
    private func legendInstanceRow(for inst: IndicatorInstance) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(inst.hidden ? inst.kind.color.opacity(0.35) : inst.kind.color)
                .frame(width: 12, height: 3)

            Text(inst.label)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(inst.hidden ? inst.kind.color.opacity(0.35) : inst.kind.color)
                .lineLimit(1)

            Button {
                toggleIndicatorHidden(id: inst.id)
            } label: {
                Image(systemName: inst.hidden ? "eye.slash" : "eye")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(inst.hidden ? Theme.Color.textMuted.opacity(0.4) : Theme.Color.textSecondary)
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.Color.surface.opacity(0.7)))
            }
            .buttonStyle(.plain)
            .help(inst.hidden ? "Show \(inst.label)" : "Hide \(inst.label)")

            Button {
                editingOscillatorID = nil
                editingIndicatorID = inst.id
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.Color.textMuted)
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.Color.surface.opacity(0.7)))
            }
            .buttonStyle(.plain)
            .help("Settings for \(inst.label)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.Color.surface.opacity(0.75)))
    }

    /// One legend row for an oscillator: gear button + label + eye toggle.
    private func legendOscillatorRow(for inst: OscillatorInstance) -> some View {
        HStack(spacing: 5) {
            Button {
                editingIndicatorID = nil
                editingOscillatorID = inst.id
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.Color.textMuted)
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.Color.surface.opacity(0.7)))
            }
            .buttonStyle(.plain)
            .help("Settings for \(inst.label)")

            Text(inst.label)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(inst.hidden ? Color.white.opacity(0.3) : Color.white.opacity(0.6))
                .lineLimit(1)

            Button {
                toggleOscillatorHidden(id: inst.id)
            } label: {
                Image(systemName: inst.hidden ? "eye.slash" : "eye")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(inst.hidden ? Theme.Color.textMuted.opacity(0.4) : Theme.Color.textSecondary)
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.Color.surface.opacity(0.7)))
            }
            .buttonStyle(.plain)
            .help(inst.hidden ? "Show \(inst.label)" : "Hide \(inst.label)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.Color.surface.opacity(0.75)))
    }

    // ── Legend mutations (write back through onUpdate) ────────────────

    private func toggleIndicatorHidden(id: UUID) {
        guard let idx = pane.indicatorInstances.firstIndex(where: { $0.id == id }) else { return }
        var updated = pane
        updated.indicatorInstances[idx].hidden.toggle()
        onUpdate(updated)
    }

    private func toggleOscillatorHidden(id: UUID) {
        guard let idx = pane.oscillatorInstances.firstIndex(where: { $0.id == id }) else { return }
        var updated = pane
        updated.oscillatorInstances[idx].hidden.toggle()
        onUpdate(updated)
    }

    private func updateIndicatorInstance(_ inst: IndicatorInstance) {
        guard let idx = pane.indicatorInstances.firstIndex(where: { $0.id == inst.id }) else { return }
        var updated = pane
        updated.indicatorInstances[idx] = inst
        onUpdate(updated)
    }

    private func updateOscillatorInstance(_ inst: OscillatorInstance) {
        guard let idx = pane.oscillatorInstances.firstIndex(where: { $0.id == inst.id }) else { return }
        var updated = pane
        updated.oscillatorInstances[idx] = inst
        onUpdate(updated)
    }

    /// Right-click menu with every chart option that used to live in
    /// the always-visible header row: pair, timeframe, chart type,
    /// indicators/oscillators, volume, and fullscreen. Parameter
    /// tuning (RSI period, UT Bot key value, etc.) stays global, edited
    /// from the primary chart's settings sheet.
    @ViewBuilder
    private var optionsMenu: some View {
        Menu("Pair") {
            ForEach(app.pairs) { p in
                Button {
                    var updated = pane
                    updated.pairID = p.id
                    onUpdate(updated)
                } label: {
                    Label(p.name, systemImage: p.id == pane.pairID ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        Menu("Timeframe") {
            ForEach(Timeframe.allCases) { tf in
                Button {
                    var updated = pane
                    updated.timeframe = tf
                    onUpdate(updated)
                } label: {
                    Label(tf.label, systemImage: tf == pane.timeframe ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        Menu("Chart type") {
            ForEach(ChartType.allCases) { ct in
                Button {
                    var updated = pane
                    updated.chartType = ct
                    onUpdate(updated)
                } label: {
                    Label(ct.label, systemImage: ct == pane.chartType ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        Menu("Indicators") {
            ForEach(IndicatorKind.allCases) { kind in
                let isOn = pane.indicatorInstances.contains(where: { $0.kind == kind })
                Button {
                    var updated = pane
                    if isOn {
                        updated.indicatorInstances.removeAll { $0.kind == kind }
                    } else {
                        updated.indicatorInstances.append(IndicatorInstance(kind: kind))
                    }
                    onUpdate(updated)
                } label: {
                    Label(kind.label, systemImage: isOn ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        Menu("Oscillators") {
            ForEach(OscillatorKind.allCases) { kind in
                let isOn = pane.oscillatorInstances.contains(where: { $0.kind == kind })
                Button {
                    var updated = pane
                    if isOn {
                        updated.oscillatorInstances.removeAll { $0.kind == kind }
                    } else {
                        updated.oscillatorInstances.append(OscillatorInstance(kind: kind))
                    }
                    onUpdate(updated)
                } label: {
                    Label(kind.label, systemImage: isOn ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        Button {
            var updated = pane
            updated.showVolume.toggle()
            onUpdate(updated)
        } label: {
            Label("Volume", systemImage: pane.showVolume ? "checkmark.circle.fill" : "circle")
        }
        Divider()
        Menu("Drawing Tool") {
            ForEach(DrawingTool.allCases) { tool in
                Button {
                    setDrawingTool(tool)
                } label: {
                    Label(tool.label, systemImage: effectiveDrawingTool == tool
                          ? "checkmark.circle.fill" : tool.systemImage)
                }
            }
        }
        if selectedDrawingID != nil {
            Button(role: .destructive) {
                if let id = selectedDrawingID {
                    drawingStore.remove(id: id, for: pane.pairID)
                    selectedDrawingID = nil
                }
            } label: {
                Label("Delete Selected Drawing", systemImage: "trash")
            }
        }
        if !drawingStore.drawings(for: pane.pairID).isEmpty {
            Button(role: .destructive) {
                drawingStore.clear(for: pane.pairID)
                selectedDrawingID = nil
            } label: {
                Label("Clear Drawings", systemImage: "trash.slash")
            }
        }
        Divider()
        Button {
            resetChart()
        } label: {
            Label("Reset Zoom", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
        }
        Divider()
        Button {
            isFullscreen.toggle()
        } label: {
            Label(isFullscreen ? "Exit Fullscreen" : "Fullscreen",
                  systemImage: isFullscreen
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
        }
    }

    private func displayedPrice(_ pair: TradingPair) -> String {
        if let p = yahoo.latestPrices[pair.id] {
            return p.formatted(.number.precision(.fractionLength(2)))
        }
        return "—"
    }

    // ── Candle loading ────────────────────────────────────────────
    //
    // Mirrors `DashboardView.reloadCandles` / `refreshTrailingCandles`
    // exactly, just scoped to this pane's own pair + timeframe instead
    // of the dashboard's single `@AppStorage` selection.

    private func load() async {
        guard let db = app.database else { candles = []; return }
        let pairID = pane.pairID
        let tf = pane.timeframe
        let respectsWeekend = app.pairs.first(where: { $0.id == pairID })?.category != .crypto
        let result = await OHLCCandleLoader.loadAsync(
            repo: db.ohlcRepo, pairID: pairID, tf: tf,
            since: .distantPast, until: Date(), dropClosedDays: respectsWeekend
        )
        self.candles = result
        self.xDomain = nil
        self.yDomain = nil
        self.setDrawingTool(.none)
        self.selectedDrawingID = nil
    }

    /// Cheap trailing-window refresh on the same live-tick cadence the
    /// primary chart uses, so panes stay current without re-reading
    /// years of history every tick.
    private func refreshTrailing() async {
        guard let db = app.database, !candles.isEmpty else { return }
        let pairID = pane.pairID
        let tf = pane.timeframe
        let respectsWeekend = app.pairs.first(where: { $0.id == pairID })?.category != .crypto
        let until = Date()
        let margin = Double(max(tf.seconds * 3, 6 * 3600))
        let since = until.addingTimeInterval(-margin)
        let recent = await OHLCCandleLoader.loadAsync(
            repo: db.ohlcRepo, pairID: pairID, tf: tf,
            since: since, until: until, dropClosedDays: respectsWeekend
        )
        guard let cutoff = recent.first?.bucketStart else { return }
        var merged = candles
        while let last = merged.last, last.bucketStart >= cutoff { merged.removeLast() }
        merged.append(contentsOf: recent)
        // Only publish when the tail actually changed. A tick that
        // re-reads the same trailing bar (common between real price
        // updates) otherwise reassigns an identical array every second,
        // forcing this pane — and its Equatable charts — to redraw for
        // nothing. `!=` is O(n) but runs at most ~1 Hz off the hot path.
        guard merged != candles else { return }
        candles = merged
    }

    // ── Scroll to latest ──────────────────────────────────────────

    /// True when the visible window's right edge is at or past the
    /// newest candle. Drives the scroll-to-latest puck's visibility.
    private var isViewingLatest: Bool {
        guard candles.count > 0, let d = xDomain else { return true }
        return d.upperBound >= Double(candles.count - 1)
    }

    /// Slide the window so its right edge lands on the newest candle,
    /// preserving the current zoom width. Matches DashboardView's
    /// `scrollToLatest()`.
    private func scrollToLatest() {
        guard candles.count > 0 else { return }
        let domain = xDomain ?? ChartWindow.defaultDomain(count: candles.count)
        let span = domain.upperBound - domain.lowerBound
        let upper = Double(candles.count - 1) + 0.5
        let lower = max(-0.5, upper - span)
        withAnimation(.easeInOut(duration: 0.25)) {
            xDomain = lower ... upper
        }
    }

    /// Reset the pane to the default recent-bars window with the price
    /// scale framed to the *candles* (not indicators/overlays). Mirrors
    /// `DashboardView.resetChart()` so every Reset behaves the same.
    private func resetChart() {
        guard candles.count > 0 else { xDomain = nil; yDomain = nil; return }
        let domain = ChartWindow.defaultDomain(count: candles.count)
        yDomain = ChartWindow.candleYDomain(candles: candles, domain: domain)
        withAnimation(.easeInOut(duration: 0.25)) {
            xDomain = domain
        }
    }
}

struct ChartPaneIndicatorsMenu: View, Equatable {
    let pane: ChartPane
    let onUpdate: (ChartPane) -> Void
    
    var body: some View {
        Menu {
            ForEach(IndicatorKind.allCases) { kind in
                let isOn = pane.indicatorInstances.contains(where: { $0.kind == kind })
                Button {
                    var updated = pane
                    if isOn {
                        updated.indicatorInstances.removeAll { $0.kind == kind }
                    } else {
                        updated.indicatorInstances.append(IndicatorInstance(kind: kind))
                    }
                    onUpdate(updated)
                } label: {
                    Label(kind.label, systemImage: isOn ? "checkmark.circle.fill" : "circle")
                }
            }
            Divider()
            ForEach(OscillatorKind.allCases) { kind in
                let isOn = pane.oscillatorInstances.contains(where: { $0.kind == kind })
                Button {
                    var updated = pane
                    if isOn {
                        updated.oscillatorInstances.removeAll { $0.kind == kind }
                    } else {
                        updated.oscillatorInstances.append(OscillatorInstance(kind: kind))
                    }
                    onUpdate(updated)
                } label: {
                    Label(kind.label, systemImage: isOn ? "checkmark.circle.fill" : "circle")
                }
            }
            Divider()
            Button {
                var updated = pane
                updated.showVolume.toggle()
                onUpdate(updated)
            } label: {
                Label("Volume", systemImage: pane.showVolume ? "checkmark.circle.fill" : "circle")
            }
        } label: {
            Text("Indicators")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
    
    static func == (lhs: ChartPaneIndicatorsMenu, rhs: ChartPaneIndicatorsMenu) -> Bool {
        lhs.pane == rhs.pane
    }
}
