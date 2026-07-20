import SwiftUI
import Combine

struct DashboardViewiPad: View {
    @EnvironmentObject private var app: AppState
    // yahoo is deliberately NOT an @EnvironmentObject here —
    // subscribing directly re-evaluates the entire body on every
    // @Published write, dismissing open menus. We read it via
    // @Environment in .onReceive closures instead.
    @EnvironmentObject private var notificationInbox: NotificationInbox
    @EnvironmentObject private var analysisStore: AnalysisStore
    @EnvironmentObject private var tradeStore: TradeStore
    @EnvironmentObject private var journal: JournalStore
    @EnvironmentObject private var autoTraderConfig: AutoTraderConfigStore
    @EnvironmentObject private var autoTrader: AutoTraderEngine
    @EnvironmentObject private var paperBalance: PaperBalance

    @Environment(\.metrics) private var metrics

    @AppStorage("dashboard.timeframe")  private var timeframe: Timeframe = .h1
    @AppStorage("dashboard.chartType")  private var userChartType: ChartType = .candle
    @AppStorage("dashboard.showVolume") private var showVolume: Bool = true
    @AppStorage("dashboard.indicators")  private var indicatorsRaw: String = ""
    @AppStorage("dashboard.oscillators") private var oscillatorsRaw: String = ""
    @AppStorage("dashboard.hiddenIndicators")  private var hiddenIndicatorsRaw: String = ""
    @AppStorage("dashboard.hiddenOscillators") private var hiddenOscillatorsRaw: String = ""

    @State private var candleCount: Int = 0
    @State private var reloadToken: Int = 0
    @State private var isLoading: Bool = false
    @State private var livePrices: [String: Double] = [:]
    @State private var isFetching: Bool = false
    @State private var dataResetToken: Int = 0
    // NOTE: the chart's zoom window (xDomain/yDomain) deliberately does NOT
    // live here. It's local @State inside `ChartPlotiPad` so a pan/zoom —
    // which rewrites the domain on every gesture frame — re-renders only the
    // chart subtree, not this whole 900-line dashboard body (pair header,
    // multi-chart grid, hidden analysis overlay, stats, toolbar). Hoisting it
    // up here is what made the iPad chart lag vs the Mac app. Reset-on-switch
    // is handled by the `.id(pair|timeframe)` on that view instead.
    @State private var oscillatorConfig: OscillatorConfig = .load()
    @State private var srLevels: PromptBuilder.SRLevels = .init(support: [], resistance: [])
    @State private var fvgZones: [PromptBuilder.FVGZone] = []
    @State private var supplyDemandZones: [PromptBuilder.SupplyDemandZone] = []
    @State private var taScenario: PromptBuilder.TAScenario? = nil
    @State private var taAltScenario: PromptBuilder.TAScenario? = nil
    @State private var srVisible: Bool = true
    @State private var fvgVisible: Bool = true
    @State private var supplyDemandVisible: Bool = true
    @State private var scenarioVisible: Bool = true
    @State private var altScenarioVisible: Bool = true
    @State private var showAnalysis: Bool = false
    @State private var showDebugLogSheet: Bool = false

    // Phase 2: Drawing tools
    @StateObject private var drawingStore = DrawingStore()
    @State private var activeDrawingTool: DrawingTool = .none
    @State private var selectedDrawingID: UUID? = nil

    // Multi-chart grid (2-column layout)
    @StateObject private var multiChart = MultiChartLayoutStore()

    // Phase 2: Sheets
    @State private var showLayersPopover: Bool = false
    @State private var showIndicatorSettings: Bool = false
    @State private var settingsFocusSection: String? = nil
    @State private var showAlertSheet: Bool = false
    @State private var settingsDragOffset: CGSize = .zero

    // Phase 2: Alert store
    @StateObject private var alertStore = AlertStore()

    // Phase 3: Replay controller
    @StateObject private var replay = ReplayController()

    // Phase 2: Activate trade
    @State private var pendingActivation: PendingActivation?

    private struct PendingActivation: Identifiable, Equatable {
        let scenario: PromptBuilder.TAScenario
        let sourceHistoryEntryID: UUID?
        var id: String { scenario.id }
    }

    // Parsed sets — computed directly from @AppStorage strings so they
    // are always in sync. The strings are short (≤10 comma-separated
    // rawValues) so parsing is trivially cheap.
    private var enabledIndicators: Set<IndicatorKind> {
        Self.parseIndicators(indicatorsRaw)
    }
    private var enabledOscillators: Set<OscillatorKind> {
        Self.parseOscillators(oscillatorsRaw)
    }
    private var hiddenIndicators: Set<IndicatorKind> {
        Self.parseIndicators(hiddenIndicatorsRaw)
    }
    private var hiddenOscillators: Set<OscillatorKind> {
        Self.parseOscillators(hiddenOscillatorsRaw)
    }
    private var visibleIndicators: Set<IndicatorKind> {
        enabledIndicators.subtracting(hiddenIndicators)
    }
    private var visibleOscillators: Set<OscillatorKind> {
        enabledOscillators.subtracting(hiddenOscillators)
    }

    private func setIndicator(_ kind: IndicatorKind, enabled: Bool) {
        var s = enabledIndicators
        if enabled { s.insert(kind) } else { s.remove(kind) }
        indicatorsRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }
    private func setOscillator(_ kind: OscillatorKind, enabled: Bool) {
        var s = enabledOscillators
        if enabled { s.insert(kind) } else { s.remove(kind) }
        oscillatorsRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }
    private func setIndicatorHidden(_ kind: IndicatorKind, hidden: Bool) {
        var s = hiddenIndicators
        if hidden { s.insert(kind) } else { s.remove(kind) }
        hiddenIndicatorsRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }
    private func setOscillatorHidden(_ kind: OscillatorKind, hidden: Bool) {
        var s = hiddenOscillators
        if hidden { s.insert(kind) } else { s.remove(kind) }
        hiddenOscillatorsRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }

    /// Drives the compact-width indicator-settings sheet. Presented only when
    /// the draggable overlay is suppressed (iPhone). Saving on dismiss mirrors
    /// the overlay's `onDismiss`.
    private var compactSettingsSheet: Binding<Bool> {
        Binding(
            get: { showIndicatorSettings && metrics.isCompact },
            set: { newValue in
                if !newValue {
                    oscillatorConfig.save()
                    showIndicatorSettings = false
                    settingsFocusSection = nil
                }
            }
        )
    }

    private static func parseIndicators(_ raw: String) -> Set<IndicatorKind> {
        Set(raw.split(separator: ",").compactMap { IndicatorKind(rawValue: String($0)) })
    }
    private static func parseOscillators(_ raw: String) -> Set<OscillatorKind> {
        Set(raw.split(separator: ",").compactMap { OscillatorKind(rawValue: String($0)) })
    }

