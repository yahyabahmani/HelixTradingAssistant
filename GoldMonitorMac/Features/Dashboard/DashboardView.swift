import SwiftUI
import Combine

/// Dashboard with live chart. Phases A+B were a placeholder; this is the
/// real implementation using ChartView from Phase D + scheduler from Phase C.
struct DashboardView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var yahoo: YahooScheduler
    @EnvironmentObject private var notificationInbox: NotificationInbox

    // Persisted session state — every selection the user makes here gets
    // restored on relaunch.
    @AppStorage("dashboard.timeframe")  private var timeframe: Timeframe = .h1
    @AppStorage("dashboard.chartType")  private var userChartType: ChartType = .candle
    @AppStorage("dashboard.showVolume") private var showVolume: Bool = true
    @AppStorage("notifications.strategySignals.enabled")
    private var strategyNotificationsEnabled: Bool = true
    /// Multi-instance indicator/oscillator storage — JSON-encoded arrays
    /// persisted to UserDefaults. Each instance holds its kind, params,
    /// and hide/show state.
    private static let indicatorStorageKey = "dashboard.indicators.v2"
    private static let oscillatorStorageKey = "dashboard.oscillators.v2"

    @State private var indicatorInstances: [IndicatorInstance] = []
    @State private var oscillatorInstances: [OscillatorInstance] = []

    /// Which instance's settings panel is open (if any). Setting this
    /// presents the floating draggable panel for that instance.
    @State private var editingIndicatorID: UUID? = nil
    @State private var editingOscillatorID: UUID? = nil

    /// Legacy global settings sheet state — kept for backward compat.
    @State private var showIndicatorSettings: Bool = false
    @State private var settingsFocusSection: String? = nil

    @State private var candles: [Candle] = []
    @State private var isLoading: Bool = false
    /// User-pinned X-axis window, in *bar indices* (Double for fractional
    /// smoothness during pan/zoom). nil ⇒ chart auto-fits to the full
    /// series. Index-based so consecutive candles never get separated by
    /// calendar gaps (weekend market closures, etc.). Reset whenever the
    /// underlying series changes (pair / timeframe). Deliberately NOT
    /// persisted — user expectations are that relaunching shows fresh
    /// auto-fit, not a stale zoomed window.
    @State private var xDomain: ClosedRange<Double>? = nil
    /// Manual vertical price scale (TradingView-style price-axis drag).
    /// nil ⇒ the chart auto-fits Y to the visible data. Reset alongside
    /// `xDomain` whenever the data underfoot changes (pair / timeframe)
    /// so a pinned scale from one symbol doesn't strand the next one's
    /// candles off-screen.
    @State private var yDomain: ClosedRange<Double>? = nil
    /// User-tunable parameters for the oscillators (RSI period, MACD
    /// fast/slow/signal, etc.). Loaded from UserDefaults on init so
    /// settings stick across launches.
    @State private var oscillatorConfig: OscillatorConfig = .load()
    /// Whether the chart-corner indicator legend is expanded.
    @State private var indicatorLegendExpanded: Bool = true
    /// Support / Resistance levels the user has chosen to draw on the
    /// chart from an AI analysis. Cleared when the pair changes; kept
    /// across timeframe switches since levels are price-based, not
    /// time-based.
    @State private var srLevels: PromptBuilder.SRLevels = .init(support: [], resistance: [])
    /// FVG / iFVG zones from the AI analysis. Same lifecycle as
    /// `srLevels` — pair-scoped, cleared on pair change.
    @State private var fvgZones: [PromptBuilder.FVGZone] = []
    /// Supply & Demand rectangles from a Confluence Scanner (or custom) run.
    /// Same lifecycle as `fvgZones` — pair-scoped, cleared when
    /// the user switches pairs. Rendered by ChartView as
    /// translucent rectangles tinted green for Demand / red for
    /// Supply.
    @State private var supplyDemandZones: [PromptBuilder.SupplyDemandZone] = []
    /// Full TA main trade plan (entry / TP / SL + bias). Rendered as
    /// three dashed lines + a bias capsule. Pair-scoped, cleared on
    /// pair change.
    @State private var taScenario: PromptBuilder.TAScenario? = nil
    /// Optional alternative trade plan from the same TA run. Same
    /// shape as `taScenario`; ChartView draws it with muted styling
    /// so the user can tell at a glance which lines belong to which
    /// plan.
    @State private var taAltScenario: PromptBuilder.TAScenario? = nil
    /// Visibility flags for each AI overlay. "Hidden" = chart skips
    /// drawing, underlying data preserved. Distinct from "delete"
    /// (clears the state outright).
    @State private var srVisible: Bool = true
    @State private var fvgVisible: Bool = true
    @State private var supplyDemandVisible: Bool = true
    @State private var scenarioVisible: Bool = true
    @State private var altScenarioVisible: Bool = true
    /// Layers popover open/close.
    @State private var showLayersPopover: Bool = false
    /// Network debug sheet open/close. Driven by the 🐞 toolbar
    /// button.
    @State private var showDebugLogSheet: Bool = false

    /// Lives at the dashboard scope so AI analysis runs survive opening
    /// and closing the AnalysisSheet — the user can launch a run, dismiss
    /// the sheet, scroll the chart, then reopen and find the stream
    /// still going (or done, with the report waiting). Also holds the
    /// persistent history of past analyses.
    /// Lifted to the app root (see HelixTradingApp.swift) so the
    /// Analytics view in the Portfolio tab can read the outcome
    /// history. Still consumed here for AnalysisPage's child wiring.
    @EnvironmentObject private var analysisStore: AnalysisStore
    /// Per-pair persistent store of user-drawn shapes (horizontal /
    /// trend / rectangle). One store across all pairs — `pairID` is
    /// part of the lookup key, not a separate object per pair.
    @StateObject private var drawingStore = DrawingStore()
    /// Per-pair persistent store of paper trades activated from AI
    /// scenarios. Subscribes to the live price stream below to drive
    /// pending → active → closed transitions.
    /// Lifted to the app root so AutoTraderEngine can mutate the
    /// same instance the dashboard observes. Reads come back via
    /// the same `byPair` map so existing chart overlays / Layers
    /// popover / outcome stamping all keep working.
    @EnvironmentObject private var tradeStore: TradeStore
    @EnvironmentObject private var journal: JournalStore
    /// Per-pair auto-trader config — read for the AUTO pill colour
    /// + click action (jumps to the matching Settings category).
    @EnvironmentObject private var autoTraderConfig: AutoTraderConfigStore
    /// Auto-trader engine — read for the live state badge label.
    @EnvironmentObject private var autoTrader: AutoTraderEngine
    @EnvironmentObject private var paperBalance: PaperBalance
    /// Per-app store of price alerts (manual + scenario-derived).
    /// Receives the same yahoo / scheduler ticks the trade
    /// evaluator does and pops macOS notifications on hit.
    @StateObject private var alertStore = AlertStore()
    /// Multi-chart split-screen state (layout + per-pane pair/timeframe/
    /// indicator selections). `.single` (the default) means the grid is
    /// off and `chartCard` renders the full-featured primary chart —
    /// see the layout picker in `pairHeader` and the branch in `body`.
    @StateObject private var multiChart = MultiChartLayoutStore()
    /// Drives the "set price alert" sheet from the chart header.
    @State private var showAlertSheet: Bool = false
    /// Drives the risk calculator popover in the chart toolbar.
    @State private var showRiskCalc: Bool = false

    /// TradingView-style Replay. Holds a single shared cursor `Date`
    /// the candle loader clips to, plus playback state. Ephemeral — see
    /// `ReplayController`.
    @StateObject private var replay = ReplayController()

    /// Working value for the replay date-jump picker. Lets the user
    /// anchor deep into history (years, on h1/h4/d1) without scrolling
    /// the chart back bar-by-bar. Synced to the cursor whenever the
    /// picking phase opens.
    @State private var replayPickerDate: Date = Date()

    /// Strategy-profile picker sheet — fires from the AUTO toggle
    /// when the user enables auto-trading for a pair. The CTS
    /// Analyze button in the analysis page has its own
    /// equivalent sheet so each surface owns its own state.
    @State private var profileSheet: ProfileSheetMode? = nil
    struct ProfileSheetMode: Identifiable {
        let pairID: String
        var id: String { pairID }
    }
    /// Drives the activation sheet. Non-nil when the user has just
    /// clicked "Activate as trade" on a completed full-TA analysis.
    /// Carries both the scenario AND the source history entry ID so
    /// the resulting Trade can stamp its outcome back onto the
    /// entry when it closes (drives the win-rate stat).
    @State private var pendingActivation: PendingActivation?

    /// The live NY Open Setup's plan, as a scenario, or nil when there's
    /// no actionable setup (indicator off, no breakout yet, or already
    /// resolved). Drives the entry/SL alerts (via `syncScenarioAlerts`)
    /// and the "Activate NY Open setup" menu action. Recomputed when a new
    /// 1-minute bar closes — see `refreshNYSetupScenario`.
    @State private var nyLiveScenario: PromptBuilder.TAScenario?

    /// MicroMap notifications are edge-triggered from closed candles only.
    /// The context + timestamp baseline prevents historical alerts when the
    /// indicator is enabled, settings change, or deeper history is prepended.
    @State private var microMapAlertContext: String?
    @State private var microMapSeenEventKeys: Set<String> = []
    @State private var microMapLastClosedTimestamp: TimeInterval?

    /// SP2L setup notifications use the same closed-candle edge-triggering
    /// rules as MicroMap. Enabling the indicator seeds the current results,
    /// so opening a chart never floods Notification Center with history.
    @State private var sp2lAlertContext: String?
    @State private var sp2lSeenEventKeys: Set<String> = []
    @State private var sp2lLastClosedTimestamp: TimeInterval?

    /// Close-confirmed pin bars for SP2L pullbacks and BTB retests.
    @State private var pinBarAlertContext: String?
    @State private var pinBarSeenEventKeys: Set<String> = []
    @State private var pinBarLastClosedTimestamp: TimeInterval?

    /// MTR alerts fire only when the neckline break is confirmed by a
    /// closed candle. Formation itself remains visual-only.
    @State private var mtrAlertContext: String?
    @State private var mtrSeenEventKeys: Set<String> = []
    @State private var mtrLastClosedTimestamp: TimeInterval?

    /// Wraps a scenario + its source history entry ID for
    /// presentation via `.sheet(item:)`. Identifiable on the
    /// scenario's stable id (composed from bias + prices) so two
    /// activations of the same plan don't fragment into separate
    /// sheets.
    struct PendingActivation: Identifiable, Equatable {
        let scenario: PromptBuilder.TAScenario
        let sourceHistoryEntryID: UUID?
        var id: String { scenario.id }
    }

    /// IDs of trades whose terminal outcomes we've already stamped
    /// back onto the source history entry. Prevents the
    /// `tradeStore.$byPair` observer from double-recording a win
    /// or loss on every subsequent emission. Deliberately not
    /// persisted — the history entry's own `outcome` field is
    /// idempotent (recordOutcome is a no-op when already set), so
    /// even if this set resets across launches the worst case is
    /// one redundant lookup per trade.
    @State private var recordedOutcomeTradeIDs: Set<UUID> = []

    /// Create or refresh the entry + SL alerts paired with a
    /// scenario. `suffix` distinguishes main vs alt so the
    /// notification titles read sensibly. Removing the scenario
    /// (passing nil) wipes its alerts. Called from `.onChange` on
    /// the dashboard's scenario state.
    private func syncScenarioAlerts(_ scenario: PromptBuilder.TAScenario?, suffix: String) {
        guard let pairID = app.selectedPairID,
              let pairName = app.pairs.first(where: { $0.id == pairID })?.name
        else { return }
        // Always drop the previous batch under this (pair, suffix)
        // slot — if scenario is now nil this just cleans up; if
        // it's a different scenario the new add() below installs
        // replacements. Prefix-based so we catch the old
        // fingerprint even when scenario.id changes.
        let prefix = "\(pairID)|\(suffix)|"
        alertStore.removeWithSourcePrefix(prefix)

        guard let scenario = scenario else { return }
        let fingerprint = "\(prefix)\(scenario.id)"
        if let entry = scenario.entry {
            alertStore.add(PriceAlert(
                id: UUID(),
                pairID: pairID,
                kind: .scenarioEntry,
                level: entry,
                title: "\(pairName) — entry filled \(suffix)",
                body: "\(scenario.bias.rawValue.uppercased()) entry at \(entry) touched.",
                createdAt: Date(),
                firedAt: nil,
                sourceScenarioID: fingerprint
            ))
        }
        alertStore.add(PriceAlert(
            id: UUID(),
            pairID: pairID,
            kind: .scenarioSL,
            level: scenario.stopLoss,
            title: "\(pairName) — stop hit \(suffix)",
            body: "\(scenario.bias.rawValue.uppercased()) plan invalidated at SL \(scenario.stopLoss).",
            createdAt: Date(),
            firedAt: nil,
            sourceScenarioID: fingerprint
        ))
    }

    /// The live NY Open Setup as a `TAScenario`, or nil when there's
    /// nothing actionable. "Actionable" means a breakout has fired and we
    /// either await the retest or are managing the position — the same
    /// states the alerts + activate-trade flow care about. Computed from
    /// the displayed candles; the detector supports 1m and 5m and returns
    /// nothing on coarser timeframes.
    private func currentNYSetupScenario() -> PromptBuilder.TAScenario? {
        guard enabledIndicatorKinds.contains(.nyOpenSetup), !candles.isEmpty else { return nil }
        let results = NYOpenSetup.compute(
            candles,
            atrMultiple: oscillatorConfig.nyAtrMult,
            amOnly: oscillatorConfig.nyAMOnly
        )
        guard let r = results.last, r.isActionable,
              let entry = r.entry, let tp = r.takeProfit, let sl = r.stopLoss,
              let dir = r.direction
        else { return nil }
        return PromptBuilder.TAScenario(
            bias: dir == .long ? .long : .short,
            entry: entry,
            takeProfit: tp,
            stopLoss: sl
        )
    }

    /// Refresh `nyLiveScenario`. Only mutating the @State when the plan
    /// actually changes (TAScenario is Equatable) means the downstream
    /// `.onChange` → `syncScenarioAlerts` won't re-arm an already-fired
    /// alert on every bar — it re-syncs only when a new plan forms, the
    /// plan clears, or it flips direction.
    private func refreshNYSetupScenario() {
        nyLiveScenario = currentNYSetupScenario()
    }

    private func refreshMicroMapNotifications(seedOnly: Bool) {
        guard let pairID = app.selectedPairID,
              let pair = app.pairs.first(where: { $0.id == pairID }),
              isStrategyNotificationActive(.microMapStrategy),
              candles.count > 1
        else {
            microMapAlertContext = nil
            microMapSeenEventKeys = []
            microMapLastClosedTimestamp = nil
            return
        }

        // The last chart candle may still be forming. Removing it makes
        // entries/stops strictly close-confirmed while targets can still use
        // the completed candle's high/low inside the detector.
        let closedCandles = Array(candles.dropLast())
        guard let newestClosed = closedCandles.last else { return }
        let results = MicroMapSetup.compute(
            closedCandles,
            configuration: oscillatorConfig.microMapConfiguration
        )
        let context = "\(pairID)|\(timeframe.rawValue)"
        let allKeys = microMapEventKeys(results)

        guard !seedOnly,
              microMapAlertContext == context,
              let previousTimestamp = microMapLastClosedTimestamp
        else {
            microMapAlertContext = context
            microMapSeenEventKeys = allKeys
            microMapLastClosedTimestamp = newestClosed.id.timeIntervalSince1970
            return
        }

        for result in results {
            let formedKey = microMapFormedEventKey(result)
            if result.microEndIndex < closedCandles.count,
               closedCandles[result.microEndIndex].id.timeIntervalSince1970 > previousTimestamp,
               !microMapSeenEventKeys.contains(formedKey) {
                let side = result.direction == .long ? "LONG" : "SHORT"
                notificationInbox.record(
                    dedupKey: formedKey,
                    cooldown: 10 * 365 * 24 * 60 * 60,
                    pairID: pairID,
                    pairLabel: pair.name,
                    category: .strategy,
                    title: "\(pair.name) - MicroMap is forming",
                    body: "A \(side) micro-channel setup has formed and is waiting for entry confirmation.",
                    timeframeLabel: timeframe.rawValue,
                    chartTarget: notificationTarget(
                        pairID: pairID,
                        indicator: .microMapStrategy,
                        candle: closedCandles[result.microEndIndex],
                        price: result.direction == .long ? result.spikeHigh : result.spikeLow,
                        label: "MicroMap \(side)"
                    )
                )
            }

            for attempt in result.attempts {
                guard let trigger = attempt.triggerIndex,
                      trigger < closedCandles.count,
                      closedCandles[trigger].id.timeIntervalSince1970 > previousTimestamp
                else { continue }
                let key = microMapEntryEventKey(result: result, attempt: attempt)
                guard !microMapSeenEventKeys.contains(key) else { continue }
                let side = result.direction == .long ? "LONG" : "SHORT"
                let quality: String
                switch result.confluence.quality {
                case .standard: quality = "standard"
                case .confirmed: quality = "confirmed"
                case .strong: quality = "strong"
                }
                notificationInbox.record(
                    dedupKey: key,
                    cooldown: 10 * 365 * 24 * 60 * 60,
                    pairID: pairID,
                    pairLabel: pair.name,
                    category: .strategy,
                    title: "\(pair.name) - MicroMap entry \(attempt.number)",
                    body: "\(side) entry confirmed at \(PriceFormat.exact(attempt.entry ?? closedCandles[trigger].close)). \(quality.capitalized) confluence \(result.confluence.score)/6.",
                    timeframeLabel: timeframe.rawValue,
                    chartTarget: notificationTarget(
                        pairID: pairID,
                        indicator: .microMapStrategy,
                        candle: closedCandles[trigger],
                        price: attempt.entry ?? closedCandles[trigger].close,
                        label: "MicroMap entry \(attempt.number)"
                    )
                )
            }

            if result.stage == .invalidated,
               let end = result.endIndex,
               end < closedCandles.count,
               closedCandles[end].id.timeIntervalSince1970 > previousTimestamp {
                let key = microMapInvalidationEventKey(result)
                if !microMapSeenEventKeys.contains(key) {
                    notificationInbox.record(
                        dedupKey: key,
                        cooldown: 10 * 365 * 24 * 60 * 60,
                        pairID: pairID,
                        pairLabel: pair.name,
                        category: .strategy,
                        title: "\(pair.name) - MicroMap invalidated",
                        body: "The third close-confirmed stop invalidated the \(result.direction.rawValue.uppercased()) setup.",
                        timeframeLabel: timeframe.rawValue,
                        chartTarget: notificationTarget(
                            pairID: pairID,
                            indicator: .microMapStrategy,
                            candle: closedCandles[end],
                            price: closedCandles[end].close,
                            label: "MicroMap invalidated"
                        )
                    )
                }
            }
        }

        microMapSeenEventKeys.formUnion(allKeys)
        microMapLastClosedTimestamp = newestClosed.id.timeIntervalSince1970
    }

    private func microMapEventKeys(_ results: [MicroMapSetup.Result]) -> Set<String> {
        var keys: Set<String> = []
        for result in results {
            keys.insert(microMapFormedEventKey(result))
            for attempt in result.attempts where attempt.triggerIndex != nil {
                keys.insert(microMapEntryEventKey(result: result, attempt: attempt))
            }
            if result.stage == .invalidated {
                keys.insert(microMapInvalidationEventKey(result))
            }
        }
        return keys
    }

    private func microMapFormedEventKey(_ result: MicroMapSetup.Result) -> String {
        "micromap|\(app.selectedPairID ?? "")|\(timeframe.rawValue)|\(result.id)|formed"
    }

    private func microMapEntryEventKey(
        result: MicroMapSetup.Result,
        attempt: MicroMapSetup.Attempt
    ) -> String {
        "micromap|\(app.selectedPairID ?? "")|\(timeframe.rawValue)|\(result.id)|entry|\(attempt.number)"
    }

    private func microMapInvalidationEventKey(_ result: MicroMapSetup.Result) -> String {
        "micromap|\(app.selectedPairID ?? "")|\(timeframe.rawValue)|\(result.id)|invalidated"
    }

    private func refreshSP2LNotifications(seedOnly: Bool) {
        guard let pairID = app.selectedPairID,
              let pair = app.pairs.first(where: { $0.id == pairID }),
              isStrategyNotificationActive(.sp2lStrategy),
              candles.count > 1
        else {
            sp2lAlertContext = nil
            sp2lSeenEventKeys = []
            sp2lLastClosedTimestamp = nil
            return
        }

        let closedCandles = Array(candles.dropLast())
        guard let newestClosed = closedCandles.last else { return }
        let results = SP2LSetup.compute(
            closedCandles,
            minSpikeBars: oscillatorConfig.sp2lMinSpikeBars,
            maxSpikeBars: oscillatorConfig.sp2lMaxSpikeBars,
            rangeBars: oscillatorConfig.sp2lRangeBars,
            atrPeriod: oscillatorConfig.sp2lATRPeriod,
            minSpikeATR: oscillatorConfig.sp2lMinSpikeATR,
            maxSpikeATR: oscillatorConfig.sp2lMaxSpikeATR,
            maxRangeATR: oscillatorConfig.sp2lMaxRangeATR,
            minGapPct: oscillatorConfig.sp2lMinGapPct,
            maxPressureGapBar: oscillatorConfig.sp2lMaxPressureGapBar,
            emaPeriod: oscillatorConfig.sp2lEMAPeriod,
            useEMAContext: oscillatorConfig.sp2lUseEMAContext,
            maxEMADistanceATR: oscillatorConfig.sp2lMaxEMADistanceATR,
            maxPullbackBars: oscillatorConfig.sp2lMaxPullbackBars,
            maxContinuationBars: oscillatorConfig.sp2lMaxContinuationBars,
            riskReward: oscillatorConfig.sp2lRiskReward,
            targetCount: oscillatorConfig.sp2lTargetCount
        )
        let context = "\(pairID)|\(timeframe.rawValue)"
        let allKeys = Set(results.map(sp2lFormedEventKey))

        guard !seedOnly,
              sp2lAlertContext == context,
              let previousTimestamp = sp2lLastClosedTimestamp
        else {
            sp2lAlertContext = context
            sp2lSeenEventKeys = allKeys
            sp2lLastClosedTimestamp = newestClosed.id.timeIntervalSince1970
            return
        }

        for result in results {
            guard result.followThroughIndex < closedCandles.count,
                  closedCandles[result.followThroughIndex].id.timeIntervalSince1970 > previousTimestamp
            else { continue }
            let key = sp2lFormedEventKey(result)
            guard !sp2lSeenEventKeys.contains(key) else { continue }
            let side = result.direction == .long ? "LONG" : "SHORT"
            notificationInbox.record(
                dedupKey: key,
                cooldown: 10 * 365 * 24 * 60 * 60,
                pairID: pairID,
                pairLabel: pair.name,
                category: .strategy,
                title: "\(pair.name) - SP2L is forming",
                body: "A \(side) SP2L setup has formed. Limit entry: \(PriceFormat.exact(result.entry)), stop: \(PriceFormat.exact(result.stopLoss)).",
                timeframeLabel: timeframe.rawValue,
                chartTarget: notificationTarget(
                    pairID: pairID,
                    indicator: .sp2lStrategy,
                    candle: closedCandles[result.followThroughIndex],
                    price: result.entry,
                    label: "SP2L entry"
                )
            )
        }

        sp2lSeenEventKeys.formUnion(allKeys)
        sp2lLastClosedTimestamp = newestClosed.id.timeIntervalSince1970
    }

    private func sp2lFormedEventKey(_ result: SP2LSetup.Result) -> String {
        "sp2l|\(app.selectedPairID ?? "")|\(timeframe.rawValue)|\(result.id)|formed"
    }

    private func refreshPinBarNotifications(seedOnly: Bool) {
        guard let pairID = app.selectedPairID,
              let pair = app.pairs.first(where: { $0.id == pairID }),
              isStrategyNotificationActive(.pinBarCombo),
              candles.count > 1
        else {
            pinBarAlertContext = nil
            pinBarSeenEventKeys = []
            pinBarLastClosedTimestamp = nil
            return
        }

        let closedCandles = Array(candles.dropLast())
        guard let newestClosed = closedCandles.last else { return }
        let sp2lResults = SP2LSetup.compute(
            closedCandles,
            minSpikeBars: oscillatorConfig.sp2lMinSpikeBars,
            maxSpikeBars: oscillatorConfig.sp2lMaxSpikeBars,
            rangeBars: oscillatorConfig.sp2lRangeBars,
            atrPeriod: oscillatorConfig.sp2lATRPeriod,
            minSpikeATR: oscillatorConfig.sp2lMinSpikeATR,
            maxSpikeATR: oscillatorConfig.sp2lMaxSpikeATR,
            maxRangeATR: oscillatorConfig.sp2lMaxRangeATR,
            minGapPct: oscillatorConfig.sp2lMinGapPct,
            maxPressureGapBar: oscillatorConfig.sp2lMaxPressureGapBar,
            emaPeriod: oscillatorConfig.sp2lEMAPeriod,
            useEMAContext: oscillatorConfig.sp2lUseEMAContext,
            maxEMADistanceATR: oscillatorConfig.sp2lMaxEMADistanceATR,
            maxPullbackBars: oscillatorConfig.sp2lMaxPullbackBars,
            maxContinuationBars: oscillatorConfig.sp2lMaxContinuationBars,
            riskReward: oscillatorConfig.sp2lRiskReward,
            targetCount: oscillatorConfig.sp2lTargetCount
        )
        let results = PinBarComboSetup.compute(
            closedCandles,
            sp2lResults: sp2lResults,
            configuration: oscillatorConfig.pinBarComboConfiguration
        )
        let context = "\(pairID)|\(timeframe.rawValue)"
        let allKeys = Set(results.map(pinBarConfirmedEventKey))

        guard !seedOnly,
              pinBarAlertContext == context,
              let previousTimestamp = pinBarLastClosedTimestamp
        else {
            pinBarAlertContext = context
            pinBarSeenEventKeys = allKeys
            pinBarLastClosedTimestamp = newestClosed.id.timeIntervalSince1970
            return
        }

        for result in results {
            guard result.confirmationIndex < closedCandles.count,
                  closedCandles[result.confirmationIndex].id.timeIntervalSince1970 > previousTimestamp
            else { continue }
            let key = pinBarConfirmedEventKey(result)
            guard !pinBarSeenEventKeys.contains(key) else { continue }
            let side = result.direction == .long ? "LONG" : "SHORT"
            let setup = result.kind == .sp2l ? "SP2L + Pin Bar" : "BTB + Pin Bar"
            notificationInbox.record(
                dedupKey: key,
                cooldown: 10 * 365 * 24 * 60 * 60,
                pairID: pairID,
                pairLabel: pair.name,
                category: .strategy,
                title: "\(pair.name) - \(setup) \(side) confirmed",
                body: "Entry \(PriceFormat.exact(result.entry)), stop \(PriceFormat.exact(result.stopLoss)), target \(PriceFormat.exact(result.takeProfit)).",
                timeframeLabel: timeframe.rawValue,
                chartTarget: notificationTarget(
                    pairID: pairID,
                    indicator: .pinBarCombo,
                    candle: closedCandles[result.confirmationIndex],
                    price: result.entry,
                    label: "\(setup) entry"
                )
            )
        }

        pinBarSeenEventKeys.formUnion(allKeys)
        pinBarLastClosedTimestamp = newestClosed.id.timeIntervalSince1970
    }

    private func pinBarConfirmedEventKey(_ result: PinBarComboSetup.Result) -> String {
        "pinbar|\(app.selectedPairID ?? "")|\(timeframe.rawValue)|\(result.id)|confirmed"
    }

    private func refreshMTRNotifications(seedOnly: Bool) {
        guard let pairID = app.selectedPairID,
              let pair = app.pairs.first(where: { $0.id == pairID }),
              isStrategyNotificationActive(.mtrStrategy),
              candles.count > 1
        else {
            mtrAlertContext = nil
            mtrSeenEventKeys = []
            mtrLastClosedTimestamp = nil
            return
        }

        // The chart's tail can still be changing. Confirmation alerts are
        // intentionally evaluated only after that candle becomes closed.
        let closedCandles = Array(candles.dropLast())
        guard let newestClosed = closedCandles.last else { return }
        let results = MTRSetup.compute(
            closedCandles,
            configuration: oscillatorConfig.mtrConfiguration
        )
        let confirmed = results.filter(\.isConfirmed)
        let context = "\(pairID)|\(timeframe.rawValue)"
        let allKeys = Set(confirmed.map(mtrConfirmedEventKey))

        guard !seedOnly,
              mtrAlertContext == context,
              let previousTimestamp = mtrLastClosedTimestamp
        else {
            mtrAlertContext = context
            mtrSeenEventKeys = allKeys
            mtrLastClosedTimestamp = newestClosed.id.timeIntervalSince1970
            return
        }

        for result in confirmed {
            guard let confirmation = result.confirmationIndex,
                  confirmation < closedCandles.count,
                  closedCandles[confirmation].id.timeIntervalSince1970 > previousTimestamp,
                  let entry = result.entry,
                  let stop = result.stopLoss,
                  let target = result.takeProfit
            else { continue }
            let key = mtrConfirmedEventKey(result)
            guard !mtrSeenEventKeys.contains(key) else { continue }
            let side = result.direction == .long ? "LONG" : "SHORT"
            notificationInbox.record(
                dedupKey: key,
                cooldown: 10 * 365 * 24 * 60 * 60,
                pairID: pairID,
                pairLabel: pair.name,
                category: .strategy,
                title: "\(pair.name) - MTR \(side) confirmed",
                body: "\(result.variant.label). Entry \(PriceFormat.exact(entry)), stop \(PriceFormat.exact(stop)), target \(PriceFormat.exact(target)).",
                timeframeLabel: timeframe.rawValue,
                chartTarget: notificationTarget(
                    pairID: pairID,
                    indicator: .mtrStrategy,
                    candle: closedCandles[confirmation],
                    price: entry,
                    label: "MTR \(side) entry"
                )
            )
        }

        mtrSeenEventKeys.formUnion(allKeys)
        mtrLastClosedTimestamp = newestClosed.id.timeIntervalSince1970
    }

    private func mtrConfirmedEventKey(_ result: MTRSetup.Result) -> String {
        "mtr|\(app.selectedPairID ?? "")|\(timeframe.rawValue)|\(result.direction.rawValue)|\(result.channelStartIndex)|\(result.channelEndIndex)|\(result.breakoutIndex)|\(result.retestIndex)|\(result.confirmationIndex ?? -1)"
    }

    private func notificationTarget(
        pairID: String,
        indicator: IndicatorKind,
        candle: Candle,
        price: Double,
        label: String
    ) -> NotificationChartTarget {
        NotificationChartTarget(
            pairID: pairID,
            timeframeRawValue: timeframe.rawValue,
            indicatorRawValue: indicator.rawValue,
            candleDate: candle.id,
            price: price,
            label: label
        )
    }
    /// Tool currently armed in the chart toolbar. `.none` ⇒ pointer
    /// (drag pans). Set via the drawing toolbar buttons; deliberately
    /// NOT persisted — relaunching with a tool armed would be
    /// confusing because the cursor changes behavior silently.
    @State private var activeDrawingTool: DrawingTool = .none
    /// Drawing currently in "edit mode" — handles are rendered at its
    /// endpoints/corners and the inspector popover is shown. Nil ⇒
    /// nothing selected. Cleared when the pair changes (the drawing
    /// wouldn't exist on the new pair anyway).
    @State private var selectedDrawingID: UUID? = nil
    /// Convenience accessor — fullscreen mode is stored in AppState so
    /// the sidebar can collapse when it flips on.
    private var isChartFull: Bool { app.isChartFullscreen }

    /// One-word validity tag for the Layers popover. Computes
    /// `LONG VALID` / `SHORT INVALID` / `NEUTRAL VALID` etc. using the
    /// current pair's live price. When no live price is available
    /// (the bootstrap hasn't landed yet, or a non-live-stream pair
    /// without a snapshot tick) we just show the bias label and skip
    /// the validity verdict.
    private func scenarioValidityLabel(_ s: PromptBuilder.TAScenario) -> String {
        let bias = s.bias.rawValue.uppercased()
        guard let pairID = app.selectedPairID else { return bias }
        let live: Double? = {
            if let p = yahoo.latestPrices[pairID] { return p }
            return app.pairs.first(where: { $0.id == pairID })?.price
        }()
        guard let price = live, price > 0 else { return bias }
        return s.isValid(at: price) ? "\(bias) · VALID" : "\(bias) · INVALID"
    }

    /// Decoded view of the persisted indicator/oscillator selections.
    /// Both are stored in @AppStorage as a comma-separated rawValue
    /// string — Set isn't a @AppStorage-supported type directly, so we
    /// translate at the boundary.
    private var enabledIndicatorKinds: Set<IndicatorKind> {
        Set(indicatorInstances.map(\.kind))
    }

    private var visibleIndicatorInstances: [IndicatorInstance] {
        indicatorInstances.filter { !$0.hidden }
    }

    /// The eye icon is the per-indicator notification switch. Settings keeps
    /// one master switch that can silence every strategy at once.
    private func isStrategyNotificationActive(_ kind: IndicatorKind) -> Bool {
        strategyNotificationsEnabled && visibleIndicatorInstances.contains { $0.kind == kind }
    }

    private var visibleOscillatorInstances: [OscillatorInstance] {
        oscillatorInstances.filter { !$0.hidden }
    }

    // ── Backward-compat helpers for legacy UI sections ──────────────

    private var enabledOscillators: Set<OscillatorKind> {
        Set(oscillatorInstances.map(\.kind))
    }
    private var hiddenIndicators: Set<IndicatorKind> {
        Set(indicatorInstances.filter(\.hidden).map(\.kind))
    }
    private var hiddenOscillators: Set<OscillatorKind> {
        Set(oscillatorInstances.filter(\.hidden).map(\.kind))
    }

    private func setIndicator(_ kind: IndicatorKind, enabled: Bool) {
        if enabled, !indicatorInstances.contains(where: { $0.kind == kind }) {
            addIndicator(kind)
        } else if !enabled {
            indicatorInstances.removeAll { $0.kind == kind }
            saveIndicators()
        }
    }
    private func setOscillator(_ kind: OscillatorKind, enabled: Bool) {
        if enabled, !oscillatorInstances.contains(where: { $0.kind == kind }) {
            addOscillator(kind)
        } else if !enabled {
            oscillatorInstances.removeAll { $0.kind == kind }
            saveOscillators()
        }
    }
    private func setIndicatorHidden(_ kind: IndicatorKind, hidden: Bool) {
        for i in indicatorInstances.indices where indicatorInstances[i].kind == kind {
            indicatorInstances[i].hidden = hidden
        }
        saveIndicators()
    }
    private func setOscillatorHidden(_ kind: OscillatorKind, hidden: Bool) {
        for i in oscillatorInstances.indices where oscillatorInstances[i].kind == kind {
            oscillatorInstances[i].hidden = hidden
        }
        saveOscillators()
    }

    /// Add a new indicator instance with the given kind's default params.
    private func addIndicator(_ kind: IndicatorKind) {
        let inst = IndicatorInstance(kind: kind)
        indicatorInstances.append(inst)
        saveIndicators()
    }

    /// Remove an indicator instance by id.
    private func removeIndicator(id: UUID) {
        indicatorInstances.removeAll { $0.id == id }
        saveIndicators()
    }

    /// Update an indicator instance in-place.
    private func updateIndicator(_ inst: IndicatorInstance) {
        guard let idx = indicatorInstances.firstIndex(where: { $0.id == inst.id }) else { return }
        indicatorInstances[idx] = inst
        saveIndicators()
        syncIndicatorParamsToConfig(inst)
    }

    /// Toggle hide/show for an indicator instance.
    private func toggleIndicatorHidden(id: UUID) {
        guard let idx = indicatorInstances.firstIndex(where: { $0.id == id }) else { return }
        indicatorInstances[idx].hidden.toggle()
        saveIndicators()
    }

    private func addOscillator(_ kind: OscillatorKind) {
        let inst = OscillatorInstance(kind: kind)
        oscillatorInstances.append(inst)
        saveOscillators()
    }

    private func removeOscillator(id: UUID) {
        oscillatorInstances.removeAll { $0.id == id }
        saveOscillators()
    }

    private func updateOscillator(_ inst: OscillatorInstance) {
        guard let idx = oscillatorInstances.firstIndex(where: { $0.id == inst.id }) else { return }
        oscillatorInstances[idx] = inst
        saveOscillators()
        syncOscillatorParamsToConfig(inst)
    }

    private func toggleOscillatorHidden(id: UUID) {
        guard let idx = oscillatorInstances.firstIndex(where: { $0.id == id }) else { return }
        oscillatorInstances[idx].hidden.toggle()
        saveOscillators()
    }

    // ── Config ↔ instance param sync ─────────────────────────────
    //
    // Two settings systems exist in parallel:
    //   1. `oscillatorConfig` (OscillatorConfig) — the global config
    //      persisted at "dashboard.indicator.config.v2", edited by the
    //      IndicatorSettingsSheet.
    //   2. `indicatorInstances` / `oscillatorInstances` — per-instance
    //      params persisted at "dashboard.indicators.v2" /
    //      "dashboard.oscillators.v2", edited by the floating
    //      IndicatorSettingsPanel / OscillatorSettingsPanel.
    //
    // ChartView reads overlay indicators (UT Bot, OB, FVG, etc.) from
    // `oscillatorConfig`, while OscillatorPanel reads from
    // `instance.params`.  The methods below keep the two in sync so
    // changes from either UI propagate to the chart immediately.

    /// Push an overlay indicator instance's params into `oscillatorConfig`
    /// so ChartView picks them up without a restart.
    private func syncIndicatorParamsToConfig(_ inst: IndicatorInstance) {
        let p = inst.params
        switch inst.kind {
        case .utBot:
            if let v = p["keyValue"]         { oscillatorConfig.utKeyValue = v.doubleValue }
            if let v = p["atrPeriod"]        { oscillatorConfig.utATRPeriod = Int(v.doubleValue) }
            if let v = p["useHeikinAshi"]    { oscillatorConfig.utUseHeikinAshi = v.boolValue }
            if let v = p["showTrailingStop"] { oscillatorConfig.utShowTrailingStop = v.boolValue }
        case .orderBlock:
            if let v = p["periods"]       { oscillatorConfig.obPeriods = Int(v.doubleValue) }
            if let v = p["threshold"]     { oscillatorConfig.obThreshold = v.doubleValue }
            if let v = p["useWicks"]      { oscillatorConfig.obUseWicks = v.boolValue }
            if let v = p["showExhausted"] { oscillatorConfig.obShowExhausted = v.boolValue }
            if let v = p["detectSteroids"]{ oscillatorConfig.obDetectSteroids = v.boolValue }
            if let v = p["notifyEvents"]  { oscillatorConfig.obNotifyEvents = v.boolValue }
        case .steroidOrderBlock:
            if let v = p["periods"]        { oscillatorConfig.sobPeriods = Int(v.doubleValue) }
            if let v = p["threshold"]      { oscillatorConfig.sobThreshold = v.doubleValue }
            if let v = p["volumeMult"]     { oscillatorConfig.sobVolumeMultiplier = v.doubleValue }
            if let v = p["useWicks"]       { oscillatorConfig.sobUseWicks = v.boolValue }
            if let v = p["showExhausted"]  { oscillatorConfig.sobShowExhausted = v.boolValue }
            if let v = p["detectSteroids"] { oscillatorConfig.sobDetectSteroids = v.boolValue }
            if let v = p["notifyEvents"]   { oscillatorConfig.sobNotifyEvents = v.boolValue }
        case .tradingSession:
            if let v = p["showTokyo"]     { oscillatorConfig.sessShowTokyo = v.boolValue }
            if let v = p["showLondon"]    { oscillatorConfig.sessShowLondon = v.boolValue }
            if let v = p["showNewYork"]   { oscillatorConfig.sessShowNewYork = v.boolValue }
            if let v = p["showNames"]     { oscillatorConfig.sessShowNames = v.boolValue }
            if let v = p["showOpenClose"] { oscillatorConfig.sessShowOpenClose = v.boolValue }
            if let v = p["showRange"]     { oscillatorConfig.sessShowRange = v.boolValue }
            if let v = p["showAverage"]   { oscillatorConfig.sessShowAverage = v.boolValue }
        case .nyOpenSetup:
            if let v = p["atrMult"] { oscillatorConfig.nyAtrMult = v.doubleValue }
            if let v = p["amOnly"]  { oscillatorConfig.nyAMOnly = v.boolValue }
        case .sp2lStrategy:
            if let v = p["minSpikeBars"]        { oscillatorConfig.sp2lMinSpikeBars = Int(v.doubleValue) }
            if let v = p["maxSpikeBars"]        { oscillatorConfig.sp2lMaxSpikeBars = Int(v.doubleValue) }
            if let v = p["rangeBars"]           { oscillatorConfig.sp2lRangeBars = Int(v.doubleValue) }
            if let v = p["atrPeriod"]           { oscillatorConfig.sp2lATRPeriod = Int(v.doubleValue) }
            if let v = p["minSpikeATR"]         { oscillatorConfig.sp2lMinSpikeATR = v.doubleValue }
            if let v = p["maxSpikeATR"]         { oscillatorConfig.sp2lMaxSpikeATR = v.doubleValue }
            if let v = p["maxRangeATR"]         { oscillatorConfig.sp2lMaxRangeATR = v.doubleValue }
            if let v = p["minGapPct"]           { oscillatorConfig.sp2lMinGapPct = v.doubleValue }
            if let v = p["maxPressureGapBar"]   { oscillatorConfig.sp2lMaxPressureGapBar = Int(v.doubleValue) }
            if let v = p["emaPeriod"]           { oscillatorConfig.sp2lEMAPeriod = Int(v.doubleValue) }
            if let v = p["useEMAContext"]       { oscillatorConfig.sp2lUseEMAContext = v.boolValue }
            if let v = p["maxEMADistanceATR"]   { oscillatorConfig.sp2lMaxEMADistanceATR = v.doubleValue }
            if let v = p["maxPullbackBars"]     { oscillatorConfig.sp2lMaxPullbackBars = Int(v.doubleValue) }
            if let v = p["maxContinuationBars"] { oscillatorConfig.sp2lMaxContinuationBars = Int(v.doubleValue) }
            if let v = p["riskReward"]          { oscillatorConfig.sp2lRiskReward = v.doubleValue }
            if let v = p["targetCount"]         { oscillatorConfig.sp2lTargetCount = Int(v.doubleValue) }
        case .pinBarCombo:
            if let v = p["enableSP2L"]            { oscillatorConfig.pinBarEnableSP2L = v.boolValue }
            if let v = p["enableBTB"]             { oscillatorConfig.pinBarEnableBTB = v.boolValue }
            if let v = p["atrPeriod"]             { oscillatorConfig.pinBarATRPeriod = Int(v.doubleValue) }
            if let v = p["minWickBodyRatio"]      { oscillatorConfig.pinBarMinWickBodyRatio = v.doubleValue }
            if let v = p["minWickRangeRatio"]     { oscillatorConfig.pinBarMinWickRangeRatio = v.doubleValue }
            if let v = p["maxBodyRangeRatio"]     { oscillatorConfig.pinBarMaxBodyRangeRatio = v.doubleValue }
            if let v = p["minCloseLocation"]      { oscillatorConfig.pinBarMinCloseLocation = v.doubleValue }
            if let v = p["oppositeWickDominance"] { oscillatorConfig.pinBarOppositeWickDominance = v.doubleValue }
            if let v = p["touchToleranceATR"]     { oscillatorConfig.pinBarTouchToleranceATR = v.doubleValue }
            if let v = p["stopBufferATR"]         { oscillatorConfig.pinBarStopBufferATR = v.doubleValue }
            if let v = p["maxConfirmationBars"]   { oscillatorConfig.pinBarMaxConfirmationBars = Int(v.doubleValue) }
            if let v = p["btbLookbackBars"]       { oscillatorConfig.pinBarBTBLookbackBars = Int(v.doubleValue) }
            if let v = p["minBreakoutBodyATR"]    { oscillatorConfig.pinBarMinBreakoutBodyATR = v.doubleValue }
            if let v = p["riskReward"]            { oscillatorConfig.pinBarRiskReward = v.doubleValue }
            if let v = p["maxContinuationBars"]   { oscillatorConfig.pinBarMaxContinuationBars = Int(v.doubleValue) }
        case .microMapStrategy:
            if let v = p["atrPeriod"]             { oscillatorConfig.microMapATRPeriod = Int(v.doubleValue) }
            if let v = p["minSpikeBars"]          { oscillatorConfig.microMapMinSpikeBars = Int(v.doubleValue) }
            if let v = p["maxSpikeBars"]          { oscillatorConfig.microMapMaxSpikeBars = Int(v.doubleValue) }
            if let v = p["minSpikeATR"]           { oscillatorConfig.microMapMinSpikeATR = v.doubleValue }
            if let v = p["minDirectionalRatio"]  { oscillatorConfig.microMapMinDirectionalRatio = v.doubleValue }
            if let v = p["minBodyRatio"]          { oscillatorConfig.microMapMinBodyRatio = v.doubleValue }
            if let v = p["maxCloseFromExtreme"]  { oscillatorConfig.microMapMaxCloseFromExtreme = v.doubleValue }
            if let v = p["minMicroBars"]          { oscillatorConfig.microMapMinMicroBars = Int(v.doubleValue) }
            if let v = p["maxMicroBars"]          { oscillatorConfig.microMapMaxMicroBars = Int(v.doubleValue) }
            if let v = p["maxMicroRangeRatio"]   { oscillatorConfig.microMapMaxMicroRangeRatio = v.doubleValue }
            if let v = p["maxRetracement"]        { oscillatorConfig.microMapMaxRetracement = v.doubleValue }
            if let v = p["structureToleranceATR"] { oscillatorConfig.microMapStructureToleranceATR = v.doubleValue }
            if let v = p["maxReentryBars"]        { oscillatorConfig.microMapMaxReentryBars = Int(v.doubleValue) }
            if let v = p["riskReward"]             { oscillatorConfig.microMapRiskReward = v.doubleValue }
            if let v = p["confluenceBalanceBars"] { oscillatorConfig.microMapConfluenceBalanceBars = Int(v.doubleValue) }
            if let v = p["confluenceEMAPeriod"]   { oscillatorConfig.microMapConfluenceEMAPeriod = Int(v.doubleValue) }
            if let v = p["minPressureGapPct"]     { oscillatorConfig.microMapMinPressureGapPct = v.doubleValue }
            if let v = p["maxPressureGapBar"]     { oscillatorConfig.microMapMaxPressureGapBar = Int(v.doubleValue) }
            if let v = p["requirePressureGap"]    { oscillatorConfig.microMapRequirePressureGap = v.boolValue }
            if let v = p["requireKeyLevelBreak"] { oscillatorConfig.microMapRequireKeyLevelBreak = v.boolValue }
            if let v = p["minConfluenceScore"]   { oscillatorConfig.microMapMinConfluenceScore = Int(v.doubleValue) }
            if let v = p["notifyEvents"]           { oscillatorConfig.microMapNotifyEvents = v.boolValue }
        case .mtrStrategy:
            if let v = p["pivotDepth"]          { oscillatorConfig.mtrPivotDepth = Int(v.doubleValue) }
            if let v = p["atrPeriod"]           { oscillatorConfig.mtrATRPeriod = Int(v.doubleValue) }
            if let v = p["minTrendLegATR"]      { oscillatorConfig.mtrMinTrendLegATR = v.doubleValue }
            if let v = p["breakBufferATR"]      { oscillatorConfig.mtrBreakBufferATR = v.doubleValue }
            if let v = p["retestToleranceATR"]  { oscillatorConfig.mtrRetestToleranceATR = v.doubleValue }
            if let v = p["maxFailedBreakATR"]   { oscillatorConfig.mtrMaxFailedBreakATR = v.doubleValue }
            if let v = p["maxRetestBars"]       { oscillatorConfig.mtrMaxRetestBars = Int(v.doubleValue) }
            if let v = p["maxConfirmationBars"] { oscillatorConfig.mtrMaxConfirmationBars = Int(v.doubleValue) }
            if let v = p["stopBufferATR"]       { oscillatorConfig.mtrStopBufferATR = v.doubleValue }
            if let v = p["riskReward"]          { oscillatorConfig.mtrRiskReward = v.doubleValue }
            if let v = p["maxTradeBars"]        { oscillatorConfig.mtrMaxTradeBars = Int(v.doubleValue) }
            if let v = p["maxResults"]           { oscillatorConfig.mtrMaxResults = Int(v.doubleValue) }
        case .fairValueGap:
            if let v = p["threshold"]     { oscillatorConfig.fvgThreshold = v.doubleValue }
            if let v = p["showMitigated"] { oscillatorConfig.fvgShowMitigated = v.boolValue }
        case .sonarlabOrderBlock:
            if let v = p["sensitivity"]     { oscillatorConfig.sonarlabSensitivity = v.doubleValue }
            if let v = p["mitigationType"]  { oscillatorConfig.sonarlabMitigationType = v.stringValue }
        case .changeOfCharacter:
            if let v = p["swingLength"]   { oscillatorConfig.chochSwingLength = Int(v.doubleValue) }
            if let v = p["minSwingPct"]   { oscillatorConfig.chochMinSwingPct = v.doubleValue }
            if let v = p["showOB"]        { oscillatorConfig.chochShowOB = v.boolValue }
            if let v = p["showFVG"]       { oscillatorConfig.chochShowFVG = v.boolValue }
            if let v = p["showIFVG"]      { oscillatorConfig.chochShowIFVG = v.boolValue }
            if let v = p["requireFVG"]    { oscillatorConfig.chochRequireFVG = v.boolValue }
            if let v = p["showMitigated"] { oscillatorConfig.chochShowMitigated = v.boolValue }
            if let v = p["notifyEvents"]  { oscillatorConfig.chochNotifyEvents = v.boolValue }
        case .volumeProfile:
            if let v = p["bucketCount"]  { oscillatorConfig.vpBucketCount = Int(v.doubleValue) }
            if let v = p["valueAreaPct"] { oscillatorConfig.vpValueAreaPct = v.doubleValue }
            if let v = p["useZigzag"]   { oscillatorConfig.vpUseZigzag = v.boolValue }
            if let v = p["showZigzag"]  { oscillatorConfig.vpShowZigzag = v.boolValue }
            if let v = p["zzDepth"]     { oscillatorConfig.vpZZDepth = Int(v.doubleValue) }
            if let v = p["zzMinChange"] { oscillatorConfig.vpZZMinChange = v.doubleValue }
        default:
            break // SMA/EMA/Bollinger — read from indicatorInstances, no config sync needed
        }
        oscillatorConfig.save()
    }

    /// Push an oscillator instance's params into `oscillatorConfig`
    /// so the global settings sheet and any config-dependent code stay
    /// in sync with the per-instance panel.
    private func syncOscillatorParamsToConfig(_ inst: OscillatorInstance) {
        let p = inst.params
        switch inst.kind {
        case .rsi:
            if let v = p["period"] { oscillatorConfig.rsiPeriod = Int(v.doubleValue) }
        case .macd:
            if let v = p["fast"]   { oscillatorConfig.macdFast = Int(v.doubleValue) }
            if let v = p["slow"]   { oscillatorConfig.macdSlow = Int(v.doubleValue) }
            if let v = p["signal"] { oscillatorConfig.macdSignal = Int(v.doubleValue) }
        case .stochastic:
            if let v = p["k"] { oscillatorConfig.stochK = Int(v.doubleValue) }
            if let v = p["d"] { oscillatorConfig.stochD = Int(v.doubleValue) }
        }
        oscillatorConfig.save()
    }

    /// Push `oscillatorConfig` values into all oscillator instances so
    /// OscillatorPanel picks up changes from the global settings sheet.
    private func syncConfigToOscillatorInstances() {
        for i in oscillatorInstances.indices {
            switch oscillatorInstances[i].kind {
            case .rsi:
                oscillatorInstances[i].params["period"] = .double(Double(oscillatorConfig.rsiPeriod))
            case .macd:
                oscillatorInstances[i].params["fast"]   = .double(Double(oscillatorConfig.macdFast))
                oscillatorInstances[i].params["slow"]   = .double(Double(oscillatorConfig.macdSlow))
                oscillatorInstances[i].params["signal"] = .double(Double(oscillatorConfig.macdSignal))
            case .stochastic:
                oscillatorInstances[i].params["k"] = .double(Double(oscillatorConfig.stochK))
                oscillatorInstances[i].params["d"] = .double(Double(oscillatorConfig.stochD))
            }
        }
        saveOscillators()
    }

    // ── Persistence ────────────────────────────────────────────────

    private func loadIndicators() {
        if let data = UserDefaults.standard.data(forKey: Self.indicatorStorageKey),
           let decoded = try? JSONDecoder().decode([IndicatorInstance].self, from: data) {
            indicatorInstances = decoded
        }
    }

    private func saveIndicators() {
        if let data = try? JSONEncoder().encode(indicatorInstances) {
            UserDefaults.standard.set(data, forKey: Self.indicatorStorageKey)
        }
    }

    private func loadOscillators() {
        if let data = UserDefaults.standard.data(forKey: Self.oscillatorStorageKey),
           let decoded = try? JSONDecoder().decode([OscillatorInstance].self, from: data) {
            oscillatorInstances = decoded
        }
    }

    private func saveOscillators() {
        if let data = try? JSONEncoder().encode(oscillatorInstances) {
            UserDefaults.standard.set(data, forKey: Self.oscillatorStorageKey)
        }
    }

    /// The chart style to render. 1m used to be forced to line (candles at
    /// minute granularity can read like a wall of toothpicks), but the user
    /// can now pick candlesticks on every timeframe, 1m included — we just
    /// honour their choice.
    private var effectiveChartType: ChartType {
        userChartType
    }

    // ── Grid fullscreen pane sync ─────────────────────────────────
    //
    // When a grid pane goes fullscreen, the toolbar at the top of the
    // screen binds to the DashboardView's @AppStorage state. The pane's
    // chart, however, reads from its own per-pane ChartPane struct.
    // These helpers bridge the gap: on fullscreen entry we copy the
    // pane's state → dashboard; on each toolbar change we write back
    // dashboard → pane.

    /// Write a single value to the current fullscreen pane. Returns
    /// `true` if a pane was updated (callers can use this to skip
    /// dashboard-specific work when the change is pane-owned).
    @discardableResult
    private func syncToFullscreenPane<T: Equatable>(
        _ keyPath: WritableKeyPath<ChartPane, T>,
        _ value: T
    ) -> Bool {
        guard let fsID = multiChart.fullscreenPaneID,
              let pane = multiChart.panes.first(where: { $0.id == fsID }),
              pane[keyPath: keyPath] != value
        else { return false }
        var p = pane
        p[keyPath: keyPath] = value
        multiChart.updatePane(p)
        return true
    }

    /// Push the dashboard's indicator instances to the fullscreen pane.
    private func syncIndicatorsToFullscreenPane() {
        guard let fsID = multiChart.fullscreenPaneID,
              let pane = multiChart.panes.first(where: { $0.id == fsID }),
              pane.indicatorInstances != indicatorInstances
        else { return }
        var p = pane
        p.indicatorInstances = indicatorInstances
        multiChart.updatePane(p)
    }

    /// Push the dashboard's oscillator instances to the fullscreen pane.
    private func syncOscillatorsToFullscreenPane() {
        guard let fsID = multiChart.fullscreenPaneID,
              let pane = multiChart.panes.first(where: { $0.id == fsID }),
              pane.oscillatorInstances != oscillatorInstances
        else { return }
        var p = pane
        p.oscillatorInstances = oscillatorInstances
        multiChart.updatePane(p)
    }

    var body: some View {
        let pair = app.pairs.first(where: { $0.id == app.selectedPairID })

        // Wrap the dashboard content in a ZStack so the AI analysis
        // page can overlay on top when the user hits Analyze. Keeping
        // the dashboard mounted underneath preserves its @State (pan
        // window, drawing selection, armed tool, …) across the
        // transition — switching it out at the RootView level would
        // drop all of that on the floor.
        ZStack {
            // No ScrollView: the dashboard is intentionally a single
            // screen that fills the window. The chart card expands to
            // consume any vertical space left over after the
            // (fixed-height) pair header, volume strip, oscillator
            // panels, and stats row. Resize the window and the chart
            // breathes accordingly — nothing scrolls.
            VStack(spacing: isChartFull ? 0 : Theme.Spacing.lg) {
                if let pair = pair {
                    // In maximised mode, hide the pair header so the
                    // chart card can stretch even further. The AI page
                    // is opened via a button on the chart header
                    // regardless of mode.
                    if !isChartFull {
                        // Grid mode stacks two full-height pane rows below
                        // this, which can demand more vertical space than
                        // the window has. Without pinning the header to its
                        // intrinsic size, the VStack's flexible distribution
                        // starves it first (it's the only child with no
                        // minHeight), squashing it down to a sliver that
                        // Card's `.clipShape` then crops — see the "top of
                        // the dashboard is clipped" grid-mode bug. Pin it so
                        // any leftover overflow lands on the grid instead,
                        // which degrades far more gracefully.
                        pairHeader(pair)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                    }
                    // Both views stay mounted at all times — the inactive
                    // one collapses to zero frame + zero opacity instead of
                    // being torn down. Same trick ChartGridView uses for its
                    // internal pane slots. This eliminates the expensive
                    // teardown/rebuild cycle (destroying ChartView's
                    // @StateObject cache + all @State, then building fresh
                    // ChartPaneViews that reload candles from GRDB) that the
                    // old if/else caused on every single↔grid switch.
                    let showsSingle = multiChart.layout == .single
                    ZStack {
                        chartCard(pair)
                            .frame(maxWidth: showsSingle ? .infinity : 0,
                                   maxHeight: showsSingle ? .infinity : 0)
                            .opacity(showsSingle ? 1 : 0)
                            .allowsHitTesting(showsSingle)
                        ChartGridView(layoutStore: multiChart, indicatorConfig: oscillatorConfig, drawingStore: drawingStore, activeDrawingTool: $activeDrawingTool) {
                            gridFullscreenToolbar
                        }
                            .frame(maxWidth: showsSingle ? 0 : .infinity,
                                   maxHeight: showsSingle ? 0 : .infinity)
                            .opacity(showsSingle ? 0 : 1)
                            .allowsHitTesting(!showsSingle)
                    }
                .clipped()
                // Right-click context menu — same options as the grid
                // pane's context menu, adapted for the single chart's
                // state model. Plus Scroll to Latest and Reset Chart.
                .contextMenu {
                    chartContextMenu(pair: pair)
                }
                    .animation(.easeInOut(duration: 0.25), value: multiChart.layout)
                } else {
                    emptyState
                }
            }
            // Zero padding in fullscreen: chart edges align with the
            // window edges so the chart truly fills the area. No local
            // `.animation(value: isChartFull)` here — `RootView`'s HStack
            // already applies one keyed on the same flag, and nesting a
            // second implicit-animation transaction around this (heavy)
            // chart subtree just doubles the layout-thrash during the
            // transition. Let the outer one drive it.
            .padding(isChartFull ? 0 : Theme.Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Analysis page stays mounted when closed — same
            // frame/opacity collapse trick as the chart/grid switch.
            // Tearing it down dropped its @State (running engine,
            // accumulated markdown) on every close.
            let showAnalysis = app.showAnalysisFullPage && pair != nil
            if let pair = pair {
                AnalysisPage(
                    pair: pair,
                    timeframe: timeframe,
                    candles: candles,
                    livePrice: pair.usesLiveStream
                               ? yahoo.latestPrices[pair.id]
                               : pair.price,
                    loadCandles: { tf in
                        await MainActor.run { candles(for: tf) }
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
                    onRestoreSRLevels:      { srLevels = $0 },
                    onRestoreFVGZones:      { fvgZones = $0 },
                    onRestoreSupplyDemand:  { supplyDemandZones = $0 },
                    onRestoreTAScenario:    { taScenario = $0 },
                    onRestoreTAAltScenario: { taAltScenario = $0 }
                )
                .environmentObject(analysisStore)
                .frame(maxWidth: showAnalysis ? .infinity : 0,
                       maxHeight: showAnalysis ? .infinity : 0)
                .opacity(showAnalysis ? 1 : 0)
                .allowsHitTesting(showAnalysis)
            }
        }
        .background(Theme.Color.canvas)
        .task(id: app.selectedPairID) {
            replay.exit()   // a replay anchored on the old pair's bars makes no sense here
            xDomain = nil   // new pair ⇒ drop any pinned window
            yDomain = nil   // …and any manual price scale
            if app.journalChartEntry?.pairID != app.selectedPairID { app.journalChartEntry = nil }
            srLevels = .init(support: [], resistance: [])  // overlays are per-pair
            fvgZones = []
            supplyDemandZones = []
            taScenario = nil
            taAltScenario = nil
            selectedDrawingID = nil   // drawing belonged to the prior pair
            await reloadCandles()
            warmHistory()   // backfill deep history for this pair (skeleton while it loads)
        }
        .task(id: app.notificationChartTarget?.id) {
            guard let target = app.notificationChartTarget,
                  target.pairID == app.selectedPairID,
                  let targetTimeframe = Timeframe(rawValue: target.timeframeRawValue)
            else { return }
            if timeframe != targetTimeframe {
                timeframe = targetTimeframe
            }
            await reloadCandles()
            focusChart(on: target)
        }
        // Wire the AutoTraderEngine's headless candle loader once
        // the dashboard mounts. The engine needs this to fire
        // Confluence Trade Scanner after a trade closes without the user opening
        // the analysis page.
        .task {
            loadIndicators()
            loadOscillators()
            alertStore.attach(inbox: notificationInbox)
            alertStore.timeframeLabel = timeframe.rawValue
            autoTrader.candleLoader = { [weak app = self.app] pairID, tf in
                guard app != nil else { return [] }
                // Always live — the live trading engine must never see
                // the foreground replay cursor's clipped history.
                return await MainActor.run { candles(for: pairID, tf: tf, ignoreReplay: true) }
            }
            // Continuous-mode validation needs a fresh live price
            // to compare against the staged scenario's entry / TP /
            // SL. Read from YahooScheduler — already the source for
            // every header + chart.
            autoTrader.livePriceProvider = { [weak yahoo = self.yahoo] pairID in
                yahoo?.latestPrices[pairID]
            }
        }
        .onChange(of: timeframe) { newValue in
            // Sync to fullscreen grid pane if active — the pane's
            // .task(id:) handles its own candle reload.
            if syncToFullscreenPane(\.timeframe, newValue) { return }
            xDomain = nil   // different bucket size ⇒ refit to data
            yDomain = nil   // drop the manual price scale too
            alertStore.timeframeLabel = newValue.rawValue
            warmHistory()   // ensure deep series is filled, then reloads candles
        }
        .onChange(of: userChartType) { newValue in
            _ = syncToFullscreenPane(\.chartType, newValue)
        }
        .onChange(of: indicatorInstances) { _ in
            syncIndicatorsToFullscreenPane()
        }
        .onChange(of: oscillatorInstances) { _ in
            syncOscillatorsToFullscreenPane()
        }
        .onChange(of: showVolume) { newValue in
            _ = syncToFullscreenPane(\.showVolume, newValue)
        }
        // When a grid pane goes fullscreen, copy its state to the
        // dashboard's @AppStorage so the toolbar controls reflect
        // the pane's current settings. (Grid fullscreen toolbar
        // binding fix.)
        .onChange(of: multiChart.fullscreenPaneID) { fsID in
            guard let fsID,
                  let pane = multiChart.panes.first(where: { $0.id == fsID })
            else { return }
            timeframe = pane.timeframe
            userChartType = pane.chartType
            indicatorInstances = pane.indicatorInstances
            oscillatorInstances = pane.oscillatorInstances
            showVolume = pane.showVolume
        }
        // Cache totalVolume so the O(n) candle iteration only runs
        // when candles change, not on every pan/zoom frame.
        .onChange(of: candles.count) { _ in recomputeTotalVolume() }
        // Infinite scroll: when the user pans within a few bars of the
        // oldest stored candle, pull an older page from Twelve Data
        // (Yahoo caps 1m/5m at ~8d/~60d) and splice it onto the front.
        // Prepended bars shift every existing index up, so we slide
        // `xDomain` by the same amount to keep the view visually still.
        .onChange(of: xDomain) { newValue in
            guard let dom = newValue, dom.lowerBound < 8 else { return }
            guard let pairID = app.selectedPairID,
                  let cur = app.pairs.first(where: { $0.id == pairID }),
                  cur.usesLiveStream,            // only Twelve Data pairs have a REST history feed
                  !replay.isActive               // don't yank a frozen replay view
            else { return }
            let srcTF = sourceTimeframeTag(for: timeframe)
            guard srcTF == "1m" || srcTF == "5m" else { return }
            Task {
                let added = await yahoo.loadOlderHistory(pairID: pairID, sourceTF: srcTF)
                guard added > 0 else { return }
                let prior = candles.count
                await reloadCandles()
                let shift = Double(candles.count - prior)
                if shift > 0, let pinned = xDomain {
                    xDomain = (pinned.lowerBound + shift) ... (pinned.upperBound + shift)
                }
            }
        }
        .sheet(isPresented: $showAlertSheet) {
            if let cur = pair {
                AlertSheet(
                    pairID: cur.id,
                    pairName: cur.name,
                    livePrice: cur.usesLiveStream
                               ? yahoo.latestPrices[cur.id]
                               : cur.price,
                    onCreate: { alert in alertStore.add(alert) }
                )
                // Inject the store into the sheet's environment
                // so the new "current alerts" list can read +
                // mutate it (toggle / re-arm / delete).
                .environmentObject(alertStore)
            }
        }
        .sheet(isPresented: $showIndicatorSettings) {
            // Persist on dismiss so the user's choice survives a relaunch
            // even if they close via clicking the backdrop / hitting Esc.
            oscillatorConfig.save()
            settingsFocusSection = nil
        } content: {
            IndicatorSettingsSheet(config: $oscillatorConfig,
                                   focusSection: settingsFocusSection)
        }
        .sheet(item: $profileSheet) { mode in
            strategyProfileSheet(for: mode)
        }
        .onReceive(
            // Throttle: cTrader's bridge can drive `lastUpdateAt` at
            // 5 Hz (or whatever the scheduler's flush rate is). Each
            // tick splices the trailing window onto `candles` and
            // rebuilds the chart's scene graph for the visible window.
            // At 5 Hz that was pinning the main thread; 1 Hz is the
            // visual ceiling for noticeable candle wiggle anyway — the
            // live price tag in the header updates separately at the
            // scheduler's full cadence because it reads
            // `yahoo.latestPrices[…]`, which isn't gated by this throttle.
            yahoo.$lastUpdateAt
                .compactMap { $0 }
                .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
        ) { _ in
            if let cur = app.pairs.first(where: { $0.id == app.selectedPairID }),
               cur.usesLiveStream,
               !replay.isActive   // live ticks must not disturb a frozen replay view
            {
                Task { await refreshTrailingCandles() }
            }
        }
        // Paper-trade evaluator: any live-stream pair's price tick
        // (metal + crypto) gets pushed into TradeStore so pending
        // trades can fill and active trades can hit TP / SL on the
        // right pair. Iran pairs evaluate on the FetchScheduler tick
        // below.
        .onReceive(yahoo.$latestPrices) { prices in
            for (pairID, price) in prices {
                tradeStore.evaluate(price: price, for: pairID)
                alertStore.evaluate(price: price, for: pairID)
            }
        }
        // Gold data source changed in Settings: the scheduler has wiped
        // the ounce bars and refetched from the new feed, then bumped this
        // token. The cheap trailing splice can't represent a wholesale
        // clear, so do a full reload to drop the old source's candles.
        .onChange(of: yahoo.dataResetToken) { _ in
            Task { await reloadCandles() }
        }
        // Auto-create entry + SL alerts when a scenario lands on
        // the chart. Sync removes them when the scenario clears
        // (or replaces them when a new one comes in).
        .onChange(of: taScenario) { scenario in
            syncScenarioAlerts(scenario, suffix: "(main)")
        }
        .onChange(of: taAltScenario) { scenario in
            syncScenarioAlerts(scenario, suffix: "(alt)")
        }
        // NY Open Setup → entry/SL alerts, mirroring the AI-scenario
        // alert sync. Only fires when the plan actually changes, so a
        // fired entry alert isn't re-armed every bar.
        .onChange(of: nyLiveScenario) { scenario in
            syncScenarioAlerts(scenario, suffix: "(NY setup)")
        }
        // Re-detect the setup when a new 1-minute bar closes (count
        // grows), the indicator is toggled, or its tuning changes. The
        // intrabar last-bar updates (same count) don't re-detect — the
        // already-registered alerts fire on price touch via the tick
        // evaluator above.
        .onChange(of: candles.count) { _ in refreshNYSetupScenario() }
        .onChange(of: candles.last?.id) { _ in
            refreshMicroMapNotifications(seedOnly: false)
            refreshSP2LNotifications(seedOnly: false)
            refreshPinBarNotifications(seedOnly: false)
            refreshMTRNotifications(seedOnly: false)
        }
        .onChange(of: indicatorInstances) { _ in
            refreshNYSetupScenario()
            refreshMicroMapNotifications(seedOnly: true)
            refreshSP2LNotifications(seedOnly: true)
            refreshPinBarNotifications(seedOnly: true)
            refreshMTRNotifications(seedOnly: true)
        }
        .onChange(of: oscillatorConfig) { _ in
            refreshNYSetupScenario()
            syncConfigToOscillatorInstances()
            refreshMicroMapNotifications(seedOnly: true)
            refreshSP2LNotifications(seedOnly: true)
            refreshPinBarNotifications(seedOnly: true)
            refreshMTRNotifications(seedOnly: true)
        }
        .onChange(of: strategyNotificationsEnabled) { enabled in
            refreshMicroMapNotifications(seedOnly: enabled)
            refreshSP2LNotifications(seedOnly: enabled)
            refreshPinBarNotifications(seedOnly: enabled)
            refreshMTRNotifications(seedOnly: enabled)
        }
        // Activation sheet — driven by `pendingActivation` so the
        // analysis sheet can dismiss first and this one presents on
        // the next render (SwiftUI is fussy about back-to-back modal
        // transitions).
        .sheet(item: $pendingActivation) { pending in
            if let pair = pair {
                ActivateTradeSheet(
                    scenario: pending.scenario,
                    pairID: pair.id,
                    livePrice: pair.usesLiveStream
                               ? yahoo.latestPrices[pair.id]
                               : pair.price,
                    sourceHistoryEntryID: pending.sourceHistoryEntryID,
                    onActivate: { trade in
                        tradeStore.add(trade, for: pair.id)
                    }
                )
            }
        }
        // Outcome observer — whenever the trade store mutates, scan
        // for newly-terminal trades that carry a source history
        // entry ID and stamp the outcome back onto the entry. The
        // diff vs `previouslyClosedTradeIDs` ensures we only record
        // the *first* terminal observation per trade, so re-renders
        // don't double-count wins/losses.
        .onReceive(tradeStore.$byPair) { byPair in
            for (_, trades) in byPair {
                for trade in trades {
                    guard let entryID = trade.sourceHistoryEntryID,
                          trade.isClosed,
                          !recordedOutcomeTradeIDs.contains(trade.id)
                    else { continue }
                    let outcome: AnalysisStore.Outcome
                    switch trade.status {
                    case .closedHitTP:    outcome = .hitTP
                    case .closedHitSL:    outcome = .hitSL
                    case .closedManually: outcome = .manual
                    case .cancelled:      outcome = .cancelled
                    case .pending, .active: continue
                    }
                    // currentPL on a closed trade already uses the
                    // frozen closePrice/fillPrice — no need to pass
                    // the live price.
                    let pl: Double? = trade.closePrice.map { trade.currentPL(at: $0) }
                    analysisStore.recordOutcome(
                        entryID: entryID,
                        outcome: outcome,
                        realisedPL: pl,
                        at: trade.closedAt ?? Date()
                    )
                    recordedOutcomeTradeIDs.insert(trade.id)
                }
            }
        }
    }

    // ── Pair header ────────────────────────────────────────────────
    private func pairHeader(_ pair: TradingPair) -> some View {
        Card(padding: Theme.Spacing.lg) {
            HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                ZStack {
                    Circle().fill(pair.color.opacity(0.18))
                    Circle().strokeBorder(pair.color.opacity(0.55), lineWidth: 1.5)
                    Text(String(pair.symbol.prefix(2)))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(pair.color)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pair.name)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.Color.textPrimary)
                    Text(pair.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Color.textMuted)
                }

                Spacer()

                layoutPickerButton(pair)

                fetchTimer(for: pair)

                refreshButton

                VStack(alignment: .trailing, spacing: 2) {
                    Text(displayedPrice(pair))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.Color.textPrimary)
                        .monospacedDigit()
                    Text(formatChange(pair))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(pair.changePercent >= 0
                                          ? Theme.Color.success
                                          : Theme.Color.danger)
                        .monospacedDigit()
                }
            }
        }
    }

    /// Live countdown chip. Picks which scheduler's timestamps to display
    /// based on the pair: metal + crypto read from YahooScheduler;
    /// Iran pairs read from FetchScheduler. Two separate fetch
    /// cadences = two possible timers; only the one driving the
    /// visible pair is shown.
    @ViewBuilder
    private func fetchTimer(for pair: TradingPair) -> some View {
        FetchTimerView(
            lastFetchAt: yahoo.lastUpdateAt,
            intervalSeconds: yahoo.tickIntervalSeconds,
            isFetching: yahoo.isFetching
        )
    }

    /// Split-screen layout picker: switches the chart area between the
    /// full-featured single chart (drawings, AI overlays, trades,
    /// replay) and a 2/4-pane grid of independent, lightweight charts
    /// (`ChartGridView`). Picking a non-single layout seeds any new
    /// panes from the current pair. Stays visible regardless of which
    /// mode is active — it's the only way back to `.single`.
    private func layoutPickerButton(_ pair: TradingPair) -> some View {
        Menu {
            ForEach(ChartLayoutKind.allCases) { layout in
                Button {
                    // Defensive: a pane could be mid-fullscreen (which
                    // drives this same flag) when the user jumps
                    // straight to a different layout from the menu —
                    // always land in a clean, non-fullscreen state.
                    app.isChartFullscreen = false
                    multiChart.setLayout(layout, defaultPairID: pair.id)
                } label: {
                    Label(layout.label, systemImage: multiChart.layout == layout
                          ? "checkmark.circle.fill" : layout.icon)
                }
            }
            if multiChart.layout != .single {
                Divider()
                Toggle("Sync symbol across panes", isOn: $multiChart.syncSymbol)
            }
        } label: {
            Image(systemName: multiChart.layout.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 32, height: 32)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Chart layout")
    }

    /// Manual refresh — kicks the Yahoo scheduler to fetch a fresh
    /// bar. Live-stream pairs auto-update at the scheduler's own
    /// cadence; this just lets the user force a tick without
    /// waiting.
    private var refreshButton: some View {
        Button {
            Task { await reloadCandles() }
        } label: {
            if yahoo.isFetching {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 32, height: 32)
            }
        }
        .buttonStyle(.plain)
        .disabled(yahoo.isFetching)
    }

    // ── Chart card ─────────────────────────────────────────────────
    @ViewBuilder
    private func chartCard(_ pair: TradingPair) -> some View {
        // A single, unconditional `Card` call — fullscreen is expressed
        // as a value change (chromeless + smaller padding), not by
        // switching between `Card { X }` and bare `X` in an `if/else`.
        // The latter would make SwiftUI tear down and rebuild
        // `chartCardContent`'s `ChartView` (and its `ChartDerivedCache`)
        // on every fullscreen toggle — see `Card.chromeless`.
        Card(padding: isChartFull ? Theme.Spacing.md : Theme.Spacing.xl, chromeless: isChartFull) {
            chartCardContent(pair)
        }
    }

    private func chartCardContent(_ pair: TradingPair) -> some View {
        VStack(spacing: Theme.Spacing.lg) {
            autoTraderStatusBanner(pair: pair)
            HStack(spacing: Theme.Spacing.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Price chart")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.Color.textPrimary)
                        HStack(spacing: 6) {
                            if !candles.isEmpty {
                                Text("\(candles.count) candles · \(timeframe.label)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.Color.textMuted)
                            }
                            TimeframeCountdown(timeframe: timeframe)
                        }
                    }
                    Spacer()
                    // Toolbar groups: actions · overlays/tools · format.
                    // Zoom + reset + maximise moved out — they live on
                    // the chart itself as a floating FAB now, freeing
                    // the toolbar to be just selection + format.
                    HStack(spacing: 6) {
                        analyzeButton
                        replayButton
                        alertButton
                        riskCalcButton
                        autoTraderPill
                        toolbarDivider
                        indicatorMenu
                        indicatorSettingsButton
                        layersButton
                        drawingToolbar
                        toolbarDivider
                        ChartTypeToggle(
                            selected: $userChartType,
                            isDisabled: false
                        )
                        TimeframeSelector(selected: $timeframe)
                        toolbarDivider
                        debugButton
                        singleChartFullscreenButton
                    }
                }

                ChartView(
                    candles: candles,
                    chartType: effectiveChartType,
                    accent: pair.color,
                    xDomain: $xDomain,
                    yDomain: $yDomain,
                    indicators: Set(visibleIndicatorInstances.map(\.kind)),
                    indicatorConfig: oscillatorConfig,
                    indicatorInstances: visibleIndicatorInstances,
                    srLevels: srVisible ? srLevels : .init(support: [], resistance: []),
                    fvgZones: fvgVisible ? fvgZones : [],
                    supplyDemandZones: supplyDemandVisible ? supplyDemandZones : [],
                    taScenario: scenarioVisible ? taScenario : nil,
                    taAltScenario: altScenarioVisible ? taAltScenario : nil,
                    drawings: drawingStore.drawings(for: pair.id),
                    activeTool: activeDrawingTool,
                    onCommitDrawing: { drawing in
                        drawingStore.add(drawing, for: pair.id)
                        // TradingView-style: after a successful draw,
                        // drop back to cursor so the next click doesn't
                        // accidentally start another shape. The user
                        // can re-arm the same tool from the toolbar if
                        // they want a string of drawings.
                        activeDrawingTool = .none
                        // Auto-select the freshly drawn shape so the
                        // user can immediately tweak its color / line
                        // width without hunting for it.
                        selectedDrawingID = drawing.id
                    },
                    onMoveDrawing: { drawing in
                        // Same id ⇒ in-place replacement, no
                        // duplication and no churn in the Layers
                        // popover ordering.
                        drawingStore.update(drawing, for: pair.id)
                    },
                    selectedDrawingID: selectedDrawingID,
                    onSelectDrawing: { id in
                        selectedDrawingID = id
                    },
                    // Open trades render as entry/TP/SL rules with a
                    // fill marker. Closed trades stay in the store
                    // (Layers popover history) but the chart drops
                    // them — keeps active runs uncluttered.
                    trades: tradeStore.openVisibleTrades(for: pair.id),
                    // Journal overlay — show the pinned entry's
                    // entry/TP/SL lines when the user hit "Show on
                    // chart" from JournalView. Scoped to the pair
                    // so switching to a different pair hides it.
                    journalEntries: {
                        guard let je = app.journalChartEntry,
                              je.pairID == pair.id else { return [] }
                        return [je]
                    }(),
                    notificationFocus: {
                        guard let target = app.notificationChartTarget,
                              target.pairID == pair.id,
                              target.timeframeRawValue == timeframe.rawValue
                        else { return nil }
                        return target
                    }(),
                    // Suppress the live-price patch during replay — the
                    // last revealed bar is historical, not "now".
                    livePrice: replay.isActive
                               ? nil
                               : (pair.usesLiveStream ? yahoo.latestPrices[pair.id] : pair.price),
                    replayActive: replay.isActive && replay.cursor != nil,
                    isPickingReplayAnchor: replay.isActive && replay.isPickingAnchor,
                    onPickReplayAnchor: { idx in
                        guard idx >= 0, idx < candles.count else { return }
                        replay.setAnchor(candles[idx].bucketStart)
                        xDomain = nil   // refit to the revealed window
                        Task { await reloadCandles() }
                    }
                )
                // Chart expands to consume any vertical space the
                // siblings below (volume / oscillators / stats) don't
                // claim — `minHeight` guards against the chart being
                // crushed when the window is short.
                .frame(minHeight: 220, maxHeight: .infinity)
                .padding(.trailing, Theme.Spacing.sm) // breathing room on the right
                // Mouse-wheel / two-finger trackpad scroll zooms the
                // chart, anchored on the cursor's X position. Attached
                // before `.clipped()` so the modifier's GeometryReader
                // sees the chart's actual frame in global coords.
                .scrollZoom(xDomain: $xDomain, totalCandles: candles.count)
                // Delete selected drawing on Backspace/Forward-Delete.
                .drawingDeleteKey(selectedDrawingID: $selectedDrawingID, drawingStore: drawingStore, pairID: pair.id)
                // Belt-and-braces clip at the layout container so any
                // mark Apple Charts renders past the chart frame still
                // can't leak past the card content. The price tag now
                // sits inside the plot area (overlay-position annotation)
                // so it's safe to clip here.
                .clipped()
                // TradingView-style indicator legend — top-left of chart.
                // Shows every active indicator/oscillator with a per-item
                // gear button. Applied after .clipped() so it floats freely.
                .overlay(alignment: .topLeading) {
                    indicatorLegendOverlay
                        .padding(.top, 6)
                        .padding(.leading, 8)
                }
                // Floating chart controls — zoom in/out, reset zoom,
                // maximise. Lives ON the chart (bottom-right) rather
                // than in the top toolbar so the toolbar stays tight
                // and these controls feel contextual to the chart they
                // act on. Applied AFTER `.clipped()` so the fan-out
                // children animate freely without being chopped.
                .overlay(alignment: .bottomTrailing) {
                    ChartControlsFAB(
                        isFullscreen: $app.isChartFullscreen,
                        onZoomIn: { zoom(by: 0.7) },
                        onZoomOut: { zoom(by: 1.4) },
                        onReset: { resetChart() }
                    )
                    .padding(.trailing, Theme.Spacing.md)
                    .padding(.bottom, Theme.Spacing.md)
                }
                // MetaTrader-style "scroll to latest" puck. Surfaces in
                // the bottom-left only when the user has panned/zoomed
                // back off the newest bar; tapping slides the window
                // forward to the latest candle keeping the zoom level.
                // Bottom-left keeps it clear of the controls FAB
                // (bottom-right) and the replay transport (bottom-center).
                .overlay(alignment: .bottomLeading) {
                    if !isViewingLatest {
                        Button { scrollToLatest() } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Theme.accentGradient))
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                                .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                        .help("Scroll to latest")
                        .padding(.leading, Theme.Spacing.md)
                        .padding(.bottom, Theme.Spacing.md)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: isViewingLatest)
                // Replay transport — floats bottom-center while replay
                // is active. Picking phase shows a hint; once anchored
                // it's play/pause/step/speed + the cursor clock.
                .overlay(alignment: .bottom) {
                    replayControlBar
                        .padding(.bottom, Theme.Spacing.md)
                }
                // History backfill feedback. With no candles yet (e.g.
                // switching to d1 before its native series has landed),
                // cover the plot with a skeleton; once some bars are
                // showing, drop to an unobtrusive top pill so the
                // partial chart stays readable while deeper history
                // fills in behind it.
                .overlay {
                    if isBackfillingCurrentTF && candles.isEmpty {
                        ChartSkeleton()
                            .padding(Theme.Spacing.sm)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .top) {
                    if isBackfillingCurrentTF && !candles.isEmpty {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Loading full history…")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.Color.textSecondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.Color.surface))
                        .padding(.top, Theme.Spacing.sm)
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isBackfillingCurrentTF)
                // When a backfill (bootstrap or on-demand) finishes for
                // any series, refresh so the freshly-stored history shows
                // up immediately rather than at the next periodic tick.
                .onChange(of: yahoo.backfilling) { _ in
                    Task { await reloadCandles() }
                }
                // Drive auto-play: the controller's timer bumps `tick`;
                // each increment advances the cursor one bar. Stop at
                // the end of stored data.
                .onChange(of: replay.tick) { _ in
                    if !advanceReplay() { replay.pause() }
                }
                // Keep the AI store's back-test anchor in lockstep with
                // the cursor so analyses launched in replay carry the
                // "treat this as now" preamble.
                .onChange(of: replay.cursor) { newValue in
                    analysisStore.replayAsOf = replay.isActive ? newValue : nil
                }
                .onChange(of: replay.isActive) { active in
                    analysisStore.replayAsOf = active ? replay.cursor : nil
                }
                // Seed the date-jump picker with the current cursor (or
                // now) each time the picking phase opens, so it starts
                // somewhere sensible.
                .onChange(of: replay.isPickingAnchor) { picking in
                    if picking { replayPickerDate = replay.cursor ?? Date() }
                }
                // Inspector for the currently-selected drawing. Floats
                // at the top-trailing of the chart so it doesn't fight
                // with the bottom-right FAB or the candles themselves.
                // Driven entirely by `selectedDrawingID` + the per-pair
                // store; clicking elsewhere or hitting "✕" closes it.
                .overlay(alignment: .topTrailing) {
                    drawingInspector(pair: pair)
                        .padding(.trailing, Theme.Spacing.md)
                        .padding(.top, Theme.Spacing.md)
                }
                // Floating per-instance settings panel
                .overlay(alignment: .topLeading) {
                    if let id = editingIndicatorID,
                       let idx = indicatorInstances.firstIndex(where: { $0.id == id }) {
                        IndicatorSettingsPanel(
                            instance: Binding(
                                get: { indicatorInstances[idx] },
                                set: { updateIndicator($0) }
                            ),
                            onUpdate: { inst in updateIndicator(inst) },
                            onClose: { editingIndicatorID = nil }
                        )
                        .padding(.leading, Theme.Spacing.md)
                        .padding(.top, Theme.Spacing.md)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let id = editingOscillatorID,
                       let idx = oscillatorInstances.firstIndex(where: { $0.id == id }) {
                        OscillatorSettingsPanel(
                            instance: Binding(
                                get: { oscillatorInstances[idx] },
                                set: { updateOscillator($0) }
                            ),
                            onUpdate: { inst in updateOscillator(inst) },
                            onClose: { editingOscillatorID = nil }
                        )
                        .padding(.leading, Theme.Spacing.md)
                        .padding(.top, Theme.Spacing.md)
                    }
                }

                volumeStrip(pair)

                oscillatorPanels

                if !isChartFull {
                    statsRow(pair)
                }
            }
            // The card's inner VStack needs to fill its container
            // vertically so the chart's `maxHeight: .infinity` actually
            // has somewhere to grow into. Without this the VStack sizes
            // to its intrinsic content and the chart pins at minHeight.
            .frame(maxHeight: .infinity)
    }

    /// Stack of enabled oscillator sub-charts (RSI / MACD / Stoch). Each
    /// is hidden when not toggled on or when temporarily hidden via the
    /// Layers popover; rendered in declaration order so the layout
    /// stays stable as the user flips them.
    @ViewBuilder
    private var oscillatorPanels: some View {
        ForEach(visibleOscillatorInstances) { inst in
            OscillatorPanel(
                instance: inst,
                candles: candles,
                xDomain: xDomain
            )
            .padding(.trailing, Theme.Spacing.sm)
        }
    }

    /// Dropdown listing all available indicators with a Toggle for each.
    /// The button shows a count when something is active so you can tell
    /// at a glance whether the chart has overlays.
    private var indicatorMenu: some View {
        DashboardIndicatorMenu(
            showVolume: $showVolume,
            indicatorInstances: $indicatorInstances,
            oscillatorInstances: $oscillatorInstances,
            editingIndicatorID: $editingIndicatorID,
            editingOscillatorID: $editingOscillatorID,
            showIndicatorSettings: $showIndicatorSettings,
            srLevels: $srLevels,
            fvgZones: $fvgZones,
            taScenario: $taScenario,
            taAltScenario: $taAltScenario,
            pendingActivation: $pendingActivation,
            nyLiveScenario: nyLiveScenario,
            enabledIndicatorKinds: enabledIndicatorKinds,
            enabledOscillators: enabledOscillators,
            onToggleIndicatorHidden: { toggleIndicatorHidden(id: $0) },
            onRemoveIndicator: { removeIndicator(id: $0) },
            onAddIndicator: { addIndicator($0) },
            onToggleOscillatorHidden: { toggleOscillatorHidden(id: $0) },
            onRemoveOscillator: { removeOscillator(id: $0) },
            onAddOscillator: { addOscillator($0) },
            onSaveIndicators: { saveIndicators() },
            onSaveOscillators: { saveOscillators() }
        )
        .equatable()
    }

    /// Tooltip text for the `f(x)` button — surfaces the active count
    /// on hover so the dot badge isn't the only feedback.
    private func activeCount(label n: Int) -> String {
        n == 0 ? "Indicators" : "Indicators · \(n) active"
    }

    /// Gear button that opens the indicator settings sheet directly —
    /// no hunting through the f(x) menu's "Settings…" item.
    private var indicatorSettingsButton: some View {
        Button {
            settingsFocusSection = nil
            showIndicatorSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface)
                )
        }
        .buttonStyle(.plain)
        .help("Indicator settings")
    }

    /// TradingView-style indicator legend floating in the chart's top-right
    /// corner. Lists every active overlay and panel indicator with a gear
    /// button per row. Collapse/expand with the chevron.
    @ViewBuilder
    private var indicatorLegendOverlay: some View {
        let overlays = Array(enabledIndicatorKinds).sorted { $0.rawValue < $1.rawValue }
        let panels   = Array(enabledOscillators).sorted { $0.rawValue < $1.rawValue }
        guard !overlays.isEmpty || !panels.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 2) {
                // Collapse / expand toggle
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
                        ForEach(indicatorInstances) { inst in
                            legendInstanceRow(for: inst)
                        }
                        ForEach(oscillatorInstances) { inst in
                            legendOscillatorRow(for: inst)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        )
    }

    /// One row in the expanded indicator legend for an indicator instance.
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

            Button {
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
    }

    /// One row in the expanded indicator legend for an oscillator instance.
    private func legendOscillatorRow(for inst: OscillatorInstance) -> some View {
        HStack(spacing: 5) {
            Button {
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
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.Color.surface.opacity(0.75)))
    }

    /// Two-way binding into the oscillator set. Same pattern as
    /// `indicatorBinding` — keeps each Toggle in the menu wired without
    /// adding a Bool per kind.
    private func oscillatorBinding(_ kind: OscillatorKind) -> Binding<Bool> {
        Binding(
            get: { enabledOscillators.contains(kind) },
            set: { setOscillator(kind, enabled: $0) }
        )
    }

    /// Two-way binding into the indicator set for one specific kind. Lets
    /// each Toggle in the menu drive its own Bool without us hand-rolling
    /// a separate state property per indicator.
    private func indicatorBinding(_ kind: IndicatorKind) -> Binding<Bool> {
        Binding(
            get: { enabledIndicatorKinds.contains(kind) },
            set: { setIndicator(kind, enabled: $0) }
        )
    }

    /// Compact "stack" button that opens the Layers popover. Counts
    /// the currently-active drawable layers so the user can see at a
    /// glance whether there's anything to manage.
    /// Bug-icon button that opens the network debug sheet. Tints
    /// amber when capture is on (so it's visually obvious the app is
    /// recording every request), grey when capture is off. Mirrors
    /// the icon-only chip style of the indicator / layers buttons.
    private var debugButton: some View {
        Button {
            showDebugLogSheet = true
        } label: {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NetworkLog.shared.isEnabled
                                 ? Theme.Color.warn
                                 : Theme.Color.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface)
                )
        }
        .buttonStyle(.plain)
        .help(NetworkLog.shared.isEnabled
              ? "Network debug · capturing"
              : "Network debug")
        .sheet(isPresented: $showDebugLogSheet) {
            DebugLogSheet()
        }
    }

    /// Fullscreen toggle button for the single chart view. Mirrors
    /// the grid pane's fullscreen button (arrow icon). Toggles
    /// `app.isChartFullscreen` which hides the sidebar and pair
    /// header via RootView. (Single-chart fullscreen button feature.)
    private var singleChartFullscreenButton: some View {
        Button {
            app.isChartFullscreen.toggle()
        } label: {
            Image(systemName: isChartFull
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface)
                )
        }
        .buttonStyle(.plain)
        .help(isChartFull ? "Exit fullscreen" : "Fullscreen")
    }

    /// Thin vertical separator between toolbar groups. 1pt wide,
    /// muted color, capped to a height that matches the buttons so
    /// it doesn't crowd them. Kept here (rather than in `UI/`)
    /// because it's a private styling detail of this toolbar.
    private var toolbarDivider: some View {
        Rectangle()
            .fill(Theme.Color.border)
            .frame(width: 1, height: 16)
            .padding(.horizontal, 2)
    }

    private var layersButton: some View {
        let count = activeLayerCount
        return Button {
            showLayersPopover.toggle()
        } label: {
            // Icon-only with a dot badge — matches the `f(x)`
            // indicators button so the toolbar reads as a row of
            // consistent square chips.
            ZStack(alignment: .topTrailing) {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface)
                    )
                if count > 0 {
                    Circle()
                        .fill(Theme.accentGradient)
                        .frame(width: 9, height: 9)
                        .overlay(
                            Circle()
                                .strokeBorder(Theme.Color.surfaceHi, lineWidth: 1)
                        )
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .help(count == 0
              ? "Layers"
              : "Layers · \(count) on chart")
        .popover(isPresented: $showLayersPopover, arrowEdge: .top) {
            layersPopoverContent
                .padding(Theme.Spacing.lg)
                .frame(minWidth: 320, idealWidth: 360)
        }
    }

    /// Total drawable layers — used to badge the button. Counts each
    /// indicator/oscillator individually, plus volume / S/R / FVG /
    /// scenario as a single layer each. User drawings count one per
    /// shape so the badge accurately reflects what's on the chart.
    private var activeLayerCount: Int {
        var n = 0
        if showVolume { n += 1 }
        n += enabledIndicatorKinds.count
        n += enabledOscillators.count
        if !srLevels.isEmpty { n += 1 }
        if !fvgZones.isEmpty { n += 1 }
        if !supplyDemandZones.isEmpty { n += 1 }
        if taScenario != nil { n += 1 }
        n += drawingStore.drawings(for: app.selectedPairID ?? "").count
        return n
    }

    /// Body of the Layers popover. Lists every currently-drawable
    /// layer with two affordances:
    ///   • Eye toggle → flips hide/show (state preserved, chart skips
    ///     rendering).
    ///   • Trash icon → removes the layer entirely (clears underlying
    ///     state). Some layers (Volume) have no trash because they
    ///     aren't user-added — only toggleable.
    @ViewBuilder
    private var layersPopoverContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("LAYERS")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)

            if activeLayerCount == 0 {
                Text("Nothing on the chart yet. Add indicators or run an AI analysis to see layers here.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textMuted)
                    .padding(.vertical, Theme.Spacing.md)
            } else {
                // Volume — always near the top since it's a chart-wide
                // toggle the user reaches for often.
                layerRow(
                    title: "Volume",
                    swatch: Theme.Color.success,
                    visible: showVolume,
                    onToggle: { showVolume.toggle() },
                    onDelete: nil      // no trash — built-in option
                )

                // Indicator overlays (SMA/EMA/Bollinger/UT Bot).
                ForEach(IndicatorKind.allCases) { kind in
                    if enabledIndicatorKinds.contains(kind) {
                        layerRow(
                            title: kind.label,
                            swatch: kind.color,
                            visible: !hiddenIndicators.contains(kind),
                            onToggle: {
                                setIndicatorHidden(kind, hidden: !hiddenIndicators.contains(kind))
                            },
                            onDelete: { setIndicator(kind, enabled: false) }
                        )
                    }
                }

                // Panel oscillators (RSI/MACD/Stoch).
                ForEach(OscillatorKind.allCases) { kind in
                    if enabledOscillators.contains(kind) {
                        layerRow(
                            title: kind.label,
                            swatch: Theme.Color.info,
                            visible: !hiddenOscillators.contains(kind),
                            onToggle: {
                                setOscillatorHidden(kind, hidden: !hiddenOscillators.contains(kind))
                            },
                            onDelete: { setOscillator(kind, enabled: false) }
                        )
                    }
                }

                // AI overlays.
                if !srLevels.isEmpty {
                    layerRow(
                        title: "S/R lines · \(srLevels.support.count + srLevels.resistance.count)",
                        swatch: Theme.Color.success,
                        visible: srVisible,
                        onToggle: { srVisible.toggle() },
                        onDelete: { srLevels = .init(support: [], resistance: []) }
                    )
                }
                if !fvgZones.isEmpty {
                    layerRow(
                        title: "FVG zones · \(fvgZones.count)",
                        swatch: Theme.Color.warn,
                        visible: fvgVisible,
                        onToggle: { fvgVisible.toggle() },
                        onDelete: { fvgZones = [] }
                    )
                }
                if !supplyDemandZones.isEmpty {
                    let demand = supplyDemandZones.filter(\.isDemand).count
                    let supply = supplyDemandZones.count - demand
                    layerRow(
                        title: "S&D zones · \(demand)D / \(supply)S",
                        // Mixed-colour layer — pick the more
                        // prominent side for the swatch, which
                        // already reads as the dominant bias.
                        swatch: demand >= supply ? Theme.Color.success : Theme.Color.danger,
                        visible: supplyDemandVisible,
                        onToggle: { supplyDemandVisible.toggle() },
                        onDelete: { supplyDemandZones = [] }
                    )
                }
                if let main = taScenario {
                    layerRow(
                        title: "TA scenario · \(scenarioValidityLabel(main))",
                        swatch: Theme.Color.warn,
                        visible: scenarioVisible,
                        onToggle: { scenarioVisible.toggle() },
                        onDelete: { taScenario = nil }
                    )
                }
                if let alt = taAltScenario {
                    layerRow(
                        title: "Alt scenario · \(scenarioValidityLabel(alt))",
                        // Distinct (cooler) swatch so the row reads
                        // as "the other plan" rather than a duplicate.
                        swatch: Theme.Color.info,
                        visible: altScenarioVisible,
                        onToggle: { altScenarioVisible.toggle() },
                        onDelete: { taAltScenario = nil }
                    )
                }

                // User drawings — one row per shape so each can be
                // toggled or deleted individually. The store is keyed
                // by pair, so we only list drawings for the currently
                // selected pair.
                if let pairID = app.selectedPairID {
                    let pairDrawings = drawingStore.drawings(for: pairID)
                    ForEach(pairDrawings) { d in
                        layerRow(
                            title: drawingLayerTitle(d),
                            swatch: DrawingPalette.stroke,
                            visible: d.visible,
                            onToggle: {
                                drawingStore.setVisible(!d.visible, id: d.id, for: pairID)
                            },
                            onDelete: { drawingStore.remove(id: d.id, for: pairID) }
                        )
                    }
                }

                // Price alerts for this pair. Manual + scenario-
                // derived alerts share the same list; the row title
                // signals which is which via the kind icon.
                if let pairID = app.selectedPairID {
                    let pairAlerts = alertStore.alerts(for: pairID)
                    ForEach(pairAlerts) { alert in
                        alertLayerRow(alert)
                    }
                }

                // Paper trades — one row per trade with status +
                // live P/L (or frozen P/L for closed). Newest first
                // by reversing so the freshly-activated trade shows
                // up at the top of the section.
                if let pairID = app.selectedPairID {
                    let pairTrades = tradeStore.trades(for: pairID).reversed()
                    ForEach(Array(pairTrades), id: \.id) { t in
                        layerRow(
                            title: tradeLayerTitle(t, pairID: pairID),
                            swatch: t.colorSwatch,
                            visible: t.visible,
                            onToggle: {
                                tradeStore.setVisible(!t.visible, id: t.id, for: pairID)
                            },
                            onDelete: { tradeStore.remove(id: t.id, for: pairID) }
                        )
                    }
                }
            }
        }
    }

    /// One row in the Layers popover representing a price alert.
    /// Eye toggle re-arms a fired alert; trash deletes it. The
    /// title encodes the kind (cross direction / scenario entry /
    /// SL) so the user can tell at a glance whether a row is a
    /// manual alert vs one auto-installed by a scenario.
    private func alertLayerRow(_ alert: PriceAlert) -> some View {
        let title: String = {
            let prefix: String
            switch alert.kind {
            case .crossUp:        prefix = "Cross UP"
            case .crossDown:      prefix = "Cross DOWN"
            case .scenarioEntry:  prefix = "Scenario entry"
            case .scenarioSL:     prefix = "Scenario SL"
            case .rsiCrossAbove:  prefix = "RSI ↑"
            case .rsiCrossBelow:  prefix = "RSI ↓"
            }
            let status = alert.isArmed ? "armed" : (alert.enabled ? "fired" : "disabled")
            // RSI alerts show the threshold as an integer, not a
            // monetary value — `priceExact` would format 70 as
            // "70.0000" which reads weirdly.
            let levelStr = alert.isIndicatorAlert
                ? String(format: "%.0f", alert.level)
                : ChartView.priceExact(alert.level)
            return "\(prefix) @ \(levelStr) · \(status)"
        }()
        let swatch: Color = alert.isArmed ? Theme.Color.warn : Theme.Color.textMuted
        return layerRow(
            title: title,
            swatch: swatch,
            visible: alert.isArmed,
            onToggle: {
                if !alert.isArmed { alertStore.reArm(id: alert.id) }
                // Disarming an armed alert without deleting it
                // isn't a meaningful operation — the user can just
                // delete it. So the toggle only "re-arms" fired
                // alerts; toggling an armed alert is a no-op.
            },
            onDelete: { alertStore.remove(id: alert.id) }
        )
    }

    /// Compose the Layers row title for a trade. Always includes
    /// side / lots / status; appends a live P/L number for active
    /// trades and a frozen P/L for closed ones. Pending trades
    /// don't show P/L (there's nothing to compute yet).
    private func tradeLayerTitle(_ t: Trade, pairID: String) -> String {
        // Live-stream pairs (metal + crypto) read from the scheduler's
        // map; Iran pairs read from the snapshot-derived TradingPair.
        let pair = app.pairs.first(where: { $0.id == pairID })
        let livePrice: Double = pair?.usesLiveStream == true
            ? (yahoo.latestPrices[pairID] ?? t.entry)
            : (pair?.price ?? t.entry)
        // Special-case the "TP hit before fill" reason — it's a
        // distinct outcome (scenario invalidated, not user-cancelled)
        // and reads more clearly as "Invalidated (TP first)".
        let statusText: String = (t.status == .cancelled && t.closeReason == .invalidatedNoFill)
            ? "Invalidated (TP first)"
            : t.statusLabel
        let head = "\(t.side == .short ? "Short" : "Long") \(String(format: "%.2f", t.lots)) · \(statusText)"
        switch t.status {
        case .pending, .cancelled:
            return head
        case .active:
            let pl = t.currentPL(at: livePrice)
            return head + "  \(formatPL(pl))"
        case .closedHitTP, .closedHitSL, .closedManually:
            let pl = t.currentPL(at: livePrice)
            return head + "  \(formatPL(pl))"
        }
    }

    /// Tight P/L formatter — preserves sign, two decimals, $ prefix.
    private func formatPL(_ pl: Double) -> String {
        let sign = pl >= 0 ? "+" : "−"
        return "\(sign)$\(String(format: "%.2f", abs(pl)))"
    }

    /// Inspector floating panel — shown only when a drawing is
    /// selected. Lets the user retune the colour/alpha, the line
    /// width, and delete the drawing. Built as a `@ViewBuilder` so
    /// the empty case (no selection) compiles to nothing.
    @ViewBuilder
    private func drawingInspector(pair: TradingPair) -> some View {
        if let id = selectedDrawingID,
           let drawing = drawingStore.drawings(for: pair.id).first(where: { $0.id == id })
        {
            DrawingInspector(
                drawing: drawing,
                onChange: { updated in
                    drawingStore.update(updated, for: pair.id)
                },
                onDelete: {
                    drawingStore.remove(id: id, for: pair.id)
                    selectedDrawingID = nil
                },
                onDismiss: {
                    selectedDrawingID = nil
                }
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Pretty label for a user drawing in the Layers popover. Includes
    /// the price for horizontal lines so the user can tell them apart
    /// without hovering on the chart.
    private func drawingLayerTitle(_ d: ChartDrawing) -> String {
        switch d.kind {
        case .horizontalLine:
            return "Horizontal · \(ChartView.priceShort(d.start.price))"
        case .trendLine:
            return "Trend line"
        case .rectangle:
            return "Rectangle"
        case .volumeProfile:
            return "Vol Profile"
        }
    }

    /// One row in the Layers popover. Eye + name + swatch + (optional)
    /// trash. Hidden rows fade their label to signal the state.
    private func layerRow(
        title: String,
        swatch: Color,
        visible: Bool,
        onToggle: @escaping () -> Void,
        onDelete: (() -> Void)?
    ) -> some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: visible ? "eye.fill" : "eye.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(visible ? Theme.Color.textSecondary : Theme.Color.textMuted)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .help(visible ? "Hide" : "Show")

            RoundedRectangle(cornerRadius: 2)
                .fill(swatch)
                .frame(width: 8, height: 14)
                .opacity(visible ? 1 : 0.35)

            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(visible ? Theme.Color.textPrimary : Theme.Color.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if let onDelete = onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Color.textMuted)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Remove from chart")
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Theme.Color.surface)
        )
    }

    /// Flips into the full-window AnalysisPage overlay. The page renders
    /// as a ZStack overlay on top of the dashboard (see `body`), so
    /// chart state (pan/zoom, drawings, selected tool) survives the
    /// transition and the user lands back on the same chart on dismiss.
    /// Build the AUTO-enable strategy-profile picker. Snaps the
    /// per-pair config to the picked profile and enables the
    /// auto-trader on confirm.
    @ViewBuilder
    private func strategyProfileSheet(for mode: ProfileSheetMode) -> some View {
        let pairID = mode.pairID
        let cfg = autoTraderConfig.config(for: pairID)
        StrategyProfileSheet(
            title: "Enable auto-trader",
            subtitle: "Pick the strategy this pair will trade. You can switch profile any time in Settings.",
            currentProfile: cfg.strategyProfile,
            confirmLabel: "Enable",
            onPick: { profile in
                var c = cfg
                c.applyProfile(profile)
                c.enabled = true
                autoTraderConfig.update(c, for: pairID)
                profileSheet = nil
                autoTrader.kickstart(for: pairID)
            },
            onCancel: { profileSheet = nil }
        )
    }

    private var analyzeButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                app.showAnalysisFullPage = true
            }
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface)
                )
        }
        .buttonStyle(.plain)
        .help("AI analysis")
    }

    /// Toggles Replay mode. Off → arms the anchor-picking phase (next
    /// chart click sets the start bar). On → exits back to live data.
    private var replayButton: some View {
        let active = replay.isActive
        return Button {
            if active {
                replay.exit()
                xDomain = nil
                Task { await reloadCandles() }
            } else {
                replay.arm()
            }
        } label: {
            Image(systemName: "backward.end.alt.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Theme.Color.warn : Theme.Color.textSecondary)
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(active ? Theme.Color.warn.opacity(0.16) : Theme.Color.surface)
                )
        }
        .buttonStyle(.plain)
        .help(active
              ? "Exit replay"
              : "Replay — pick a start bar and step through history")
    }

    /// Selectable playback speeds. The interval is wall-clock seconds
    /// per revealed bar; the label is the human-facing multiplier.
    private static let replaySpeeds: [(label: String, interval: TimeInterval)] = [
        ("4×", 0.25), ("2×", 0.5), ("1×", 1.0), ("0.5×", 2.0),
    ]

    /// Clock label for the replay cursor — date + time so the user can
    /// see exactly where in history they are.
    private static let replayClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d  HH:mm"
        return f
    }()

    /// Floating transport shown while replay is active.
    @ViewBuilder
    private var replayControlBar: some View {
        if replay.isActive {
            HStack(spacing: 12) {
                if replay.isPickingAnchor {
                    Image(systemName: "cursorarrow.rays")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Color.warn)
                    Text("Click a bar, or jump to")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                    DatePicker(
                        "",
                        selection: $replayPickerDate,
                        in: replayDateRange(),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .fixedSize()
                    Button("Go") { jumpReplay(to: replayPickerDate) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Color.warn)
                        .help("Jump the replay start to this date")
                } else {
                    Button { replay.beginRepick() } label: {
                        Image(systemName: "calendar")
                    }
                    .buttonStyle(.plain)
                    .help("Jump to a different date")

                    Button { stepReplayBack() } label: {
                        Image(systemName: "backward.frame.fill")
                    }
                    .buttonStyle(.plain)
                    .help("Step back one bar")

                    Button { replay.togglePlay() } label: {
                        Image(systemName: replay.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 16)
                    }
                    .buttonStyle(.plain)
                    .help(replay.isPlaying ? "Pause" : "Play")

                    Button { _ = advanceReplay() } label: {
                        Image(systemName: "forward.frame.fill")
                    }
                    .buttonStyle(.plain)
                    .help("Step forward one bar")

                    replaySpeedMenu

                    if let c = replay.cursor {
                        Text(Self.replayClock.string(from: c))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                }

                Divider().frame(height: 14)

                Button {
                    replay.exit()
                    xDomain = nil
                    Task { await reloadCandles() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Exit replay")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.Color.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(Theme.Color.surfaceMax)
                    .overlay(Capsule().stroke(Theme.Color.warn.opacity(0.35), lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        }
    }

    private var replaySpeedMenu: some View {
        let current = Self.replaySpeeds.first(where: { $0.interval == replay.stepInterval })?.label ?? "1×"
        return Menu {
            ForEach(Self.replaySpeeds, id: \.label) { speed in
                Button(speed.label) {
                    replay.stepInterval = speed.interval
                    replay.reschedule()
                }
            }
        } label: {
            Text(current)
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Playback speed")
    }

    /// Opens the manual alert sheet for the current pair. Badge in
    /// the corner shows the number of armed alerts; tapping with
    /// no alerts opens the create-alert flow. Scenario alerts are
    /// added/removed automatically by the dashboard's onChange
    /// observers — this button only handles the manual flow.
    private var alertButton: some View {
        let armed = (app.selectedPairID.map { alertStore.armedAlerts(for: $0).count }) ?? 0
        let tint: Color = armed > 0 ? Theme.Color.warn : Theme.Color.textSecondary
        return Button {
            showAlertSheet = true
        } label: {
            Image(systemName: armed > 0 ? "bell.badge.fill" : "bell")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface)
                )
                .overlay(alignment: .topTrailing) {
                    if armed > 0 {
                        // Count chip stacked top-right corner.
                        // `.offset` pulls it slightly outside the
                        // tile so it reads as a badge, not part of
                        // the button face.
                        Text("\(armed)")
                            .font(.system(size: 8, weight: .heavy).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Theme.Color.warn))
                            .offset(x: 4, y: -4)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(armed > 0
              ? "\(armed) armed alert\(armed == 1 ? "" : "s") on this pair — click to add another"
              : "Create a price alert")
    }

    private var riskCalcButton: some View {
        Button {
            showRiskCalc.toggle()
        } label: {
            Image(systemName: "percent")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(showRiskCalc ? Theme.Color.accentStart : Theme.Color.textSecondary)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(showRiskCalc ? Theme.Color.accentStart.opacity(0.5) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Risk / position size calculator")
        .popover(isPresented: $showRiskCalc, arrowEdge: .top) {
            RiskCalculatorView()
        }
    }

    /// Inline status strip rendered above the chart header when
    /// auto-trader is enabled for the current pair. Shows the
    /// engine's live state in plain English so the user knows
    /// what the bot is doing without opening Settings:
    ///   • ANALYZING — Confluence Trade Scanner streaming in the background
    ///   • PENDING ORDER @ X — a pending limit is staged
    ///   • LIVE POSITION — a fill is open with running P/L
    ///   • IDLE — waiting for next opportunity (countdown to
    ///     re-analysis if known)
    ///   • COOLDOWN — paused after consecutive losses
    ///   • KILL SWITCH — daily loss limit, news pause, etc.
    @ViewBuilder
    private func autoTraderStatusBanner(pair: TradingPair) -> some View {
        let cfg = autoTraderConfig.config(for: pair.id)
        if cfg.enabled {
            let status = autoTrader.continuousStatus(for: pair.id)
            HStack(spacing: Theme.Spacing.md) {
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)
                Text(status.label)
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(status.color)
                Divider().background(Theme.Color.border).frame(height: 14)
                Text(status.detail.isEmpty
                     ? autoTraderDetailLine(pair: pair, cfg: cfg)
                     : status.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if !cfg.paperMode {
                    Text("LIVE")
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(0.5)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.Color.danger))
                }
                Text("Settings →")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Color.accentStart)
                    .onTapGesture { app.selectedSidebarItem = .settings }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(status.color.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .strokeBorder(status.color.opacity(0.35), lineWidth: 1)
            )
        }
    }

    /// Compose the detail line for the status banner. Reads the
    /// engine's per-pair state + the open trades to summarise
    /// what's actually happening in human terms.
    private func autoTraderDetailLine(pair: TradingPair, cfg: AutoTraderConfig) -> String {
        let session = analysisStore.session(kind: .confluenceScanner, pairID: pair.id)
        if session.phase == .running {
            return "Confluence Trade Scanner is analyzing — streaming the next setup…"
        }
        let openTrades = tradeStore.trades(for: pair.id).filter { !$0.isClosed }
        if let active = openTrades.first(where: { $0.status == .active }) {
            let live = yahoo.latestPrices[pair.id] ?? active.entry
            let pl = active.currentPL(at: live)
            let plStr = String(format: "%+.2f", pl)
            return "\(active.side.rawValue.uppercased()) \(String(format: "%.2f", active.lots)) lot · entry \(fmtPx(active.entry)) · live P/L $\(plStr)"
        }
        if let pending = openTrades.first(where: { $0.status == .pending }) {
            return "Pending \(pending.side.rawValue.uppercased()) order @ \(fmtPx(pending.entry)) · SL \(fmtPx(pending.stopLoss)) · TP \(fmtPx(pending.takeProfit))"
        }
        // No open trades — show last outcome + balance.
        let bal = paperBalance.currentBalance
        let plTotal = paperBalance.realisedPL
        let plStr = String(format: "%+.2f", plTotal)
        return cfg.paperMode
            ? "Waiting for next setup · paper balance $\(String(format: "%.0f", bal)) (\(plStr))"
            : "Waiting for next setup · risk \(String(format: "%.1f", cfg.riskPercent))% per trade"
    }

    private func fmtPx(_ v: Double) -> String {
        if v >= 10_000 { return String(format: "%.0f", v) }
        if v >= 100    { return String(format: "%.2f", v) }
        return String(format: "%.4f", v)
    }

    /// Auto-trader control pair: a toggle pill (click to flip
    /// enabled) + a small gear button that jumps to Settings.
    /// Always rendered when a pair is selected — when disabled,
    /// the pill reads "AUTO OFF" in muted gray so the user can
    /// see at a glance there's a per-pair switch available.
    @ViewBuilder
    private var autoTraderPill: some View {
        if let pairID = app.selectedPairID {
            let cfg = autoTraderConfig.config(for: pairID)
            HStack(spacing: 4) {
                autoTraderToggleButton(pairID: pairID, cfg: cfg)
                autoTraderGearButton
            }
        }
    }

    private func autoTraderToggleButton(pairID: String, cfg: AutoTraderConfig) -> some View {
        let enabled = cfg.enabled
        let state = autoTrader.displayState(for: pairID)
        let tint: Color = !enabled ? Theme.Color.textMuted
                          : (cfg.paperMode ? Theme.Color.warn : Theme.Color.danger)
        return Button {
            // Disable is one-click; enabling opens the profile
            // picker so the user can pick Position / Swing / Scalp
            // before the engine kicks off its first analysis.
            if cfg.enabled {
                var c = cfg
                c.enabled = false
                autoTraderConfig.update(c, for: pairID)
            } else {
                profileSheet = ProfileSheetMode(pairID: pairID)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: enabled ? "wand.and.rays" : "wand.and.rays.inverse")
                    .font(.system(size: 11, weight: .semibold))
                Text("AUTO")
                    .font(.system(size: 11, weight: .heavy))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if enabled {
                    Text(state.label)
                        .font(.system(size: 9, weight: .heavy).monospacedDigit())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(state.color))
                } else {
                    Text("OFF")
                        .font(.system(size: 9, weight: .heavy))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(Theme.Color.textMuted)
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(tint.opacity(enabled ? 0.6 : 0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(enabled
              ? (cfg.paperMode
                 ? "Auto-trader ON (paper) — click to disable."
                 : "Auto-trader ON (LIVE) — click to disable.")
              : "Auto-trader OFF for this pair — click to enable.")
    }

    private var autoTraderGearButton: some View {
        Button {
            // Deep-link: jump to Settings → Auto-trader with
            // this pair's inspector pre-expanded so the user
            // edits the relevant config without hunting.
            if let pairID = app.selectedPairID {
                app.autoTraderInspectorPairID = pairID
            }
            app.settingsCategory = .autoTrader
            app.selectedSidebarItem = .settings
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Color.textMuted)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface)
                )
        }
        .buttonStyle(.plain)
        .help("Open auto-trader settings for this pair.")
    }

    private func statsRow(_ pair: TradingPair) -> some View {
        HStack(spacing: Theme.Spacing.xxl) {
            stat(label: "24H HIGH", value: pair.high24h, color: Theme.Color.success)
            Divider().background(Theme.Color.border).frame(height: 24)
            stat(label: "24H LOW", value: pair.low24h, color: Theme.Color.danger)
            Divider().background(Theme.Color.border).frame(height: 24)
            stat(label: "CHANGE", value: pair.change, color: pair.change >= 0 ? Theme.Color.success : Theme.Color.danger)
            if let vol = cachedTotalVolume {
                Divider().background(Theme.Color.border).frame(height: 24)
                volumeStat(vol)
            }
            Spacer()
        }
    }

    /// Sum of `volume` across all visible candles. Returns nil when no
    /// candle has volume data — keeps the "VOLUME" stat hidden for pairs
    /// that don't report volume (everything except ounce, currently).
    /// Cached in `@State` so the O(n) candle iteration only runs when
    /// `candles` actually changes, not on every pan/zoom frame.
    /// (Pan/zoom performance fix.)
    @State private var cachedTotalVolume: Double? = nil
    private func recomputeTotalVolume() {
        let vols = candles.compactMap { $0.volume }
        guard !vols.isEmpty else { cachedTotalVolume = nil; return }
        let sum = vols.reduce(0, +)
        cachedTotalVolume = sum > 0 ? sum : nil
    }

    /// Volume strip rendered just under the main price chart. Hidden when
    /// the visible series doesn't have volume — keeps the layout clean for
    /// non-ounce pairs.
    @ViewBuilder
    private func volumeStrip(_ pair: TradingPair) -> some View {
        // `showVolume` is the user-facing toggle (lives in the indicator
        // menu and the Layers popover). `hasVolume` is the data-presence
        // check — hide the strip anyway when the visible series has no
        // volume data, even if the toggle is on, so non-ounce pairs
        // don't show an empty bar.
        let bars = VolumeBarsView(candles: candles, accent: pair.color, xDomain: xDomain)
        if showVolume && bars.hasVolume {
            bars
                .frame(height: 70)
                .padding(.trailing, Theme.Spacing.sm)
                .clipped()
        }
    }

    /// Drawing-tools dropdown. Used to be a row of four buttons taking
    /// up >120pt; now collapsed into one Menu that shows the active
    /// tool's glyph (highlighted when something other than `.none` is
    /// armed). Clicking opens the picker; selecting an item arms that
    /// tool. Drawings are committed via the ChartView callback and
    /// rendered as Chart marks alongside the AI overlays.
    private var drawingToolbar: some View {
        let isArmed = activeDrawingTool != .none
        return Menu {
            ForEach(DrawingTool.allCases) { tool in
                Button {
                    activeDrawingTool = tool
                } label: {
                    Label(tool.label,
                          systemImage: activeDrawingTool == tool
                                       ? "checkmark.circle.fill"
                                       : tool.systemImage)
                }
            }
        } label: {
            Image(systemName: activeDrawingTool.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isArmed ? Color.white : Theme.Color.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    Group {
                        if isArmed {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Theme.accentGradient)
                        } else {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Theme.Color.surface)
                        }
                    }
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Drawing tool · \(activeDrawingTool.label)")
    }

    /// True when the visible window's right edge already sits on the most
    /// recent candle — i.e. there's nothing newer to scroll to, so the
    /// "scroll to latest" button hides. A `nil` `xDomain` means auto-fit,
    /// which always pins the latest bar. In replay mode `candles` is
    /// cursor-clipped, so "latest" is the last revealed bar.
    private var isViewingLatest: Bool {
        guard candles.count > 0, let d = xDomain else { return true }
        return d.upperBound >= Double(candles.count - 1)
    }

    /// MetaTrader-style "scroll to the end": slide the visible window so
    /// its right edge lands on the newest candle, *preserving the current
    /// zoom width* (unlike Reset, which refits the default window). Works
    /// in replay too — `candles` is cursor-clipped there, so this jumps to
    /// the last revealed bar.
    private func scrollToLatest() {
        let n = candles.count
        guard n > 0, let d = xDomain else { return }   // nil ⇒ already at latest
        // Match the default domain's trailing half-bar pad so the newest
        // candle isn't flush against the right edge.
        let upper = Double(n - 1) + 0.5
        let span = max(d.upperBound - d.lowerBound, 1)
        withAnimation(.easeInOut(duration: 0.25)) {
            xDomain = (upper - span) ... upper
        }
    }

    /// Multiply the current window's half-span by `factor` while keeping
    /// its centre fixed. <1 ⇒ zoom in, >1 ⇒ zoom out. Mirrors the maths
    /// in ChartView's magnification gesture so the buttons and the pinch
    /// behave the same.
    private func zoom(by factor: Double) {
        // Resolve the current window the same way ChartView does so the
        // first zoom click after "Reset" behaves predictably.
        let current: ClosedRange<Double>
        if let d = xDomain {
            current = d
        } else {
            let n = candles.count
            guard n > 0 else { return }
            current = n == 1 ? -0.5 ... 0.5 : -0.5 ... Double(n - 1) + 0.5
        }
        let center = (current.lowerBound + current.upperBound) / 2
        let halfSpan = (current.upperBound - current.lowerBound) / 2
        let clamped = max(0.05, min(50, factor))
        let newHalf = halfSpan * clamped
        xDomain = (center - newHalf) ... (center + newHalf)
    }

    /// TradingView-style reset: jump to the most-recent candles at a
    /// comfortable zoom (~150 bars) and clear any manual Y-axis pin so
    /// the price scale auto-fits the visible window.
    private func resetChart() {
        let n = candles.count
        guard n > 0 else { xDomain = nil; yDomain = nil; return }
        let defaultBars: Double = 150
        let upper = Double(n - 1) + 0.5
        let lower = max(-0.5, upper - defaultBars)
        // Compute an explicit Y fit for the reset window directly from the
        // candle array. Setting a concrete non-nil value ensures Apple Charts
        // registers a definite domain change and redraws the Y axis —
        // transitioning from a pinned value through nil back to a computed
        // value via the effectiveYDomain chain is unreliable on macOS 13.
        let loIdx = max(0, Int(lower.rounded(.down)))
        let hiIdx = min(n - 1, Int(upper.rounded(.up)))
        let slice = candles[loIdx...hiIdx]
        if let lo = slice.map(\.low).min(), let hi = slice.map(\.high).max() {
            let span = max(hi - lo, hi * 0.001, 1.0)
            let pad  = span * 0.05
            yDomain = (lo - pad) ... (hi + pad)
        } else {
            yDomain = nil
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            xDomain = lower ... upper
        }
        // Re-enable continuous Y auto-fit after the animation finishes, so
        // the user can pan left and have the Y scale follow automatically.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            yDomain = nil
        }
    }

    // ── Chart context menu ────────────────────────────────────────
    /// Right-click menu with all chart options. Mirrors the grid
    /// pane's `optionsMenu` for feature parity across modes, plus
    /// Scroll to Latest and Reset Chart actions.
    @ViewBuilder
    private func chartContextMenu(pair: TradingPair) -> some View {
        Menu("Timeframe") {
            ForEach(Timeframe.allCases) { tf in
                Button {
                    timeframe = tf
                } label: {
                    Label(tf.label, systemImage: tf == timeframe ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        Menu("Chart type") {
            ForEach(ChartType.allCases) { ct in
                Button {
                    userChartType = ct
                } label: {
                    Label(ct.label, systemImage: ct == userChartType ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        Menu("Indicators") {
            ForEach(IndicatorKind.allCases) { kind in
                Button {
                    setIndicator(kind, enabled: !enabledIndicatorKinds.contains(kind))
                } label: {
                    Label(kind.label, systemImage: enabledIndicatorKinds.contains(kind) ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        Menu("Oscillators") {
            ForEach(OscillatorKind.allCases) { kind in
                Button {
                    setOscillator(kind, enabled: !enabledOscillators.contains(kind))
                } label: {
                    Label(kind.label, systemImage: enabledOscillators.contains(kind) ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        Button {
            showVolume.toggle()
        } label: {
            Label("Volume", systemImage: showVolume ? "checkmark.circle.fill" : "circle")
        }
        Divider()
        Menu("Drawing Tool") {
            ForEach(DrawingTool.allCases) { tool in
                Button {
                    activeDrawingTool = tool
                } label: {
                    Label(tool.label, systemImage: activeDrawingTool == tool
                          ? "checkmark.circle.fill" : tool.systemImage)
                }
            }
        }
        if selectedDrawingID != nil {
            Button(role: .destructive) {
                if let id = selectedDrawingID {
                    drawingStore.remove(id: id, for: pair.id)
                    selectedDrawingID = nil
                }
            } label: {
                Label("Delete Selected Drawing", systemImage: "trash")
            }
        }
        if !drawingStore.drawings(for: pair.id).isEmpty {
            Button(role: .destructive) {
                drawingStore.clear(for: pair.id)
                selectedDrawingID = nil
            } label: {
                Label("Clear Drawings", systemImage: "trash.slash")
            }
        }
        Divider()
        if !isViewingLatest {
            Button {
                scrollToLatest()
            } label: {
                Label("Scroll to Latest", systemImage: "forward.end.fill")
            }
        }
        Button {
            resetChart()
        } label: {
            Label("Reset Chart", systemImage: "arrow.counterclockwise")
        }
        Divider()
        Button {
            app.isChartFullscreen.toggle()
        } label: {
            Label(isChartFull ? "Exit Fullscreen" : "Fullscreen",
                  systemImage: isChartFull
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
        }
    }

    /// Specialized stat tile for volume — wider precision, compact K/M/B
    /// formatter rather than the price formatter.
    private func volumeStat(_ v: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("VOLUME")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            Text(Self.compactVolume(v))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
                .monospacedDigit()
        }
    }

    private static func compactVolume(_ v: Double) -> String {
        switch Swift.abs(v) {
        case 1_000_000_000...:
            return "\((v / 1_000_000_000).formatted(.number.precision(.fractionLength(2))))B"
        case 1_000_000...:
            return "\((v / 1_000_000).formatted(.number.precision(.fractionLength(2))))M"
        case 1_000...:
            return "\((v / 1_000).formatted(.number.precision(.fractionLength(1))))K"
        default:
            return v.formatted(.number.precision(.fractionLength(0)))
        }
    }

    private func stat(label: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            Text(value.formatted(.number.precision(.fractionLength(value >= 100 ? 0 : 2))))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }

    // ── Empty state ────────────────────────────────────────────────
    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Spacer()
            Image(systemName: "chart.line.downtrend.xyaxis.circle")
                .font(.system(size: 56))
                .foregroundStyle(Theme.Color.textMuted)
            Text("No pair selected")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
            Text("Pick a market in the sidebar — Yahoo/cTrader live data will start streaming once a pair is selected.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Color.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xxl)
            PrimaryButton("Re-run setup wizard", systemImage: "wand.and.stars") {
                app.showWizard = true
            }
            .padding(.top, Theme.Spacing.md)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // ── Helpers ────────────────────────────────────────────────────
    private func formatChange(_ pair: TradingPair) -> String {
        let sign = pair.changePercent >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", pair.changePercent))%"
    }

    /// Header-line price text. Reads the live-stream value
    /// published by `YahooScheduler` for whichever pair is
    /// selected; falls back to "—" before the first tick lands.
    private func displayedPrice(_ pair: TradingPair) -> String {
        if let p = yahoo.latestPrices[pair.id] {
            return p.formatted(.number.precision(.fractionLength(2)))
        }
        return "—"
    }

    private func reloadCandles() async {
        guard let db = app.database, let pairID = app.selectedPairID else {
            candles = []
            return
        }
        isLoading = true
        // Async read — SQLite work runs off the main thread.
        let pair = app.pairs.first(where: { $0.id == pairID })
        let respectsWeekend = pair?.category != .crypto
        let until = replay.cursor ?? Date()
        let result = await OHLCCandleLoader.loadAsync(
            repo: db.ohlcRepo, pairID: pairID, tf: timeframe,
            since: Date.distantPast, until: until,
            dropClosedDays: respectsWeekend
        )
        let priorCount = candles.count
        self.candles = result
        recomputeTotalVolume()
        self.isLoading = false
        self.followLatestIfPinned(priorCount: priorCount, newCount: result.count)
        guard !replay.isActive else { return }
        if let r = Oscillators.rsi(result, period: oscillatorConfig.rsiPeriod).last?.value {
            let livePeek = yahoo.latestPrices[pairID]
            alertStore.evaluateRSI(r, pricePeek: livePeek, for: pairID)
        }
        notifyOrderBlockEvents(result, pairID: pairID)
    }

    private func focusChart(on target: NotificationChartTarget) {
        guard !candles.isEmpty else { return }
        let index = candles.indices.min {
            abs(candles[$0].id.timeIntervalSince(target.candleDate))
                < abs(candles[$1].id.timeIntervalSince(target.candleDate))
        } ?? candles.count - 1
        let radius = 30
        let lower = max(0, index - radius)
        let upper = min(candles.count - 1, index + radius)
        xDomain = Double(lower)...Double(max(lower + 1, upper))
        yDomain = nil
    }

    /// Cheap live-tick path. The full `reloadCandles()` now re-reads the
    /// *entire* stored series (years of bars) and re-folds it — far too
    /// heavy to run on the main thread at the 1 Hz live cadence. Instead
    /// we read only a short trailing window, fold it, and splice it onto
    /// the tail of the in-memory `candles`: the current (in-progress) bar
    /// gets its latest OHLC, and any bar that just rolled over is
    /// appended. The deep load stays reserved for pair / timeframe change
    /// and explicit refresh.
    ///
    /// Now uses `loadAsync` so the SQLite read + fold runs off the main
    /// thread. (Data-fetching Performance Fix.)
    private func refreshTrailingCandles() async {
        guard let db = app.database, let pairID = app.selectedPairID else { return }
        let pair = app.pairs.first(where: { $0.id == pairID })
        let respectsWeekend = pair?.category != .crypto
        let until = Date()
        // Window wide enough to cover the current + prior fold bucket so
        // re-folding the tail reproduces the last bars exactly.
        let margin = Double(max(timeframe.seconds * 3, 6 * 3600))
        let since = until.addingTimeInterval(-margin)
        let recent = await OHLCCandleLoader.loadAsync(
            repo: db.ohlcRepo, pairID: pairID, tf: timeframe,
            since: since, until: until, dropClosedDays: respectsWeekend
        )
        guard let cutoff = recent.first?.bucketStart else { return }
        let priorCount = candles.count
        var merged = candles
        while let last = merged.last, last.bucketStart >= cutoff { merged.removeLast() }
        merged.append(contentsOf: recent)
        candles = merged
        recomputeTotalVolume()
        followLatestIfPinned(priorCount: priorCount, newCount: merged.count)
        if let r = Oscillators.rsi(merged, period: oscillatorConfig.rsiPeriod).last?.value {
            alertStore.evaluateRSI(r, pricePeek: yahoo.latestPrices[pairID], for: pairID)
        }
        notifyOrderBlockEvents(merged, pairID: pairID)
    }

    /// Feeds Change of Character zones to the lifecycle alert evaluator.
    /// Order Block and Steroid Order Block notifications are intentionally
    /// disabled; those indicators remain chart-only.
    private func notifyOrderBlockEvents(_ candles: [Candle], pairID: String) {
        let chochActive = isStrategyNotificationActive(.changeOfCharacter)
        guard chochActive else { return }
        let pairLabel = app.pairs.first(where: { $0.id == pairID })?.name ?? pairID

        let config = oscillatorConfig
        Task.detached(priority: .utility) {
            let zones = ChangeOfCharacter.compute(
                candles,
                swingLength: config.chochSwingLength,
                minSwingPct: config.chochMinSwingPct,
                requireFVG: config.chochRequireFVG,
                showMitigated: true
            )
            await self.alertStore.evaluateCHoCH(
                zones,
                candles: candles,
                pairID: pairID,
                pairLabel: pairLabel
            )
        }
    }

    /// Pure candle fetch for an arbitrary timeframe. All pairs go
    /// through the OHLC table now (no Iran snapshot fallback) —
    /// `respectsWeekend` is on for the metal pair so COMEX-closed
    /// days drop out, off for 24/7 crypto.
    private func candles(for tf: Timeframe) -> [Candle] {
        guard let pairID = app.selectedPairID else { return [] }
        return candles(for: pairID, tf: tf)
    }

    /// Pair-agnostic version — used both by the dashboard (via the
    /// selected-pair convenience above) and by the AutoTraderEngine
    /// when it needs to bundle 15m/1h/4h for a headless Confluence Trade Scanner
    /// re-run on any pair.
    private func candles(for pairID: String, tf: Timeframe, ignoreReplay: Bool = false) -> [Candle] {
        guard let db = app.database else { return [] }
        // Replay clips the right edge to the cursor; the window of
        // context (`historySeconds`) ends there instead of at the live
        // moment. This single substitution is what makes both the chart
        // AND every AI analysis (which load through this same function)
        // see only the bars up to the replay cursor.
        //
        // `ignoreReplay` opts back into live data — the headless
        // auto-trader uses it so a backtest in the foreground can't
        // feed the live trading engine stale bars.
        let until = (ignoreReplay ? nil : replay.cursor) ?? Date()
        // Load the *entire* stored series up to `until` (the live moment,
        // or the replay cursor). The chart renders only a bounded visible
        // window via `ChartWindow`, and the AI / auto-trader callers
        // suffix-cap the candles they actually send, so reading deep here
        // is cheap-enough and safe. Previously this clipped to
        // `tf.historySeconds` (~1–2 weeks), which hid the years of history
        // already sitting in the DB.
        let since = Date.distantPast
        let pair = app.pairs.first(where: { $0.id == pairID })
        // Forex + indices respect weekends (COMEX, NYSE all close);
        // crypto is 24/7 so we never drop closed days for those.
        let respectsWeekend = pair?.category != .crypto
        return loadOHLCCandles(
            repo: db.ohlcRepo,
            pairID: pairID,
            tf: tf, since: since, until: until,
            dropClosedDays: respectsWeekend
        )
    }

    /// "Follow latest" auto-pan: when the user has pinned `xDomain` (by
    /// dragging or pinching) AND the right edge of their visible window
    /// is on the last bar that *was* available, slide the window forward
    /// by however many new bars arrived. This is how trading apps avoid
    /// the "live data is hidden behind my zoom" trap.
    ///
    /// If the user's right edge isn't at the last bar (they've scrolled
    /// back through history) we leave the view alone — they're looking
    /// at something specific and shouldn't get yanked forward.
    private func followLatestIfPinned(priorCount: Int, newCount: Int) {
        guard let pinned = xDomain else { return }   // auto-fit handles itself
        guard newCount > priorCount, priorCount > 0 else { return }
        // Anchor: was the upper bound within half a bar of the last
        // previously-available index? Use ≥ priorCount - 1 to account
        // for the half-bar trailing padding the default domain uses.
        let wasAtEdge = pinned.upperBound >= Double(priorCount - 1)
        guard wasAtEdge else { return }
        let shift = Double(newCount - priorCount)
        xDomain = (pinned.lowerBound + shift) ... (pinned.upperBound + shift)
    }

    /// Resolve the stored OHLC timeframe to use as the *source* for a given
    /// chart timeframe, and whether we need to aggregate up. We only store
    /// 1m and 5m bars; everything coarser is rolled up from 5m.
    /// `dropClosedDays` is on for COMEX-hours markets (gold) and off
    /// for 24/7 markets (crypto).
    /// The stored OHLC series we read as the *source* for a chart
    /// timeframe. We keep four native series (1m, 5m, 1h, 1d) at the
    /// depths Yahoo allows and fold the in-between TFs up from the
    /// nearest finer native one. Reading h1/h4/d1 from native 1h/1d
    /// (rather than folding from 5m) is what lets Replay reach years
    /// back instead of ~2 months.
    private func sourceTimeframeTag(for tf: Timeframe) -> String {
        OHLCCandleLoader.sourceTimeframeTag(for: tf)
    }

    /// True while Yahoo is fetching the full history for the source
    /// series the current timeframe reads from — drives the chart
    /// skeleton / "loading history" pill.
    private var isBackfillingCurrentTF: Bool {
        guard let pairID = app.selectedPairID else { return false }
        return yahoo.backfilling.contains("\(pairID)|\(sourceTimeframeTag(for: timeframe))")
    }

    // ── Grid fullscreen toolbar ────────────────────────────────────
    /// Toolbar row shown at the top of the grid when a pane goes
    /// fullscreen. Mirrors the single-chart header toolbar so every
    /// tool (AI, indicators, drawing, chart type, timeframe, etc.)
    /// is reachable without exiting fullscreen. Animates in from the
    /// top with a slide + fade. (Grid fullscreen toolbar feature.)
    private var gridFullscreenToolbar: some View {
        HStack(spacing: Theme.Spacing.md) {
            // Pair name for context
            if let pairID = app.selectedPairID,
               let pair = app.pairs.first(where: { $0.id == pairID }) {
                Text(pair.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(timeframe.label)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.Color.textMuted)
                toolbarDivider
            }
            HStack(spacing: 6) {
                analyzeButton
                replayButton
                alertButton
                riskCalcButton
                autoTraderPill
                toolbarDivider
                indicatorMenu
                indicatorSettingsButton
                layersButton
                drawingToolbar
                toolbarDivider
                ChartTypeToggle(
                    selected: $userChartType,
                    isDisabled: false
                )
                TimeframeSelector(selected: $timeframe)
                toolbarDivider
                debugButton
                singleChartFullscreenButton
            }
        }
    }

    /// Pull deep history for the selected pair: the current timeframe's
    /// series first (so its skeleton resolves fastest), then warm the
    /// remaining native series in the background. Each `ensureDeepHistory`
    /// is idempotent, so this is cheap to call on every pair / timeframe
    /// change — already-filled series return immediately.
    private func warmHistory() {
        guard let pairID = app.selectedPairID else { return }
        let currentSrc = sourceTimeframeTag(for: timeframe)
        Task {
            await yahoo.ensureDeepHistory(pairID: pairID, sourceTF: currentSrc)
            await reloadCandles()
            await yahoo.backfillAll(pairID: pairID)
            await reloadCandles()
        }
    }

    private func loadOHLCCandles(
        repo: OHLCRepo,
        pairID: String,
        tf: Timeframe,
        since: Date,
        until: Date,
        dropClosedDays: Bool
    ) -> [Candle] {
        OHLCCandleLoader.load(
            repo: repo, pairID: pairID, tf: tf,
            since: since, until: until, dropClosedDays: dropClosedDays
        )
    }

    // ── Replay stepping ────────────────────────────────────────────

    /// First stored bar strictly *after* `cursor` for `tf`, or nil at
    /// the end of available data. Loads a small forward window (sized to
    /// clear a weekend + holiday on any TF) rather than reusing the
    /// cursor-clipped `candles(for:)`, which by definition can't see
    /// past the cursor.
    private func nextReplayBar(after cursor: Date, pairID: String, tf: Timeframe) -> Candle? {
        guard let db = app.database else { return nil }
        let pair = app.pairs.first(where: { $0.id == pairID })
        let respectsWeekend = pair?.category != .crypto
        let lookahead = max(tf.seconds * 6, 5 * 24 * 3600)
        let bars = loadOHLCCandles(
            repo: db.ohlcRepo, pairID: pairID, tf: tf,
            since: cursor,
            until: min(cursor.addingTimeInterval(lookahead), Date()),
            dropClosedDays: respectsWeekend
        )
        return bars.first(where: { $0.bucketStart > cursor })
    }

    /// Last stored bar strictly *before* `cursor` for `tf`, for the
    /// step-back control. Same windowed approach as `nextReplayBar`.
    private func prevReplayBar(before cursor: Date, pairID: String, tf: Timeframe) -> Candle? {
        guard let db = app.database else { return nil }
        let pair = app.pairs.first(where: { $0.id == pairID })
        let respectsWeekend = pair?.category != .crypto
        let lookback = max(tf.seconds * 6, 5 * 24 * 3600)
        let bars = loadOHLCCandles(
            repo: db.ohlcRepo, pairID: pairID, tf: tf,
            since: cursor.addingTimeInterval(-lookback),
            until: cursor,
            dropClosedDays: respectsWeekend
        )
        return bars.last(where: { $0.bucketStart < cursor })
    }

    /// Move the replay cursor forward one bar of the current timeframe.
    /// Snapping to the next *stored* bar (rather than blindly adding
    /// `tf.seconds`) skips COMEX weekend gaps cleanly. Returns false at
    /// the end of data so auto-play can stop itself.
    ///
    /// Splices the single revealed bar onto `candles` in memory instead
    /// of calling `reloadCandles()`, which re-reads and re-folds the
    /// *entire* stored series (`since: Date.distantPast`). That full
    /// reload — run on every step, up to 4×/sec during auto-play, with
    /// no cancellation of the previous one — was what made replay
    /// stepping/auto-play laggy: it also busts every `ChartDerivedCache`
    /// signature, forcing every enabled indicator to recompute over the
    /// full history on every tick. This mirrors the cheap splice
    /// `refreshTrailingCandles()` already uses for the live 1 Hz tick.
    @discardableResult
    private func advanceReplay() -> Bool {
        guard replay.isActive, let cursor = replay.cursor,
              let pairID = app.selectedPairID else { return false }
        guard let next = nextReplayBar(after: cursor, pairID: pairID, tf: timeframe) else {
            return false
        }
        replay.cursor = next.bucketStart
        appendReplayBar(next)
        return true
    }

    /// Incremental counterpart to `refreshTrailingCandles()`, scoped to
    /// replay's single-bar advance: appends (or, on the rare chance the
    /// bucket already matches, replaces) one bar without touching the
    /// rest of the array. No alert/notification evaluation here —
    /// `reloadCandles()` already skips that while replay is active, and
    /// this path never runs outside replay.
    private func appendReplayBar(_ bar: Candle) {
        let priorCount = candles.count
        var merged = candles
        if let last = merged.last, last.bucketStart == bar.bucketStart {
            merged[merged.count - 1] = bar
        } else {
            merged.append(bar)
        }
        candles = merged
        followLatestIfPinned(priorCount: priorCount, newCount: merged.count)
    }

    /// Selectable date range for the replay date-jump picker, bounded
    /// to the data we actually hold for the current timeframe's source
    /// series (so the picker can't land somewhere with no bars). Falls
    /// back to a 10-year lower bound if the range can't be read.
    private func replayDateRange() -> ClosedRange<Date> {
        let upper = Date()
        let fallbackLower = upper.addingTimeInterval(-10 * 365 * 24 * 3600)
        guard let pairID = app.selectedPairID, let db = app.database,
              let earliest = try? db.ohlcRepo.earliestBucket(
                pairID: pairID, timeframe: sourceTimeframeTag(for: timeframe))
        else { return fallbackLower...upper }
        // Guard against a degenerate range (earliest >= now).
        return earliest < upper ? earliest...upper : fallbackLower...upper
    }

    /// Commit the date-jump: snap the cursor to the nearest stored bar
    /// at/just before the picked date so it lands on real data.
    private func jumpReplay(to date: Date) {
        guard let pairID = app.selectedPairID else { return }
        // Re-use the backward finder (which returns the last bar < date)
        // but include the picked instant itself via a 1s nudge forward.
        let target = prevReplayBar(before: date.addingTimeInterval(1),
                                   pairID: pairID, tf: timeframe)?.bucketStart
                     ?? date
        replay.setAnchor(target)
        xDomain = nil
        Task { await reloadCandles() }
    }

    /// Move the replay cursor back one bar of the current timeframe.
    /// Pops the last revealed bar from `candles` in memory — the
    /// step-back counterpart to `advanceReplay`'s append — instead of
    /// reloading and re-folding the entire stored series.
    private func stepReplayBack() {
        guard replay.isActive, let cursor = replay.cursor,
              let pairID = app.selectedPairID,
              let prev = prevReplayBar(before: cursor, pairID: pairID, tf: timeframe)
        else { return }
        replay.cursor = prev.bucketStart
        if candles.last?.bucketStart == cursor {
            candles.removeLast()
        } else {
            // In-memory candles don't line up with the cursor (shouldn't
            // normally happen) — fall back to a full reload rather than
            // leaving the chart out of sync.
            Task { await reloadCandles() }
        }
    }
}

struct DashboardIndicatorMenu: View, Equatable {
    @State private var isPresented = false
    @State private var addIndicatorsExpanded = false
    @State private var addPanelsExpanded = false

    @Binding var showVolume: Bool
    @Binding var indicatorInstances: [IndicatorInstance]
    @Binding var oscillatorInstances: [OscillatorInstance]
    @Binding var editingIndicatorID: UUID?
    @Binding var editingOscillatorID: UUID?
    @Binding var showIndicatorSettings: Bool
    @Binding var srLevels: PromptBuilder.SRLevels
    @Binding var fvgZones: [PromptBuilder.FVGZone]
    @Binding var taScenario: PromptBuilder.TAScenario?
    @Binding var taAltScenario: PromptBuilder.TAScenario?
    @Binding var pendingActivation: DashboardView.PendingActivation?
    
    let nyLiveScenario: PromptBuilder.TAScenario?
    let enabledIndicatorKinds: Set<IndicatorKind>
    let enabledOscillators: Set<OscillatorKind>
    
    let onToggleIndicatorHidden: (UUID) -> Void
    let onRemoveIndicator: (UUID) -> Void
    let onAddIndicator: (IndicatorKind) -> Void
    let onToggleOscillatorHidden: (UUID) -> Void
    let onRemoveOscillator: (UUID) -> Void
    let onAddOscillator: (OscillatorKind) -> Void
    let onSaveIndicators: () -> Void
    let onSaveOscillators: () -> Void
    
    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "function")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface)
                    )
                let activeCount = enabledIndicatorKinds.count + enabledOscillators.count
                if activeCount > 0 {
                    Circle()
                        .fill(Theme.accentGradient)
                        .frame(width: 9, height: 9)
                        .overlay(
                            Circle()
                                .strokeBorder(Theme.Color.surfaceHi, lineWidth: 1)
                        )
                        .offset(x: 3, y: -3)
                }
            }
            .help(activeCount(label: enabledIndicatorKinds.count + enabledOscillators.count))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            indicatorPopoverContent
        }
    }

    /// A SwiftUI popover deliberately replaces the native nested `Menu`.
    /// AppKit dismisses an open submenu whenever its SwiftUI host is
    /// refreshed by a live price tick. The popover owns its presentation
    /// state, so candle updates can redraw the dashboard without collapsing
    /// either the panel or the expanded add lists.
    private var indicatorPopoverContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                popoverSectionTitle("Overlays")

                Toggle(isOn: $showVolume) {
                    Label("Volume", systemImage: showVolume
                          ? "checkmark.circle.fill" : "circle")
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)

                ForEach(indicatorInstances) { inst in
                    let isHidden = inst.hidden
                    Button {
                        onToggleIndicatorHidden(inst.id)
                    } label: {
                        Label {
                            HStack(spacing: 6) {
                                Text(inst.label)
                                    .foregroundStyle(isHidden ? Theme.Color.textMuted : inst.kind.color)
                                Spacer()
                                if editingIndicatorID == inst.id {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.Color.info)
                                }
                            }
                        } icon: {
                            Image(systemName: isHidden ? "eye.slash" : "checkmark.circle.fill")
                                .foregroundStyle(isHidden ? Theme.Color.textMuted : inst.kind.color)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            editingIndicatorID = inst.id
                        } label: {
                            Label("Settings", systemImage: "slider.horizontal.3")
                        }
                        Button(role: .destructive) {
                            onRemoveIndicator(inst.id)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }

                DisclosureGroup(isExpanded: $addIndicatorsExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(IndicatorKind.allCases) { kind in
                            Button {
                                onAddIndicator(kind)
                            } label: {
                                Label(kind.label, systemImage: "plus")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, 12)
                    .padding(.top, 6)
                } label: {
                    Label("Add indicator", systemImage: "plus.circle")
                }

                Divider()
                popoverSectionTitle("Panels")

                ForEach(oscillatorInstances) { inst in
                    Button {
                        onToggleOscillatorHidden(inst.id)
                    } label: {
                        Label {
                            HStack(spacing: 6) {
                                Text(inst.label)
                                if editingOscillatorID == inst.id {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.Color.info)
                                }
                            }
                        } icon: {
                            Image(systemName: inst.hidden ? "eye.slash" : "checkmark.circle.fill")
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            editingOscillatorID = inst.id
                        } label: {
                            Label("Settings", systemImage: "slider.horizontal.3")
                        }
                        Button(role: .destructive) {
                            onRemoveOscillator(inst.id)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }

                DisclosureGroup(isExpanded: $addPanelsExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(OscillatorKind.allCases) { kind in
                            Button {
                                onAddOscillator(kind)
                            } label: {
                                Label(kind.label, systemImage: "plus")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, 12)
                    .padding(.top, 6)
                } label: {
                    Label("Add panel", systemImage: "plus.rectangle.on.rectangle")
                }

                Divider()

                Button {
                    showIndicatorSettings = true
                    isPresented = false
                } label: {
                    Label("Settings…", systemImage: "slider.horizontal.3")
                }

                if !srLevels.isEmpty {
                    Button("Clear S/R lines") {
                        srLevels = .init(support: [], resistance: [])
                    }
                }
                if !fvgZones.isEmpty {
                    Button("Clear FVG zones") { fvgZones = [] }
                }
                if taScenario != nil {
                    Button("Clear scenario") { taScenario = nil }
                }
                if taAltScenario != nil {
                    Button("Clear alt scenario") { taAltScenario = nil }
                }
                if let scenario = nyLiveScenario {
                    Button("Activate NY Open setup…") {
                        pendingActivation = DashboardView.PendingActivation(
                            scenario: scenario,
                            sourceHistoryEntryID: nil
                        )
                        isPresented = false
                    }
                }
                if !enabledIndicatorKinds.isEmpty || !enabledOscillators.isEmpty {
                    Divider()
                    Button("Clear all") {
                        indicatorInstances = []
                        oscillatorInstances = []
                        onSaveIndicators()
                        onSaveOscillators()
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(14)
        }
        .frame(width: 300)
        .frame(maxHeight: 520)
    }

    private func popoverSectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.Color.textMuted)
    }
    
    private func activeCount(label n: Int) -> String {
        n == 0 ? "Indicators" : "Indicators · \(n) active"
    }
    
    static func == (lhs: DashboardIndicatorMenu, rhs: DashboardIndicatorMenu) -> Bool {
        lhs.showVolume == rhs.showVolume &&
        lhs.indicatorInstances == rhs.indicatorInstances &&
        lhs.oscillatorInstances == rhs.oscillatorInstances &&
        lhs.editingIndicatorID == rhs.editingIndicatorID &&
        lhs.editingOscillatorID == rhs.editingOscillatorID &&
        lhs.showIndicatorSettings == rhs.showIndicatorSettings &&
        lhs.srLevels == rhs.srLevels &&
        lhs.fvgZones == rhs.fvgZones &&
        lhs.taScenario == rhs.taScenario &&
        lhs.taAltScenario == rhs.taAltScenario &&
        lhs.pendingActivation == rhs.pendingActivation &&
        lhs.nyLiveScenario == rhs.nyLiveScenario &&
        lhs.enabledIndicatorKinds == rhs.enabledIndicatorKinds &&
        lhs.enabledOscillators == rhs.enabledOscillators
    }
}