    var body: some View {
        let pair = app.pairs.first(where: { $0.id == app.selectedPairID })
        let showsGrid = multiChart.layout != .single

        YahooDataBridge(
            livePrices: $livePrices,
            isFetching: $isFetching,
            dataResetToken: $dataResetToken
        ) { yahoo in
        ZStack {
            VStack(spacing: 8) {
                if let pair = pair {
                    if !app.isChartFullscreen {
                        pairHeader(pair)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    let isFull = app.isChartFullscreen
                    // Single chart and grid always mounted — inactive one
                    // collapses to zero frame + zero opacity. Eliminates
                    // teardown/rebuild cycle on layout switch.
                    ZStack {
                        chartCard(pair, yahoo: yahoo)
                            .frame(maxWidth: showsGrid ? 0 : .infinity,
                                   maxHeight: showsGrid ? 0 : .infinity)
                            .opacity(showsGrid ? 0 : 1)
                            .allowsHitTesting(!showsGrid)
                        ChartGridView(
                            layoutStore: multiChart,
                            indicatorConfig: oscillatorConfig,
                            drawingStore: drawingStore,
                            activeDrawingTool: $activeDrawingTool
                        ) {
                            // Empty fullscreen toolbar — grid panes have
                            // their own compact headers.
                            EmptyView()
                        }
                        .frame(maxWidth: showsGrid ? .infinity : 0,
                               maxHeight: showsGrid ? .infinity : 0)
                        .opacity(showsGrid ? 1 : 0)
                        .allowsHitTesting(showsGrid)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                    if !isFull && !showsGrid {
                        statsRow(pair)
                    }
                } else {
                    emptyState
                }
            }
            .padding(app.isChartFullscreen ? 0 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Phase 2: Analysis overlay. Built ONLY while shown — previously
            // it was always mounted (collapsed to frame 0), so its body — which
            // renders the AI report markdown — re-evaluated on every dashboard
            // re-render (each 1 Hz candle tick, each fullscreen toggle) even
            // while hidden. Gating it behind `showAnalysis` keeps it off the
            // hot path; the one-time build cost lands only when the user opens it.
            if let pair = pair, showAnalysis {
                AnalysisPageiPad(
                    pair: pair,
                    timeframe: timeframe,
                    candles: ChartPlotiPad.loadCandles(pairID: pair.id, tf: timeframe, app: app),
                    livePrice: livePrices[pair.id],
                    loadCandles: { tf in
                        ChartPlotiPad.loadCandles(pairID: pair.id, tf: tf, app: app)
                    },
                    onApplySRLevels:      { srLevels = $0 },
                    onApplyFVGZones:      { fvgZones = $0 },
                    onApplySupplyDemand:  { supplyDemandZones = $0 },
                    onApplyTAScenario:    { taScenario = $0 },
                    onApplyTAAltScenario: { taAltScenario = $0 },
                    onActivateTradeFromScenario: { scenario, entryID in
                        pendingActivation = PendingActivation(
                            scenario: scenario,
                            sourceHistoryEntryID: entryID
                        )
                    },
                    onClose: { showAnalysis = false }
                )
                .environmentObject(analysisStore)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.Color.canvas)
        .task(id: app.selectedPairID) {
            await MainActor.run {
                // Domain reset happens via ChartPlotiPad's `.id` changing.
                srLevels = .init(support: [], resistance: [])
                fvgZones = []
                supplyDemandZones = []
                taScenario = nil
                taAltScenario = nil
                selectedDrawingID = nil
                alertStore.timeframeLabel = timeframe.rawValue
            }
        }
        .onChange(of: timeframe) { _ in
            alertStore.timeframeLabel = timeframe.rawValue
        }
        .onChange(of: userChartType) { _ in }
        .onChange(of: showVolume) { _ in }
        // Grid: ensure pane count when layout changes
        .onChange(of: multiChart.layout) { newLayout in
            if newLayout != .single, let pairID = app.selectedPairID {
                multiChart.ensurePaneCount(defaultPairID: pairID)
            }
        }
        // Grid: sidebar symbol selection in grid mode
        .onChange(of: app.selectedPairID) { newPairID in
            guard let newPairID, multiChart.layout != .single else { return }
            var updated = multiChart.panes
            if multiChart.syncSymbol {
                for i in updated.indices { updated[i].pairID = newPairID }
            } else {
                let targetID = multiChart.focusedPaneID ?? updated.first?.id
                guard let idx = updated.firstIndex(where: { $0.id == targetID }) else { return }
                updated[idx].pairID = newPairID
            }
            multiChart.panes = updated
        }
        // Regular width (iPad): a non-modal, draggable panel lets the user
        // tune params while watching the chart update live. On compact
        // (iPhone) that floating panel is wider than the screen, so we
        // present a proper detented sheet instead.
        .overlay {
            if showIndicatorSettings && !metrics.isCompact {
                DraggableSettingsOverlay(
                    config: $oscillatorConfig,
                    focusSection: settingsFocusSection,
                    dragOffset: $settingsDragOffset,
                    onDismiss: {
                        oscillatorConfig.save()
                        showIndicatorSettings = false
                        settingsFocusSection = nil
                    }
                )
            }
        }
        .sheet(isPresented: compactSettingsSheet) {
            NavigationStack {
                ScrollView {
                    IndicatorSettingsBody(config: $oscillatorConfig)
                }
                .background(Theme.Color.surface)
                .navigationTitle("Indicator Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { compactSettingsSheet.wrappedValue = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAlertSheet) {
            if let cur = pair {
                AlertSheet(
                    pairID: cur.id,
                    pairName: cur.name,
                    livePrice: livePrices[cur.id],
                    onCreate: { alert in alertStore.add(alert) }
                )
                .environmentObject(alertStore)
            }
        }
        .sheet(isPresented: $showDebugLogSheet) {
            DebugLogSheetiPad()
        }
        .sheet(item: $pendingActivation) { mode in
            ActivateTradeSheet(
                scenario: mode.scenario,
                pairID: pair?.id ?? "",
                livePrice: pair.flatMap { livePrices[$0.id] },
                sourceHistoryEntryID: mode.sourceHistoryEntryID
            ) { trade in
                tradeStore.add(trade, for: pair?.id ?? "")
                pendingActivation = nil
            }
            .environmentObject(tradeStore)
        }
        } // YahooDataBridge content
    }

    // MARK: - Pair header (Phase 2: + fetch timer)

    private func pairHeader(_ pair: TradingPair) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            // Pair selector dropdown
            Menu {
                ForEach(app.pairs) { p in
                    Button {
                        app.selectedPairID = p.id
                    } label: {
                        Label(p.name, systemImage: p.id == app.selectedPairID ? "checkmark.circle.fill" : "circle")
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(pair.color)
                        .frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pair.name)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Theme.Color.textPrimary)
                        Text(pair.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Color.textMuted)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Color.textMuted)
                }
            }

            // Layout picker (single / 2 columns)
            Menu {
                Button {
                    multiChart.layout = .single
                } label: {
                    Label("Single chart", systemImage: multiChart.layout == .single
                          ? "checkmark.circle.fill" : "rectangle")
                }
                Button {
                    if let pairID = app.selectedPairID {
                        multiChart.setLayout(.twoColumn, defaultPairID: pairID)
                    }
                } label: {
                    Label("2 columns", systemImage: multiChart.layout == .twoColumn
                          ? "checkmark.circle.fill" : "rectangle.split.2x1")
                }
                if multiChart.layout != .single {
                    Divider()
                    Toggle("Sync symbol across panes", isOn: $multiChart.syncSymbol)
                }
            } label: {
                Image(systemName: multiChart.layout == .single ? "rectangle" : "rectangle.split.2x1")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.Color.surface))
            }

            Spacer()

            // Phase 2: Fetch timer
            FetchTimerBridge(intervalSeconds: 60)

            let price = livePrices[pair.id] ?? pair.price
            if price > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatPrice(price))
                        .font(.system(size: 22, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.Color.textPrimary)
                    let pct = pair.changePercent
                    Text(String(format: "%+.2f%%", pct))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(pct >= 0 ? Theme.Color.success : Theme.Color.danger)
                }
            }
            Button {
                reloadToken += 1
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.Color.surface))
            }
        }
    }

    // MARK: - Chart card (Phase 2: + drawing toolbar + layers + alerts)

    private func chartCard(_ pair: TradingPair, yahoo: YahooScheduler) -> some View {
        VStack(spacing: 0) {
            // Chart header
            IPadChartHeaderToolbar(
                timeframe: $timeframe,
                userChartType: $userChartType,
                replay: replay,
                indicatorsRaw: $indicatorsRaw,
                oscillatorsRaw: $oscillatorsRaw,
                hiddenIndicatorsRaw: $hiddenIndicatorsRaw,
                hiddenOscillatorsRaw: $hiddenOscillatorsRaw,
                showIndicatorSettings: $showIndicatorSettings,
                srVisible: $srVisible,
                fvgVisible: $fvgVisible,
                supplyDemandVisible: $supplyDemandVisible,
                scenarioVisible: $scenarioVisible,
                altScenarioVisible: $altScenarioVisible,
                hasSRLevels: !srLevels.isEmpty,
                hasFVGZones: !fvgZones.isEmpty,
                hasSupplyDemandZones: !supplyDemandZones.isEmpty,
                hasScenario: taScenario != nil,
                hasAltScenario: taAltScenario != nil,
                selectedPairID: app.selectedPairID,
                drawings: app.selectedPairID.map { drawingStore.drawings(for: $0) } ?? [],
                selectedDrawingID: $selectedDrawingID,
                drawingStore: drawingStore,
                activeDrawingTool: $activeDrawingTool,
                showAnalysis: $showAnalysis,
                showDebugLogSheet: $showDebugLogSheet,
                showAlertSheet: $showAlertSheet,
                isChartFullscreen: $app.isChartFullscreen
            )
            .equatable()
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, 8)

            Divider().background(Theme.Color.border)

            // Chart body + oscillators + volume, isolated in ChartPlotiPad.
            // That view owns xDomain/yDomain, so pan/zoom re-renders only its
            // subtree — never this dashboard body, the multi-chart grid, or
            // the analysis overlay. The `.id` gives each pair/timeframe a
            // fresh (auto-fit) zoom window, replacing the old explicit resets.
            ChartPlotiPad(
                pairID: pair.id,
                timeframe: timeframe,
                chartType: userChartType,
                accent: pair.color,
                indicators: visibleIndicators,
                oscillators: visibleOscillators,
                indicatorConfig: oscillatorConfig,
                srLevels: srVisible ? srLevels : .init(support: [], resistance: []),
                fvgZones: fvgVisible ? fvgZones : [],
                supplyDemandZones: supplyDemandVisible ? supplyDemandZones : [],
                taScenario: scenarioVisible ? taScenario : nil,
                taAltScenario: altScenarioVisible ? taAltScenario : nil,
                drawings: app.selectedPairID.map { drawingStore.drawings(for: $0) } ?? [],
                activeTool: activeDrawingTool,
                contractSpec: .forPair(id: app.selectedPairID ?? ""),
                onCommitDrawing: { drawing in
                    guard let pairID = app.selectedPairID else { return }
                    drawingStore.add(drawing, for: pairID)
                    activeDrawingTool = .none
                },
                onMoveDrawing: { drawing in
                    guard let pairID = app.selectedPairID else { return }
                    drawingStore.update(drawing, for: pairID)
                },
                selectedDrawingID: selectedDrawingID,
                onSelectDrawing: { id in selectedDrawingID = id },
                trades: app.selectedPairID.flatMap { tradeStore.openVisibleTrades(for: $0) } ?? [],
                journalEntries: app.selectedPairID == app.journalChartEntry?.pairID
                    ? (app.journalChartEntry.map { [$0] } ?? []) : [],
                livePrice: livePrices[pair.id],
                replayActive: replay.isActive,
                showVolume: showVolume,
                reloadToken: reloadToken,
                dataResetToken: dataResetToken,
                candleCount: $candleCount,
                yahoo: yahoo
            )
            .id("\(pair.id)|\(timeframe.rawValue)")
        }
        .background(
            RoundedRectangle(cornerRadius: app.isChartFullscreen ? 0 : Theme.Radius.lg, style: .continuous)
                .fill(app.isChartFullscreen ? Color.clear : Theme.Color.surfaceHi)
                .overlay(
                    app.isChartFullscreen ? nil :
                    RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                        .strokeBorder(Theme.Color.border, lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: app.isChartFullscreen ? 0 : Theme.Radius.lg, style: .continuous))
        .frame(maxHeight: .infinity)
    }





    // MARK: - Stats row

    private func statsRow(_ pair: TradingPair) -> some View {
        HStack(spacing: Theme.Spacing.lg) {
            statItem("24H High", value: pair.high24h > 0 ? formatPrice(pair.high24h) : "—")
            statItem("24H Low", value: pair.low24h > 0 ? formatPrice(pair.low24h) : "—")
            statItem("24H Change", value: String(format: "%+.2f%%", pair.changePercent),
                     color: pair.changePercent >= 0 ? Theme.Color.success : Theme.Color.danger)
        }
    }

    private func statItem(_ label: String, value: String, color: Color? = nil) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Color.textMuted)
            Text(value)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(color ?? Theme.Color.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.Color.surface)
        )
    }

    // MARK: - Helpers

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Spacer()
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 48))
                .foregroundStyle(Theme.Color.textMuted)
            Text("Select a pair")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formatPrice(_ v: Double) -> String {
        if v >= 10_000 { return String(format: "%.0f", v) }
        if v >= 100 { return String(format: "%.2f", v) }
        if v >= 1 { return String(format: "%.4f", v) }
        return String(format: "%.5f", v)
    }
}

// MARK: - Isolated chart plot

/// The price chart plus its oscillator panels and volume bars, all sharing
/// one `xDomain`/`yDomain` zoom window.
///
/// Why this is its own view: the domain lives here as local `@State`, not on
/// `DashboardViewiPad`. A pan/zoom rewrites the domain on *every* gesture
/// frame; keeping it local means SwiftUI re-evaluates only this subtree per
/// frame, instead of the entire dashboard body (pair header, multi-chart
/// grid, hidden analysis overlay, stats row, toolbar menus). Re-rendering
/// that whole tree ~60–120×/sec during a drag is what made the iPad chart
/// lag compared to the Mac app, whose domain state is likewise scoped to an
/// isolated chart pane (`ChartPaneView`).
///
/// Reset-on-switch is driven from the parent by changing this view's `.id`
/// (pair | timeframe): a new id re-creates the view with nil domains, so
/// each pair/timeframe opens on its default auto-fit window.
private struct ChartPlotiPad: View {
    let pairID: String
    let timeframe: Timeframe
    let chartType: ChartType
    let accent: Color
    let indicators: Set<IndicatorKind>
    let oscillators: Set<OscillatorKind>
    let indicatorConfig: OscillatorConfig
    let srLevels: PromptBuilder.SRLevels
    let fvgZones: [PromptBuilder.FVGZone]
    let supplyDemandZones: [PromptBuilder.SupplyDemandZone]
    let taScenario: PromptBuilder.TAScenario?
    let taAltScenario: PromptBuilder.TAScenario?
    let drawings: [ChartDrawing]
    let activeTool: DrawingTool
    let contractSpec: ContractSpec
    let onCommitDrawing: (ChartDrawing) -> Void
    let onMoveDrawing: (ChartDrawing) -> Void
    let selectedDrawingID: UUID?
    let onSelectDrawing: (UUID?) -> Void
    let trades: [Trade]
    let journalEntries: [JournalEntry]
    let livePrice: Double?
    let replayActive: Bool
    let showVolume: Bool
    let reloadToken: Int
    let dataResetToken: Int
    @Binding var candleCount: Int

    @EnvironmentObject private var app: AppState
    /// Passed as a plain `let` (not `@EnvironmentObject`) so that
    /// `@Published` writes on YahooScheduler (latestPrices, isFetching,
    /// etc.) do NOT trigger body re-evaluation of this view. The parent
    /// DashboardViewiPad already subscribes to the specific fields it
    /// needs via YahooDataBridge — this view only reads the scheduler
    /// in async tasks (warmHistory / refreshTrailingCandles).
    let yahoo: YahooScheduler
    /// Shared economic-calendar feed — powers the on-chart news flags.
    @EnvironmentObject private var news: NewsStore
    /// News-flag layer toggle (shared key with the Mac chart).
    @AppStorage("dashboard.showNews") private var showNews: Bool = true
    @State private var candles: [Candle] = []
    @State private var htfChochZones: [ChangeOfCharacter.DatedZone] = []
    @State private var xDomain: ClosedRange<Double>? = nil
    @State private var yDomain: ClosedRange<Double>? = nil

    var body: some View {
        VStack(spacing: 0) {
            ChartViewiPad(
                candles: candles,
                chartType: chartType,
                accent: accent,
                xDomain: $xDomain,
                yDomain: $yDomain,
                indicators: indicators,
                indicatorConfig: indicatorConfig,
                htfChochZones: htfChochZones,
                srLevels: srLevels,
                fvgZones: fvgZones,
                supplyDemandZones: supplyDemandZones,
                taScenario: taScenario,
                taAltScenario: taAltScenario,
                drawings: drawings,
                activeTool: activeTool,
                contractSpec: contractSpec,
                onCommitDrawing: onCommitDrawing,
                onMoveDrawing: onMoveDrawing,
                selectedDrawingID: selectedDrawingID,
                onSelectDrawing: onSelectDrawing,
                trades: trades,
                journalEntries: journalEntries,
                livePrice: livePrice,
                replayActive: replayActive,
                newsEvents: showNews ? news.chartEvents : [],
                newsTimeZone: news.effectiveTimeZone
            )
            .equatable()
            .frame(maxHeight: .infinity)
            .clipped()
            // Tap-and-hold to rescale — mirrors the double-tap reset, but
            // discoverable. Frames the recent bars with the price scale fit
            // to the *candles* (not indicators/overlays).
            .contextMenu {
                Button {
                    resetChart()
                } label: {
                    Label("Reset Zoom", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                }
            }

            // Oscillator panels — follow the same xDomain so they scroll in
            // lockstep with the price chart.
            if !oscillators.isEmpty {
                Divider().background(Theme.Color.border)
                // Sorted for stable ForEach ordering — Set iteration
                // order is unstable, causing diff churn.
                ForEach(Array(oscillators).sorted(by: { $0.rawValue < $1.rawValue })) { kind in
                    OscillatorPanel(
                        instance: Self.makeOscillatorInstance(kind: kind, config: indicatorConfig),
                        candles: candles,
                        xDomain: xDomain
                    )
                    .equatable()
                    .padding(.horizontal, Theme.Spacing.lg)
                }
            }

            // Volume bars
            if showVolume {
                let volView = VolumeBarsView(candles: candles, accent: accent, xDomain: xDomain)
                if volView.hasVolume {
                    Divider().background(Theme.Color.border)
                    volView
                        .equatable()
                        .frame(height: 50)
                        .padding(.horizontal, Theme.Spacing.lg)
                }
            }
        }
        .task(id: "\(pairID)|\(timeframe.rawValue)|\(reloadToken)") {
            await reloadCandles()
            warmHistory()
        }
        .onReceive(
            yahoo.$lastUpdateAt
                .compactMap { $0 }
                .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
        ) { _ in
            let pair = app.pairs.first(where: { $0.id == pairID })
            if pair?.usesLiveStream == true {
                Task { await refreshTrailingCandles() }
            }
        }
        .onChange(of: dataResetToken) { _ in
            Task { await reloadCandles() }
        }
        // Recompute HTF CHoCH when the user toggles the CHoCH layer or edits
        // any HTF-relevant setting (the candle `.task` id doesn't cover
        // config-only changes).
        .onChange(of: htfChochInputKey) { _ in
            Task { await reloadHTFChoch() }
        }
    }

    /// Compact signature of every input `reloadHTFChoch()` reads, so a
    /// single `onChange` recomputes the overlay on any relevant edit.
    private var htfChochInputKey: String {
        [
            String(indicators.contains(.changeOfCharacter)),
            String(indicatorConfig.chochHTFEnabled),
            indicatorConfig.chochHTFTimeframe,
            String(indicatorConfig.chochHTFCount),
            String(indicatorConfig.chochSwingLength),
            String(indicatorConfig.chochMinSwingPct),
            String(indicatorConfig.chochRequireFVG),
            String(indicatorConfig.chochShowMitigated)
        ].joined(separator: "|")
    }

    /// Reset to the default recent-bars window with the price scale
    /// framed to the *candles* (not indicators/overlays), matching the
    /// Mac chart's Reset and the chart's own double-tap.
    private func resetChart() {
        guard candles.count > 0 else { xDomain = nil; yDomain = nil; return }
        let domain = ChartWindow.defaultDomain(count: candles.count)
        yDomain = ChartWindow.candleYDomain(candles: candles, domain: domain)
        xDomain = domain
    }

    // MARK: - Candle loading

    @MainActor
    private func reloadCandles() async {
        let loaded = Self.loadCandles(pairID: pairID, tf: timeframe, app: app)
        // Skip state mutation when data is unchanged — avoids
        // "Modifying state during view update" and unnecessary redraws.
        guard loaded != candles else {
            candleCount = loaded.count
            return
        }
        candles = loaded
        candleCount = candles.count
        await reloadHTFChoch()
    }

    /// Load the higher-timeframe CHoCH zones for the multi-timeframe
    /// overlay. Reads the configured HTF candles for the current pair,
    /// computes the last N zones, and re-anchors them to dates so
    /// `ChartViewiPad` can project them onto the currently-displayed
    /// (lower) timeframe. A no-op (clears the overlay) unless the CHoCH
    /// indicator is visible, the HTF option is on, and the chosen HTF is
    /// strictly coarser than the timeframe in view.
    @MainActor
    private func reloadHTFChoch() async {
        let cfg = indicatorConfig
        guard indicators.contains(.changeOfCharacter),
              cfg.chochHTFEnabled,
              let db = app.database,
              let htf = Timeframe(rawValue: cfg.chochHTFTimeframe),
              htf.seconds > timeframe.seconds
        else {
            if !htfChochZones.isEmpty { htfChochZones = [] }
            return
        }

        let pair = app.pairs.first(where: { $0.id == pairID })
        let respectsWeekend = pair?.category != .crypto
        let htfCandles = await OHLCCandleLoader.loadAsync(
            repo: db.ohlcRepo, pairID: pairID, tf: htf,
            since: Date.distantPast, until: Date(),
            dropClosedDays: respectsWeekend
        )
        htfChochZones = ChangeOfCharacter.datedZones(
            htfCandles,
            swingLength: cfg.chochSwingLength,
            minSwingPct: cfg.chochMinSwingPct,
            requireFVG: cfg.chochRequireFVG,
            showMitigated: cfg.chochShowMitigated,
            maxZones: max(1, cfg.chochHTFCount)
        )
    }

    private func warmHistory() {
        let currentSrc = OHLCCandleLoader.sourceTimeframeTag(for: timeframe)
        Task {
            await yahoo.ensureDeepHistory(pairID: pairID, sourceTF: currentSrc)
            await reloadCandles()
            await yahoo.backfillAll(pairID: pairID)
            await reloadCandles()
        }
    }

    @MainActor
    private func refreshTrailingCandles() async {
        guard let db = app.database else { return }
        let pair = app.pairs.first(where: { $0.id == pairID })
        let respectsWeekend = pair?.category != .crypto
        let until = Date()
        let margin = Double(max(timeframe.seconds * 3, 6 * 3600))
        let since = until.addingTimeInterval(-margin)
        let recent = OHLCCandleLoader.load(
            repo: db.ohlcRepo, pairID: pairID, tf: timeframe,
            since: since, until: until, dropClosedDays: respectsWeekend
        )
        guard let cutoff = recent.first?.bucketStart else { return }
        var merged = candles
        while let last = merged.last, last.bucketStart >= cutoff { merged.removeLast() }
        merged.append(contentsOf: recent)
        // Skip state mutation when the trailing splice is unchanged —
        // avoids "Modifying state during view update" and unnecessary
        // chart redraws on ticks that didn't produce a new bar.
        guard merged != candles else { return }
        candles = merged
        candleCount = candles.count
    }

    static func loadCandles(pairID: String, tf: Timeframe, app: AppState) -> [Candle] {
        guard let db = app.database else { return [] }
        let pair = app.pairs.first(where: { $0.id == pairID })
        let respectsWeekend = pair?.category != .crypto
        return OHLCCandleLoader.load(
            repo: db.ohlcRepo, pairID: pairID, tf: tf,
            since: Date.distantPast, until: Date(), dropClosedDays: respectsWeekend
        )
    }

    /// Build an OscillatorInstance whose params reflect the current
    /// OscillatorConfig so the panel actually renders with the user's
    /// chosen periods instead of hardcoded defaults. Uses a stable UUID
    /// derived from the kind so OscillatorPanel's Equatable check works
    /// across renders (avoids diff churn from fresh UUIDs each frame).
    private static func makeOscillatorInstance(kind: OscillatorKind, config: OscillatorConfig) -> OscillatorInstance {
        let raw = kind.rawValue
        let padded = raw.padding(toLength: 12, withPad: "0", startingAt: 0)
        let stableID = UUID(uuidString: "00000000-0000-0000-0000-\(padded)") ?? UUID()
        switch kind {
        case .rsi:
            return OscillatorInstance(id: stableID, kind: .rsi, params: ["period": .double(Double(config.rsiPeriod))])
        case .macd:
            return OscillatorInstance(id: stableID, kind: .macd, params: [
                "fast":   .double(Double(config.macdFast)),
                "slow":   .double(Double(config.macdSlow)),
                "signal": .double(Double(config.macdSignal)),
            ])
        case .stochastic:
            return OscillatorInstance(id: stableID, kind: .stochastic, params: [
                "k": .double(Double(config.stochK)),
                "d": .double(Double(config.stochD)),
            ])
        }
    }
}

// MARK: - Draggable settings overlay

/// A non-modal, draggable settings panel that applies changes instantly
/// as the user adjusts values. Replaces the old `.sheet` approach so the
/// user can see the chart update in real time while tuning parameters.
private struct DraggableSettingsOverlay: View {
    @Binding var config: OscillatorConfig
    var focusSection: String?
    @Binding var dragOffset: CGSize
    let onDismiss: () -> Void

    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 0) {
            // Draggable header
            HStack {
                Text("Indicator Settings")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.Color.surfaceHi)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        dragOffset = CGSize(
                            width: value.translation.width,
                            height: value.translation.height
                        )
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )

            Divider().background(Theme.Color.border)

            // Settings content — changes apply instantly via $config binding
            ScrollViewReader { proxy in
                ScrollView {
                    IndicatorSettingsBody(config: $config)
                }
                .frame(maxHeight: 450)
                .onAppear {
                    if let section = focusSection {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation { proxy.scrollTo(section, anchor: .top) }
                        }
                    }
                }
            }

            Divider().background(Theme.Color.border)

            // Bottom bar
            HStack {
                Button("Reset to defaults") {
                    config = OscillatorConfig()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Color.textSecondary)
                Spacer()
                Text("Changes apply instantly")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.Color.surfaceHi)
        }
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.Color.surface)
                .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.Color.border, lineWidth: 1)
        )
        .offset(x: dragOffset.width, y: dragOffset.height)
        .animation(isDragging ? .none : .spring(response: 0.3), value: dragOffset)
    }
}

// MARK: - Settings body (shared between sheet and overlay)

/// The scrollable settings content — extracted so both the old `.sheet`
/// and the new draggable overlay can share it.
private struct IndicatorSettingsBody: View {
    @Binding var config: OscillatorConfig

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            settingsSection(title: "RSI") {
                settingsStepper(label: "Period", value: $config.rsiPeriod, range: 2...100)
            }
            Divider().background(Theme.Color.border)
            settingsSection(title: "MACD") {
                settingsStepper(label: "Fast EMA", value: $config.macdFast, range: 2...50)
                settingsStepper(label: "Slow EMA", value: $config.macdSlow, range: 3...100)
                settingsStepper(label: "Signal EMA", value: $config.macdSignal, range: 2...50)
            }
            Divider().background(Theme.Color.border)
            settingsSection(title: "Stochastic") {
                settingsStepper(label: "%K period", value: $config.stochK, range: 2...50)
                settingsStepper(label: "%D period", value: $config.stochD, range: 1...20)
            }
            Divider().background(Theme.Color.border)
            settingsSection(title: "UT Bot Alerts") {
                settingsDoubleStepper(label: "Key value", value: $config.utKeyValue, range: 0.1...10.0, step: 0.1)
                settingsStepper(label: "ATR period", value: $config.utATRPeriod, range: 1...100)
                Toggle("Show trailing-stop line", isOn: $config.utShowTrailingStop)
                    .toggleStyle(.switch)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.textSecondary)
                Toggle("Use Heikin Ashi", isOn: $config.utUseHeikinAshi)
                    .toggleStyle(.switch)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Divider().background(Theme.Color.border)
            settingsSection(title: "Order Blocks") {
                settingsStepper(label: "Run length", value: $config.obPeriods, range: 1...20)
                settingsDoubleStepper(label: "Min % move", value: $config.obThreshold, range: 0.0...10.0, step: 0.1)
                Toggle("Use wicks", isOn: $config.obUseWicks)
                    .toggleStyle(.switch)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.textSecondary)
                Toggle("Show exhausted", isOn: $config.obShowExhausted)
                    .toggleStyle(.switch)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Divider().background(Theme.Color.border)
            settingsSection(title: "Fair Value Gap") {
                settingsDoubleStepper(label: "Min gap %", value: $config.fvgThreshold, range: 0.0...5.0, step: 0.1)
                Toggle("Show mitigated", isOn: $config.fvgShowMitigated)
                    .toggleStyle(.switch)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Divider().background(Theme.Color.border)
            settingsSection(title: "Trading Sessions") {
                Toggle("Tokyo", isOn: $config.sessShowTokyo)
                    .toggleStyle(.switch)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.textSecondary)
                Toggle("London", isOn: $config.sessShowLondon)
                    .toggleStyle(.switch)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.textSecondary)
                Toggle("New York", isOn: $config.sessShowNewYork)
                    .toggleStyle(.switch)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Divider().background(Theme.Color.border)
            settingsSection(title: "Volume Profile") {
                Picker("Mode", selection: $config.vpMode) {
                    Text("Sessions (trading day)").tag("session")
                    Text("ZigZag trend").tag("zigzag")
                    Text("Visible range + levels").tag("visible")
                }
                .pickerStyle(.menu)
                if config.vpMode == "visible" {
                    settingsStepper(label: "Levels", value: $config.vpLevelCount, range: 1...10)
                }
                settingsStepper(label: "Buckets", value: $config.vpBucketCount, range: 10...100)
                settingsDoubleStepper(label: "Value Area %", value: $config.vpValueAreaPct, range: 50...95, step: 5.0)
            }
            Divider().background(Theme.Color.border)
            settingsSection(title: "Volume-Filtered OB") {
                robToggle("Show Historic Zones", $config.vfobShowHistoric)
                robToggle("Volumetric Info", $config.vfobVolumetricInfo)
                Picker("Zone Invalidation", selection: $config.vfobInvalidation) {
                    Text("Wick").tag("Wick")
                    Text("Close").tag("Close")
                }
                .pickerStyle(.menu)
                .font(.system(size: 12))
                settingsStepper(label: "Swing Length", value: $config.vfobSwingLength, range: 3...50)
                Picker("Zone Count", selection: $config.vfobZoneCount) {
                    Text("High").tag("High")
                    Text("Medium").tag("Medium")
                    Text("Low").tag("Low")
                    Text("One").tag("One")
                }
                .pickerStyle(.menu)
                .font(.system(size: 12))
            }
        }
        .padding(14)
    }

    /// Compact switch row used by the Ranked-OB section.
    private func robToggle(_ label: String, _ value: Binding<Bool>) -> some View {
        Toggle(label, isOn: value)
            .toggleStyle(.switch)
            .font(.system(size: 12))
            .foregroundStyle(Theme.Color.textSecondary)
    }

    @ViewBuilder
    private func settingsSection<Content: View>(title: String, @ViewBuilder body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.Color.textMuted)
                .id(title)
            body()
        }
    }

    private func settingsStepper(label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
            Text("\(value.wrappedValue)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.Color.textPrimary)
                .frame(minWidth: 30, alignment: .trailing)
            Stepper("", value: value, in: range)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    private func settingsDoubleStepper(label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
            Text(String(format: "%.1f", value.wrappedValue))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.Color.textPrimary)
                .frame(minWidth: 36, alignment: .trailing)
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
        }
    }
}

struct IPadIndicatorsMenu: View, Equatable {
    @Binding var indicatorsRaw: String
    @Binding var oscillatorsRaw: String
    @Binding var hiddenIndicatorsRaw: String
    @Binding var hiddenOscillatorsRaw: String
    @Binding var showIndicatorSettings: Bool
    
    private var enabledIndicators: Set<IndicatorKind> {
        Set(indicatorsRaw.split(separator: ",").compactMap { IndicatorKind(rawValue: String($0)) })
    }
    private var enabledOscillators: Set<OscillatorKind> {
        Set(oscillatorsRaw.split(separator: ",").compactMap { OscillatorKind(rawValue: String($0)) })
    }
    private var hiddenIndicators: Set<IndicatorKind> {
        Set(hiddenIndicatorsRaw.split(separator: ",").compactMap { IndicatorKind(rawValue: String($0)) })
    }
    
    private func setIndicator(_ kind: IndicatorKind, enabled: Bool) {
        var s = enabledIndicators
        if enabled { s.insert(kind) } else { s.remove(kind) }
        indicatorsRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }
    private func setOscillator(_ kind: OscillatorKind, enabled: Bool) {
        var s = enabledOscillators
        if enabled { s.insert(kind) } else { s.remove(kind) }
        oscillatorsRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }
    private func setIndicatorHidden(_ kind: IndicatorKind, hidden: Bool) {
        var s = hiddenIndicators
        if hidden { s.insert(kind) } else { s.remove(kind) }
        hiddenIndicatorsRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }
    
    @State private var showPopover: Bool = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover) {
            IPadIndicatorsPopover(
                indicatorsRaw: $indicatorsRaw,
                oscillatorsRaw: $oscillatorsRaw,
                hiddenIndicatorsRaw: $hiddenIndicatorsRaw,
                hiddenOscillatorsRaw: $hiddenOscillatorsRaw,
                showIndicatorSettings: $showIndicatorSettings
            )
        }
    }
    
    static func == (lhs: IPadIndicatorsMenu, rhs: IPadIndicatorsMenu) -> Bool {
        lhs.indicatorsRaw == rhs.indicatorsRaw &&
        lhs.oscillatorsRaw == rhs.oscillatorsRaw &&
        lhs.hiddenIndicatorsRaw == rhs.hiddenIndicatorsRaw &&
        lhs.hiddenOscillatorsRaw == rhs.hiddenOscillatorsRaw &&
        lhs.showIndicatorSettings == rhs.showIndicatorSettings
    }
}

struct IPadLayersMenu: View, Equatable {
    @Binding var indicatorsRaw: String
    @Binding var hiddenIndicatorsRaw: String
    @Binding var oscillatorsRaw: String
    @Binding var hiddenOscillatorsRaw: String
    
    // Visibilities
    @Binding var srVisible: Bool
    @Binding var fvgVisible: Bool
    @Binding var supplyDemandVisible: Bool
    @Binding var scenarioVisible: Bool
    @Binding var altScenarioVisible: Bool
    
    let hasSRLevels: Bool
    let hasFVGZones: Bool
    let hasSupplyDemandZones: Bool
    let hasScenario: Bool
    let hasAltScenario: Bool
    
    // Drawings
    let drawings: [ChartDrawing]
    @Binding var selectedDrawingID: UUID?
    let drawingStore: DrawingStore
    let selectedPairID: String?
    
    private var enabledIndicators: Set<IndicatorKind> {
        Set(indicatorsRaw.split(separator: ",").compactMap { IndicatorKind(rawValue: String($0)) })
    }
    private var hiddenIndicators: Set<IndicatorKind> {
        Set(hiddenIndicatorsRaw.split(separator: ",").compactMap { IndicatorKind(rawValue: String($0)) })
    }
    private var enabledOscillators: Set<OscillatorKind> {
        Set(oscillatorsRaw.split(separator: ",").compactMap { OscillatorKind(rawValue: String($0)) })
    }
    private var hiddenOscillators: Set<OscillatorKind> {
        Set(hiddenOscillatorsRaw.split(separator: ",").compactMap { OscillatorKind(rawValue: String($0)) })
    }
    
    private func setIndicatorHidden(_ kind: IndicatorKind, hidden: Bool) {
        var s = hiddenIndicators
        if hidden { s.insert(kind) } else { s.remove(kind) }
        hiddenIndicatorsRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }
    private func setOscillatorHidden(_ kind: OscillatorKind, hidden: Bool) {
        var s = hiddenOscillators
        if hidden { s.insert(kind) } else { s.remove(kind) }
        hiddenOscillatorsRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }
    
    @State private var showPopover: Bool = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover) {
            IPadLayersPopover(
                indicatorsRaw: $indicatorsRaw,
                hiddenIndicatorsRaw: $hiddenIndicatorsRaw,
                oscillatorsRaw: $oscillatorsRaw,
                hiddenOscillatorsRaw: $hiddenOscillatorsRaw,
                srVisible: $srVisible,
                fvgVisible: $fvgVisible,
                supplyDemandVisible: $supplyDemandVisible,
                scenarioVisible: $scenarioVisible,
                altScenarioVisible: $altScenarioVisible,
                hasSRLevels: hasSRLevels,
                hasFVGZones: hasFVGZones,
                hasSupplyDemandZones: hasSupplyDemandZones,
                hasScenario: hasScenario,
                hasAltScenario: hasAltScenario,
                drawings: drawings,
                selectedDrawingID: $selectedDrawingID,
                drawingStore: drawingStore,
                selectedPairID: selectedPairID
            )
        }
    }
    
    static func == (lhs: IPadLayersMenu, rhs: IPadLayersMenu) -> Bool {
        lhs.indicatorsRaw == rhs.indicatorsRaw &&
        lhs.hiddenIndicatorsRaw == rhs.hiddenIndicatorsRaw &&
        lhs.oscillatorsRaw == rhs.oscillatorsRaw &&
        lhs.hiddenOscillatorsRaw == rhs.hiddenOscillatorsRaw &&
        lhs.srVisible == rhs.srVisible &&
        lhs.fvgVisible == rhs.fvgVisible &&
        lhs.supplyDemandVisible == rhs.supplyDemandVisible &&
        lhs.scenarioVisible == rhs.scenarioVisible &&
        lhs.altScenarioVisible == rhs.altScenarioVisible &&
        lhs.hasSRLevels == rhs.hasSRLevels &&
        lhs.hasFVGZones == rhs.hasFVGZones &&
        lhs.hasSupplyDemandZones == rhs.hasSupplyDemandZones &&
        lhs.hasScenario == rhs.hasScenario &&
        lhs.hasAltScenario == rhs.hasAltScenario &&
        lhs.drawings == rhs.drawings &&
        lhs.selectedDrawingID == rhs.selectedDrawingID &&
        lhs.selectedPairID == rhs.selectedPairID
    }
}

struct IPadChartHeaderToolbar: View, Equatable {
    @Binding var timeframe: Timeframe
    @Binding var userChartType: ChartType
    @ObservedObject var replay: ReplayController
    
    // Bindings for enums / storage strings
    @Binding var indicatorsRaw: String
    @Binding var oscillatorsRaw: String
    @Binding var hiddenIndicatorsRaw: String
    @Binding var hiddenOscillatorsRaw: String
    @Binding var showIndicatorSettings: Bool
    
    @Binding var srVisible: Bool
    @Binding var fvgVisible: Bool
    @Binding var supplyDemandVisible: Bool
    @Binding var scenarioVisible: Bool
    @Binding var altScenarioVisible: Bool
    
    let hasSRLevels: Bool
    let hasFVGZones: Bool
    let hasSupplyDemandZones: Bool
    let hasScenario: Bool
    let hasAltScenario: Bool
    
    let selectedPairID: String?
    let drawings: [ChartDrawing]
    @Binding var selectedDrawingID: UUID?
    @ObservedObject var drawingStore: DrawingStore
    
    @Binding var activeDrawingTool: DrawingTool
    
    @Binding var showAnalysis: Bool
    @Binding var showDebugLogSheet: Bool
    @Binding var showAlertSheet: Bool
    @Binding var isChartFullscreen: Bool

    @Environment(\.metrics) private var metrics

    var body: some View {
        // On compact width (iPhone portrait) the ~14 controls can't share one
        // row without overflowing, so we split into a primary row (timeframe /
        // type / Analyze) plus a horizontally scrollable secondary row of
        // touch-sized icons. On regular width everything stays on one row.
        if metrics.isCompact {
            VStack(spacing: 8) {
                HStack(spacing: Theme.Spacing.sm) {
                    TimeframeSelector(selected: $timeframe)
                    ChartTypeToggle(selected: $userChartType, isDisabled: false)
                    Spacer(minLength: 8)
                    analyzeButton
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        drawingTools
                        deleteSelectedButton
                        verticalDivider
                        replayControl
                        verticalDivider
                        indicatorsMenu
                        layersMenu
                        alertsButton
                        fullscreenButton
                        overflowMenu
                    }
                    .padding(.horizontal, 2)
                }
            }
        } else {
            HStack(spacing: Theme.Spacing.sm) {
                TimeframeSelector(selected: $timeframe)
                ChartTypeToggle(selected: $userChartType, isDisabled: false)
                Spacer()
                drawingTools
                deleteSelectedButton
                verticalDivider
                replayControl
                verticalDivider
                indicatorsMenu
                layersMenu
                alertsButton
                analyzeButton
                fullscreenButton
                overflowMenu
            }
        }
    }

    // MARK: - Control groups

    private var verticalDivider: some View {
        Divider().frame(height: 20).background(Theme.Color.border)
    }

    private var drawingTools: some View {
        HStack(spacing: 4) {
            ForEach(DrawingTool.allCases.filter { $0 != .none }) { tool in
                IconButton(
                    systemName: tool.systemImage,
                    isActive: activeDrawingTool == tool
                ) {
                    activeDrawingTool = activeDrawingTool == tool ? .none : tool
                }
            }
        }
    }

    @ViewBuilder
    private var deleteSelectedButton: some View {
        if selectedDrawingID != nil {
            IconButton(systemName: "trash", tint: Theme.Color.danger) {
                if let id = selectedDrawingID, let pairID = selectedPairID {
                    drawingStore.remove(id: id, for: pairID)
                    selectedDrawingID = nil
                }
            }
        }
    }

    @ViewBuilder
    private var replayControl: some View {
        if replay.isActive {
            HStack(spacing: 4) {
                Button { replay.exit() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.Color.danger)
                }
                Text("REPLAY")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Theme.Color.warn)
            }
        } else {
            IconButton(systemName: "clock.arrow.circlepath") { replay.arm() }
        }
    }

    private var indicatorsMenu: some View {
        IPadIndicatorsMenu(
            indicatorsRaw: $indicatorsRaw,
            oscillatorsRaw: $oscillatorsRaw,
            hiddenIndicatorsRaw: $hiddenIndicatorsRaw,
            hiddenOscillatorsRaw: $hiddenOscillatorsRaw,
            showIndicatorSettings: $showIndicatorSettings
        )
        .equatable()
    }

    private var layersMenu: some View {
        IPadLayersMenu(
            indicatorsRaw: $indicatorsRaw,
            hiddenIndicatorsRaw: $hiddenIndicatorsRaw,
            oscillatorsRaw: $oscillatorsRaw,
            hiddenOscillatorsRaw: $hiddenOscillatorsRaw,
            srVisible: $srVisible,
            fvgVisible: $fvgVisible,
            supplyDemandVisible: $supplyDemandVisible,
            scenarioVisible: $scenarioVisible,
            altScenarioVisible: $altScenarioVisible,
            hasSRLevels: hasSRLevels,
            hasFVGZones: hasFVGZones,
            hasSupplyDemandZones: hasSupplyDemandZones,
            hasScenario: hasScenario,
            hasAltScenario: hasAltScenario,
            drawings: drawings,
            selectedDrawingID: $selectedDrawingID,
            drawingStore: drawingStore,
            selectedPairID: selectedPairID
        )
        .equatable()
    }

    private var alertsButton: some View {
        IconButton(systemName: "bell") { showAlertSheet = true }
    }

    private var analyzeButton: some View {
        PillButton(title: "Analyze", systemName: "sparkles") {
            showAnalysis = true
        }
    }

    private var fullscreenButton: some View {
        IconButton(
            systemName: isChartFullscreen
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right"
        ) {
            isChartFullscreen.toggle()
        }
    }

    /// Secondary/rarely-used actions, consolidated out of the main row so the
    /// chrome stays uncluttered. The network-debug tool used to sit inline as
    /// a ladybug button on every screen — it lives here now.
    private var overflowMenu: some View {
        Menu {
            Button {
                showDebugLogSheet = true
            } label: {
                Label(
                    NetworkLog.shared.isEnabled ? "Network Debug · capturing" : "Network Debug",
                    systemImage: "ladybug"
                )
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: metrics.iconGlyph, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: metrics.iconHit, height: metrics.iconHit)
                .contentShape(Rectangle())
        }
    }
    
    static func == (lhs: IPadChartHeaderToolbar, rhs: IPadChartHeaderToolbar) -> Bool {
        lhs.timeframe == rhs.timeframe &&
        lhs.userChartType == rhs.userChartType &&
        lhs.replay.isActive == rhs.replay.isActive &&
        lhs.indicatorsRaw == rhs.indicatorsRaw &&
        lhs.oscillatorsRaw == rhs.oscillatorsRaw &&
        lhs.hiddenIndicatorsRaw == rhs.hiddenIndicatorsRaw &&
        lhs.hiddenOscillatorsRaw == rhs.hiddenOscillatorsRaw &&
        lhs.showIndicatorSettings == rhs.showIndicatorSettings &&
        lhs.srVisible == rhs.srVisible &&
        lhs.fvgVisible == rhs.fvgVisible &&
        lhs.supplyDemandVisible == rhs.supplyDemandVisible &&
        lhs.scenarioVisible == rhs.scenarioVisible &&
        lhs.altScenarioVisible == rhs.altScenarioVisible &&
        lhs.hasSRLevels == rhs.hasSRLevels &&
        lhs.hasFVGZones == rhs.hasFVGZones &&
        lhs.hasSupplyDemandZones == rhs.hasSupplyDemandZones &&
        lhs.hasScenario == rhs.hasScenario &&
        lhs.hasAltScenario == rhs.hasAltScenario &&
        lhs.selectedPairID == rhs.selectedPairID &&
        lhs.drawings == rhs.drawings &&
        lhs.selectedDrawingID == rhs.selectedDrawingID &&
        lhs.activeDrawingTool == rhs.activeDrawingTool &&
        lhs.showAnalysis == rhs.showAnalysis &&
        lhs.showDebugLogSheet == rhs.showDebugLogSheet &&
        lhs.showAlertSheet == rhs.showAlertSheet &&
        lhs.isChartFullscreen == rhs.isChartFullscreen
    }
}

struct IPadIndicatorsPopover: View {
    @Binding var indicatorsRaw: String
    @Binding var oscillatorsRaw: String
    @Binding var hiddenIndicatorsRaw: String
    @Binding var hiddenOscillatorsRaw: String
    @Binding var showIndicatorSettings: Bool
    
    private var enabledIndicators: Set<IndicatorKind> {
        Set(indicatorsRaw.split(separator: ",").compactMap { IndicatorKind(rawValue: String($0)) })
    }
    private var enabledOscillators: Set<OscillatorKind> {
        Set(oscillatorsRaw.split(separator: ",").compactMap { OscillatorKind(rawValue: String($0)) })
    }
    private var hiddenIndicators: Set<IndicatorKind> {
        Set(hiddenIndicatorsRaw.split(separator: ",").compactMap { IndicatorKind(rawValue: String($0)) })
    }
    
    private func setIndicator(_ kind: IndicatorKind, enabled: Bool) {
        var s = enabledIndicators
        if enabled { s.insert(kind) } else { s.remove(kind) }
        indicatorsRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }
    private func setOscillator(_ kind: OscillatorKind, enabled: Bool) {
        var s = enabledOscillators
        if enabled { s.insert(kind) } else { s.remove(kind) }
        oscillatorsRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }
    private func setIndicatorHidden(_ kind: IndicatorKind, hidden: Bool) {
        var s = hiddenIndicators
        if hidden { s.insert(kind) } else { s.remove(kind) }
        hiddenIndicatorsRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Indicators")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .padding(.bottom, 4)
                
                Text("Overlays")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.Color.textMuted)
                    .textCase(.uppercase)
                
                ForEach(IndicatorKind.allCases) { kind in
                    let isOn = enabledIndicators.contains(kind)
                    let isHidden = isOn && hiddenIndicators.contains(kind)
                    
                    HStack {
                        Button {
                            setIndicator(kind, enabled: !isOn)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isOn ? Theme.Color.accentStart : Theme.Color.textMuted)
                                Text(kind.label)
                                    .foregroundStyle(Theme.Color.textPrimary)
                            }
                        }
                        .buttonStyle(.plain)
                        
                        Spacer()
                        
                        if isOn {
                            Button {
                                setIndicatorHidden(kind, hidden: !isHidden)
                            } label: {
                                Image(systemName: isHidden ? "eye.slash" : "eye")
                                    .foregroundStyle(Theme.Color.textSecondary)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(height: 32)
                }
                
                Divider().background(Theme.Color.border)
                
                Text("Panels")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.Color.textMuted)
                    .textCase(.uppercase)
                    .padding(.top, 4)
                
                ForEach(OscillatorKind.allCases) { kind in
                    let isOn = enabledOscillators.contains(kind)
                    Button {
                        setOscillator(kind, enabled: !isOn)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isOn ? Theme.Color.accentStart : Theme.Color.textMuted)
                            Text(kind.label)
                                .foregroundStyle(Theme.Color.textPrimary)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(height: 32)
                }
                
                Divider().background(Theme.Color.border)
                
                Button {
                    showIndicatorSettings = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Indicator Settings...")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Color.accentStart)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(16)
        }
        .frame(width: 280, height: 420)
        .background(Theme.Color.surface)
    }
}

struct IPadLayersPopover: View {
    @Binding var indicatorsRaw: String
    @Binding var hiddenIndicatorsRaw: String
    @Binding var oscillatorsRaw: String
    @Binding var hiddenOscillatorsRaw: String
    
    // Visibilities
    @Binding var srVisible: Bool
    @Binding var fvgVisible: Bool
    @Binding var supplyDemandVisible: Bool
    @Binding var scenarioVisible: Bool
    @Binding var altScenarioVisible: Bool
    
    let hasSRLevels: Bool
    let hasFVGZones: Bool
    let hasSupplyDemandZones: Bool
    let hasScenario: Bool
    let hasAltScenario: Bool
    
    // Drawings
    let drawings: [ChartDrawing]
    @Binding var selectedDrawingID: UUID?
    let drawingStore: DrawingStore
    let selectedPairID: String?

    /// Shared economic-calendar feed + the news-flag layer toggle.
    /// Read directly here (both are app-wide) so the toggle doesn't
    /// have to thread through `IPadLayersMenu` / the toolbar's
    /// Equatable structs.
    @EnvironmentObject private var news: NewsStore
    @AppStorage("dashboard.showNews") private var showNews: Bool = true

    private var enabledIndicators: Set<IndicatorKind> {
        Set(indicatorsRaw.split(separator: ",").compactMap { IndicatorKind(rawValue: String($0)) })
    }
    private var hiddenIndicators: Set<IndicatorKind> {
        Set(hiddenIndicatorsRaw.split(separator: ",").compactMap { IndicatorKind(rawValue: String($0)) })
    }
    private var enabledOscillators: Set<OscillatorKind> {
        Set(oscillatorsRaw.split(separator: ",").compactMap { OscillatorKind(rawValue: String($0)) })
    }
    private var hiddenOscillators: Set<OscillatorKind> {
        Set(hiddenOscillatorsRaw.split(separator: ",").compactMap { OscillatorKind(rawValue: String($0)) })
    }

    private func setIndicatorHidden(_ kind: IndicatorKind, hidden: Bool) {
        var s = hiddenIndicators
        if hidden { s.insert(kind) } else { s.remove(kind) }
        hiddenIndicatorsRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }
    private func setOscillatorHidden(_ kind: OscillatorKind, hidden: Bool) {
        var s = hiddenOscillators
        if hidden { s.insert(kind) } else { s.remove(kind) }
        hiddenOscillatorsRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Layers")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.Color.textPrimary)
                    .padding(.bottom, 4)

                // News — economic-calendar flags on the time axis.
                if !news.chartEvents.isEmpty {
                    Text("Chart")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.Color.textMuted)
                        .textCase(.uppercase)
                    toggleRow(label: "News · \(news.chartEvents.count)", isOn: $showNews)
                    Divider().background(Theme.Color.border)
                }

                // Indicators
                let activeIndicators = IndicatorKind.allCases.filter {
                    enabledIndicators.contains($0)
                }
                if !activeIndicators.isEmpty {
                    Text("Indicators")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.Color.textMuted)
                        .textCase(.uppercase)
                    
                    ForEach(activeIndicators) { kind in
                        let isHidden = hiddenIndicators.contains(kind)
                        Button {
                            setIndicatorHidden(kind, hidden: !isHidden)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isHidden ? "eye.slash" : "eye")
                                    .foregroundStyle(Theme.Color.textSecondary)
                                Text(kind.label)
                                    .foregroundStyle(Theme.Color.textPrimary)
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(height: 32)
                    }
                    Divider().background(Theme.Color.border)
                }
                
                // Oscillators
                let activeOscillators = OscillatorKind.allCases.filter { enabledOscillators.contains($0) }
                if !activeOscillators.isEmpty {
                    Text("Oscillators")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.Color.textMuted)
                        .textCase(.uppercase)
                    
                    ForEach(activeOscillators) { kind in
                        let isHidden = hiddenOscillators.contains(kind)
                        Button {
                            setOscillatorHidden(kind, hidden: !isHidden)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isHidden ? "eye.slash" : "eye")
                                    .foregroundStyle(Theme.Color.textSecondary)
                                Text(kind.label)
                                    .foregroundStyle(Theme.Color.textPrimary)
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(height: 32)
                    }
                    Divider().background(Theme.Color.border)
                }
                
                // AI Overlays
                if hasSRLevels || hasFVGZones || hasSupplyDemandZones || hasScenario || hasAltScenario {
                    Text("AI Overlays")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.Color.textMuted)
                        .textCase(.uppercase)
                    
                    if hasSRLevels {
                        toggleRow(label: "S/R Levels", isOn: $srVisible)
                    }
                    if hasFVGZones {
                        toggleRow(label: "FVG Zones", isOn: $fvgVisible)
                    }
                    if hasSupplyDemandZones {
                        toggleRow(label: "Supply & Demand", isOn: $supplyDemandVisible)
                    }
                    if hasScenario {
                        toggleRow(label: "Trade Plan", isOn: $scenarioVisible)
                    }
                    if hasAltScenario {
                        toggleRow(label: "Alt Plan", isOn: $altScenarioVisible)
                    }
                    Divider().background(Theme.Color.border)
                }
                
                // Drawings
                if !drawings.isEmpty {
                    Text("Drawings")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.Color.textMuted)
                        .textCase(.uppercase)
                    
                    ForEach(drawings) { d in
                        Button {
                            if let pairID = selectedPairID {
                                drawingStore.setVisible(!d.visible, id: d.id, for: pairID)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: d.visible ? "eye" : "eye.slash")
                                    .foregroundStyle(Theme.Color.textSecondary)
                                Text(d.kind.rawValue)
                                    .foregroundStyle(Theme.Color.textPrimary)
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(height: 32)
                    }
                    
                    Divider().background(Theme.Color.border)
                    
                    Button(role: .destructive) {
                        if let pairID = selectedPairID {
                            drawingStore.clear(for: pairID)
                            selectedDrawingID = nil
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "trash")
                            Text("Clear All Drawings")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Color.danger)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
            .padding(16)
        }
        .frame(width: 260, height: 380)
        .background(Theme.Color.surface)
    }
    
    private func toggleRow(label: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn.wrappedValue ? "eye" : "eye.slash")
                    .foregroundStyle(Theme.Color.textSecondary)
                Text(label)
                    .foregroundStyle(Theme.Color.textPrimary)
            }
        }
        .buttonStyle(.plain)
        .frame(height: 32)
    }
}
