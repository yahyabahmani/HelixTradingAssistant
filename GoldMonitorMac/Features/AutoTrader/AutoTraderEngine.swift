import Foundation
import Combine
import SwiftUI

/// Orchestration layer for auto-trading. Lives at the app root,
/// owns the per-pair state machine, subscribes to the inputs
/// (`AnalysisStore` history, `TradeStore` lifecycle, `NewsStore`
/// calendar) and emits the side-effects (stage paper trades,
/// schedule re-analysis on the next candle close). Paper-only —
/// no orders ever reach a real broker.
///
/// The engine is **passive** — it never initiates a Confluence Trade Scanner run
/// on its own. The user kicks off the first run from
/// `AnalysisPage`; from then on, the engine reacts to outcomes
/// and re-runs as the state machine dictates.
@MainActor
final class AutoTraderEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case staged(scenarioID: String, expectingFill: Bool)
        case active(scenarioID: String)
        case cooldown(until: Date)
        case killed(reason: String)
    }

    /// Per-pair state — drives the AUTO pill colour + Settings
    /// status badge. Published so the UI re-renders on transitions.
    @Published private(set) var stateByPair: [String: State] = [:]

    /// Last scenario the engine staged for each pair. Kept so we
    /// can pass it as `priorRunHint.main` into the next Confluence Trade Scanner
    /// re-run.
    private var lastScenarioByPair: [String: PromptBuilder.TAScenario] = [:]
    private var lastAltByPair: [String: PromptBuilder.TAScenario] = [:]

    /// Per-pair fallback queue. When Confluence Trade Scanner emits a scored
    /// scenario array, the engine stages the top one and stashes
    /// the rest here. On invalidation it pops the next one off
    /// the queue and stages it — only re-runs Confluence Trade Scanner when the
    /// queue is exhausted. Single-scenario kinds (Full TA) just
    /// leave this empty.
    private var scenarioQueueByPair: [String: [PromptBuilder.ScoredScenario]] = [:]
    /// IDs of HistoryEntries whose scored queue we've already
    /// loaded — guards against re-seeding on every `history`
    /// emission when only the outcome changed.
    private var seededQueueFromEntry: Set<UUID> = []
    /// 1-indexed rank of the scenario currently staged for the
    /// pair, relative to the original scored array. Used by
    /// `displayState` to show "STAGED 2/5" on the AUTO pill.
    private var currentScenarioRankByPair: [String: Int] = [:]
    /// Total scenarios in the original scored array — kept so
    /// `displayState` and `priorRunHint` can express "we tried
    /// all 5 and they all failed".
    private var currentScenarioTotalByPair: [String: Int] = [:]
    /// HistoryEntry whose scored queue is currently active for
    /// each pair. Used both to re-stage from the same entry
    /// (so outcome tracking still resolves) and to feed
    /// `priorRunHint` after the queue exhausts.
    private var sourceEntryByPair: [String: UUID] = [:]

    /// IDs of HistoryEntries we've already routed to a trade.
    /// Prevents double-staging when AnalysisStore.history mutates
    /// for unrelated reasons (e.g. an outcome update).
    private var stagedEntryIDs: Set<UUID> = []

    /// IDs of trades whose terminal close we've already reacted to
    /// (so we don't re-trigger analysis twice for the same close).
    private var reactedTradeIDs: Set<UUID> = []

    /// Wall-clock timestamp of the last consecutive-loss check —
    /// used to drive the cooldown window.
    private var cooldownExpiry: [String: Date] = [:]

    // Injected dependencies — optional because the engine is
    // constructed eagerly at app launch (so SwiftUI's env-object
    // lookup never fails) and `attach(...)` wires the stores once
    // the @StateObject deps exist. Every public method that needs
    // a store guards on nil and no-ops cleanly.
    private var configStore: AutoTraderConfigStore?
    private var analysisStore: AnalysisStore?
    private var tradeStore: TradeStore?
    private var news: NewsStore?
    private var paperBalance: PaperBalance?

    /// Closure the dashboard sets in `.task` so the engine can
    /// load OHLC candles for an arbitrary (pair, timeframe). Used
    /// to fire Confluence Trade Scanner autonomously after a trade closes — the
    /// engine bundles 15m/1h/4h and calls `analysisStore.runConfluenceScanner`
    /// without the user needing to open the analysis page.
    var candleLoader: ((String, Timeframe) async -> [Candle])?

    /// Closure the dashboard wires up so the engine can read the
    /// freshest live price for a pair without coupling to
    /// YahooScheduler directly. Used by continuous-mode validation
    /// to decide if a staged scenario is still reachable.
    var livePriceProvider: ((String) -> Double?)?

    /// Engine selection — defaults to Claude. Lifted to the same
    /// AppStorage the analysis page reads from so a model swap in
    /// Settings affects auto-trader runs too.
    private var selectedEngine: AIEngineKind {
        let raw = UserDefaults.standard.string(forKey: "ai.engine") ?? "opencode"
        return AIEngineKind(rawValue: raw) ?? .opencode
    }

    private var cancellables = Set<AnyCancellable>()
    /// Debounce token for the post-close re-analysis fire. We wait
    /// ~30s after a close so the OHLC settles before the next read.
    private var reAnalyzeTimer: [String: DispatchSourceTimer] = [:]

    // ── Continuous-mode state ─────────────────────────────────────
    /// Single timer driving the "trade assistant pro" loop. Wakes
    /// every 30s, looks for bar-close crossings + invalidation
    /// triggers across every continuous-mode pair.
    private var continuousTimer: DispatchSourceTimer?
    /// Last wall-clock the continuous tick ran. Used to detect
    /// which TF bar boundaries were crossed in the window.
    private var lastContinuousTickAt: Date = Date()
    /// When the most recent CTS run for a pair completed (or
    /// started — whichever's relevant for the rate limit + the
    /// "refresh in Xm" countdown).
    private var lastAnalysisAtByPair: [String: Date] = [:]
    /// Rolling window of recent run timestamps per pair — anything
    /// older than 1h is pruned. `count >= maxRunsPerHour` blocks
    /// the next continuous trigger.
    private var recentRunTimestampsByPair: [String: [Date]] = [:]
    /// Hash of the (rounded) closes that fed the last CTS run,
    /// per pair. If the next continuous-tick's would-be input
    /// produces the same hash, we skip the run — market hasn't
    /// moved meaningfully, the model would say the same thing.
    private var lastRunInputHashByPair: [String: Int] = [:]
    /// Cached "why we're not re-running right now" for the UI
    /// status line. Drives the COOLDOWN / STALE / PAUSED labels
    /// without re-evaluating every render.
    private var continuousNoteByPair: [String: String] = [:]

    init() {
        // Seed all known pairs to idle so `displayState(for:)` and
        // similar read paths return sensible values before
        // `attach(...)` runs.
        for def in TradingPair.catalog {
            stateByPair[def.id] = .idle
        }
    }

    /// Wire the engine's dependencies after the surrounding
    /// `@StateObject`s exist. Idempotent — subsequent calls
    /// no-op. Called from `HelixTradingApp`'s boot `.task`.
    func attach(
        configStore: AutoTraderConfigStore,
        analysisStore: AnalysisStore,
        tradeStore: TradeStore,
        news: NewsStore,
        paperBalance: PaperBalance
    ) {
        guard self.configStore == nil else { return }
        self.configStore = configStore
        self.analysisStore = analysisStore
        self.tradeStore = tradeStore
        self.news = news
        self.paperBalance = paperBalance

        analysisStore.$history
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entries in
                self?.observeHistory(entries)
            }
            .store(in: &cancellables)

        tradeStore.$byPair
            .receive(on: DispatchQueue.main)
            .sink { [weak self] byPair in
                self?.observeTrades(byPair)
            }
            .store(in: &cancellables)

        // Warm the news cache so the safety gate has data on
        // first scenario landing.
        news.refresh()

        startContinuousTimer()
    }

    // ── Continuous-mode loop ──────────────────────────────────────

    /// Spin up the 30s tick that drives bar-close + invalidation
    /// detection across every continuous-mode pair. Idempotent.
    private func startContinuousTimer() {
        guard continuousTimer == nil else { return }
        lastContinuousTickAt = Date()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(30), repeating: .seconds(30), leeway: .seconds(2))
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.continuousTick() }
        }
        t.resume()
        continuousTimer = t
    }

    /// One pass of the continuous loop. For each enabled +
    /// continuous-mode pair: validate the staged scenario; if
    /// invalid, re-run (subject to gating); otherwise decide
    /// whether a bar close warrants a fresh run anyway.
    private func continuousTick() {
        guard let configStore = configStore else { return }
        let now = Date()

        // Bar-close crossings are per-profile (Swing watches
        // 15m/1h/4h, Scalp watches 1m/5m/15m, Position watches
        // 1h/4h/1d), so compute the set once per profile-in-use.
        let activeProfiles = Set(configStore.byPair.values.compactMap {
            $0.enabled && $0.continuousMode ? $0.strategyProfile : nil
        })
        var crossedByProfile: [StrategyProfile: Set<Timeframe>] = [:]
        for profile in activeProfiles {
            crossedByProfile[profile] = barCloseCrossings(
                from: lastContinuousTickAt,
                to: now,
                timeframes: profile.meta.timeframes
            )
        }
        lastContinuousTickAt = now

        for (pairID, cfg) in configStore.byPair {
            guard cfg.enabled, cfg.continuousMode else { continue }
            let crossed = crossedByProfile[cfg.strategyProfile] ?? []
            evaluateContinuous(pairID: pairID, crossedTFs: crossed, cfg: cfg, now: now)
        }
    }

    /// Which of the given timeframes crossed a bucket boundary
    /// between `from` and `to`. Simple integer-bucket comparison —
    /// no timezone subtleties because all timeframes are POSIX-
    /// seconds modulo their bucket size.
    private func barCloseCrossings(
        from: Date,
        to: Date,
        timeframes: [Timeframe]
    ) -> Set<Timeframe> {
        var crossed: Set<Timeframe> = []
        for tf in timeframes {
            let bucket = Double(tfBucketSeconds(tf))
            guard bucket > 0 else { continue }
            let fromBucket = floor(from.timeIntervalSince1970 / bucket)
            let toBucket   = floor(to.timeIntervalSince1970   / bucket)
            if toBucket > fromBucket { crossed.insert(tf) }
        }
        return crossed
    }

    /// Bucket size in seconds for the timeframes we watch on the
    /// continuous loop. Mirrors the values in `Timeframe.seconds`
    /// without taking a dep on that side of the codebase.
    private func tfBucketSeconds(_ tf: Timeframe) -> Int {
        switch tf {
        case .m1:  return 60
        case .m5:  return 300
        case .m15: return 900
        case .m30: return 1800
        case .h1:  return 3600
        case .h4:  return 14400
        case .d1:  return 86400
        }
    }

    /// The heart of the continuous loop. Validation first (per the
    /// "first check if the last analysis is still ok" requirement);
    /// only re-runs when the prior is unactionable OR a bar close
    /// of sufficient weight has arrived. All triggers funnel
    /// through `canRunNow` for rate-limit + active-trade gating.
    private func evaluateContinuous(
        pairID: String,
        crossedTFs: Set<Timeframe>,
        cfg: AutoTraderConfig,
        now: Date
    ) {
        // Active trade lock: we don't second-guess a position once
        // it's open. The post-close path already runs CTS again.
        if hasOpenAutoTrade(pairID: pairID) {
            continuousNoteByPair[pairID] = "Holding position"
            return
        }

        // Cooldown / kill switch — both already drive stateByPair;
        // the cooldown branch is also a gate here so we don't fire
        // the analysis while still pausing for losses.
        if inCooldown(pairID: pairID) {
            continuousNoteByPair[pairID] = "In cooldown"
            return
        }

        // Validate the prior scenario first. If it's still in play
        // and the bar close wasn't a heavy one, keep it.
        let validation = validateCurrentAnalysis(pairID: pairID, now: now)

        if !validation.isValid {
            continuousNoteByPair[pairID] = validation.reason
            if canRunNow(pairID: pairID, cfg: cfg) {
                triggerContinuousReanalyze(pairID: pairID, reason: validation.reason)
            }
            return
        }

        // Current analysis is still valid. Re-run only when a bar
        // close says so. Generalised to the active profile's
        // [low, mid, high] timeframes:
        //   • high close → always (structural shift)
        //   • mid close → if prior > 20 min old
        //   • low close → if prior > stalenessMinutes old
        let tfs = cfg.strategyProfile.meta.timeframes
        let low = tfs.first ?? .m15
        let mid = tfs.count > 1 ? tfs[1] : .h1
        let high = tfs.last ?? .h4
        let prior = lastAnalysisAtByPair[pairID] ?? .distantPast
        let elapsed = now.timeIntervalSince(prior)
        var reason: String?
        if crossedTFs.contains(high) {
            reason = "\(high.label) bar closed"
        } else if crossedTFs.contains(mid), elapsed > 20 * 60 {
            reason = "\(mid.label) bar closed"
        } else if crossedTFs.contains(low), elapsed > Double(cfg.stalenessMinutes * 60) {
            reason = "\(low.label) bar closed (prior \(Int(elapsed / 60))m old)"
        }

        guard let bumpReason = reason else {
            // Nothing to do — record a friendly note for the UI.
            let nextRefreshMins = nextRefreshETA(prior: prior, cfg: cfg, now: now)
            if let mins = nextRefreshMins {
                continuousNoteByPair[pairID] = "Valid · refresh in \(mins)m"
            } else {
                continuousNoteByPair[pairID] = "Valid"
            }
            return
        }

        guard canRunNow(pairID: pairID, cfg: cfg) else {
            continuousNoteByPair[pairID] = "Rate limited · skipping \(bumpReason)"
            return
        }
        triggerContinuousReanalyze(pairID: pairID, reason: bumpReason)
    }

    /// Quick "what's still actionable about the staged scenario?"
    /// check. Returns invalid when:
    ///   • no prior scenario exists at all (cold start),
    ///   • the live price has already touched the TP (setup played
    ///     out without us — same idea as the trade-side
    ///     `.invalidatedNoFill`),
    ///   • the live price has touched the SL (structurally broken),
    ///   • the live price has drifted further than
    ///     `stalenessPricePercent` from the scenario entry — the
    ///     setup is no longer reachable.
    struct ValidationResult {
        let isValid: Bool
        let reason: String
    }

    private func validateCurrentAnalysis(pairID: String, now: Date) -> ValidationResult {
        guard let scenario = lastScenarioByPair[pairID] else {
            return ValidationResult(isValid: false, reason: "No prior analysis")
        }
        guard let live = livePriceProvider?(pairID), live > 0 else {
            // Can't validate without a live price — treat as valid
            // (the bar-close path still drives refreshes).
            return ValidationResult(isValid: true, reason: "")
        }
        let cfg = configStore?.config(for: pairID) ?? .default

        // For LONG: tp > entry > sl. For SHORT: sl > entry > tp.
        let isLong = scenario.bias == .long
        let tp = scenario.takeProfit
        let sl = scenario.stopLoss

        if isLong {
            if live >= tp { return ValidationResult(isValid: false, reason: "Price hit TP without fill") }
            if live <= sl { return ValidationResult(isValid: false, reason: "Price hit SL — setup broken") }
        } else if scenario.bias == .short {
            if live <= tp { return ValidationResult(isValid: false, reason: "Price hit TP without fill") }
            if live >= sl { return ValidationResult(isValid: false, reason: "Price hit SL — setup broken") }
        }

        // Stale entry zone: price too far from entry to fill.
        if let entry = scenario.entry, entry > 0 {
            let pct = abs(live - entry) / entry * 100
            if pct > cfg.stalenessPricePercent {
                return ValidationResult(
                    isValid: false,
                    reason: String(format: "Price %.2f%% off entry — setup unreachable", pct)
                )
            }
        }

        return ValidationResult(isValid: true, reason: "")
    }

    /// Rate-limit + same-read suppression check. The active-trade
    /// + cooldown gates live in `evaluateContinuous` so this is
    /// strictly about *throttling*, not *blocking on state*.
    private func canRunNow(pairID: String, cfg: AutoTraderConfig) -> Bool {
        let now = Date()
        let recent = (recentRunTimestampsByPair[pairID] ?? [])
            .filter { now.timeIntervalSince($0) < 3600 }
        recentRunTimestampsByPair[pairID] = recent
        if recent.count >= cfg.maxRunsPerHour { return false }
        if let session = analysisStore?.session(kind: .confluenceScanner, pairID: pairID),
           session.phase == .running {
            return false  // already streaming, don't queue a parallel
        }
        return true
    }

    /// Whether an auto-trader-staged trade is currently open
    /// (pending or active) for this pair. Pre-existing manual
    /// trades from other surfaces don't count — only ones with a
    /// `sourceHistoryEntryID`, which is the auto-trader's signal.
    private func hasOpenAutoTrade(pairID: String) -> Bool {
        guard let trades = tradeStore?.byPair[pairID] else { return false }
        return trades.contains { t in
            t.sourceHistoryEntryID != nil && !t.isClosed
        }
    }

    /// Fire a fresh CTS run for the pair, stamping the run-
    /// rate-limit counters. Wraps `triggerConfluenceScanner` with
    /// the bookkeeping the continuous loop needs.
    private func triggerContinuousReanalyze(pairID: String, reason: String) {
        recentRunTimestampsByPair[pairID, default: []].append(Date())
        lastAnalysisAtByPair[pairID] = Date()
        continuousNoteByPair[pairID] = "Re-analyzing: \(reason)"
        triggerConfluenceScanner(for: pairID)
    }

    /// Approximate minutes until the next scheduled bar-close
    /// trigger could fire for this pair. Reads the profile's
    /// fastest TF as the floor (Scalp = 1m, Swing = 15m,
    /// Position = 1h).
    private func nextRefreshETA(prior: Date, cfg: AutoTraderConfig, now: Date) -> Int? {
        let fastest = cfg.strategyProfile.meta.timeframes.first ?? .m15
        let bucket = Double(tfBucketSeconds(fastest))
        let secsSinceBucketStart = now.timeIntervalSince1970.truncatingRemainder(dividingBy: bucket)
        let secsUntilNextClose = bucket - secsSinceBucketStart
        return max(0, Int((secsUntilNextClose / 60).rounded()))
    }

    // ── Inputs: history observer ──────────────────────────────────

    private func observeHistory(_ entries: [AnalysisStore.HistoryEntry]) {
        for entry in entries {
            guard entry.kind == .confluenceScanner else { continue }

            // Update the "last analysis at" stamp on every fresh
            // CTS entry so the continuous loop's bar-close +
            // staleness logic has an accurate reference, regardless
            // of who triggered the run (engine, user, or expand).
            if !stagedEntryIDs.contains(entry.id) {
                lastAnalysisAtByPair[entry.pairID] = entry.date
            }

            // Scored-scenarios path: stage the top-ranked, stash the
            // rest as the fallback queue.
            if let scored = entry.scoredScenarios,
               !scored.isEmpty,
               !seededQueueFromEntry.contains(entry.id)
            {
                seededQueueFromEntry.insert(entry.id)
                stagedEntryIDs.insert(entry.id)
                let pairID = entry.pairID
                let head = scored[0]
                let rest = Array(scored.dropFirst())
                scenarioQueueByPair[pairID] = rest
                currentScenarioRankByPair[pairID] = 1
                currentScenarioTotalByPair[pairID] = scored.count
                sourceEntryByPair[pairID] = entry.id
                lastScenarioByPair[pairID] = head.scenario
                lastAltByPair[pairID] = rest.first?.scenario
                guard head.scenario.entry != nil else { continue }
                stageScenario(head.scenario, alt: rest.first?.scenario, from: entry)
                continue
            }

            // Legacy single-scenario path (Confluence Trade Scanner runs predating
            // the scored output, or scored parse failure).
            guard let scenario = entry.taScenario,
                  scenario.entry != nil,
                  !stagedEntryIDs.contains(entry.id)
            else { continue }
            stagedEntryIDs.insert(entry.id)
            scenarioQueueByPair[entry.pairID] = []
            currentScenarioRankByPair[entry.pairID] = nil
            currentScenarioTotalByPair[entry.pairID] = nil
            sourceEntryByPair[entry.pairID] = entry.id
            lastScenarioByPair[entry.pairID] = scenario
            lastAltByPair[entry.pairID] = entry.taAltScenario
            stageScenario(scenario, alt: entry.taAltScenario, from: entry)
        }
    }

    private func stageScenario(
        _ scenario: PromptBuilder.TAScenario,
        alt: PromptBuilder.TAScenario?,
        from entry: AnalysisStore.HistoryEntry
    ) {
        guard let configStore = configStore else { return }
        let pairID = entry.pairID
        let cfg = configStore.config(for: pairID)

        guard cfg.enabled else { return }
        guard let gateError = safetyGate(pairID: pairID, scenario: scenario) else {
            placeOrder(scenario: scenario, entry: entry, cfg: cfg)
            return
        }
        stateByPair[pairID] = .killed(reason: gateError)
    }

    // ── Outputs: place order (paper or live) ─────────────────────

    private func placeOrder(
        scenario: PromptBuilder.TAScenario,
        entry: AnalysisStore.HistoryEntry,
        cfg: AutoTraderConfig
    ) {
        guard let tradeStore = tradeStore else { return }
        let pairID = entry.pairID
        guard let entryPx = scenario.entry else { return }
        let side: Trade.Side = {
            switch scenario.bias {
            case .long:    return .long
            case .short:   return .short
            case .neutral: return .neutral
            }
        }()

        // Lot sizing — risk %-driven. Paper mode uses the running
        // paper balance (losses compound: a 1% risk after three
        // losses is smaller in absolute dollars than before).
        // Live mode falls back to the user-settable account balance
        // since the broker's equity isn't visible here.
        let balance: Double = {
            if cfg.paperMode, let pb = paperBalance {
                return pb.currentBalance
            }
            let live = UserDefaults.standard.double(forKey: "trade.accountBalance")
            return live > 0 ? live : 10_000
        }()
        let slDistance = abs(entryPx - scenario.stopLoss)
        guard slDistance > 0 else { return }
        let target = balance * (cfg.riskPercent / 100)
        let lots = max(0.01, (target / (slDistance * 100) * 100).rounded() / 100)

        let trade = Trade(
            id: UUID(),
            pairID: pairID,
            sourceHistoryEntryID: entry.id,
            isPaper: true,     // paper-only build — no broker transport
            liveOrderID: nil,
            side: side,
            entry: entryPx,
            takeProfit: scenario.takeProfit,
            stopLoss: scenario.stopLoss,
            lots: lots,
            createdAt: Date(),
            status: .pending,
            visible: true
        )

        tradeStore.add(trade, for: pairID)
        stateByPair[pairID] = .staged(scenarioID: scenario.id, expectingFill: true)
    }

    // ── Inputs: trade observer → re-trigger ──────────────────────

    private func observeTrades(_ byPair: [String: [Trade]]) {
        guard let configStore = configStore else { return }
        for (pairID, trades) in byPair {
            // First pass: reflect open trade status onto the state
            // badge. If any auto-tradered trade is active, the pair
            // is ACTIVE; else if any is pending, STAGED; else
            // leave whatever the state machine already had (idle
            // / cooldown / killed).
            let autoTrades = trades.filter { $0.sourceHistoryEntryID != nil }
            if let activeOne = autoTrades.first(where: { $0.status == .active }) {
                let sid = lastScenarioByPair[pairID]?.id ?? activeOne.id.uuidString
                stateByPair[pairID] = .active(scenarioID: sid)
            } else if let pendingOne = autoTrades.first(where: { $0.status == .pending }) {
                let sid = lastScenarioByPair[pairID]?.id ?? pendingOne.id.uuidString
                stateByPair[pairID] = .staged(scenarioID: sid, expectingFill: true)
            }

            // Second pass: closed-trade reactions, once per trade.
            for trade in trades {
                guard trade.isClosed,
                      trade.sourceHistoryEntryID != nil,
                      !reactedTradeIDs.contains(trade.id)
                else { continue }
                reactedTradeIDs.insert(trade.id)

                let cfg = configStore.config(for: pairID)

                // Consecutive-loss cooldown: count the trailing
                // run of SL closes on this pair.
                if trade.status == .closedHitSL {
                    let recentClosed = trades
                        .filter { $0.isClosed }
                        .sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }
                    let trailingLosses = recentClosed
                        .prefix(while: { $0.status == .closedHitSL })
                        .count
                    if trailingLosses >= cfg.cooldownAfterConsecutiveLosses {
                        let until = Date().addingTimeInterval(60 * 60)
                        cooldownExpiry[pairID] = until
                        stateByPair[pairID] = .cooldown(until: until)
                        // Cooldown wipes the queue — we want a fresh
                        // read once it lifts, not stale fallbacks.
                        scenarioQueueByPair[pairID] = []
                        continue
                    }
                }

                // Invalidation = SL hit, OR pending cancelled because
                // TP touched before the limit filled. Both mean the
                // scenario is dead; try the next queued one before
                // burning a fresh analysis.
                let invalidated = trade.status == .closedHitSL
                    || (trade.status == .cancelled
                        && trade.closeReason == .invalidatedNoFill)

                if invalidated,
                   var queue = scenarioQueueByPair[pairID],
                   !queue.isEmpty,
                   let sourceID = sourceEntryByPair[pairID],
                   let sourceEntry = analysisStore?.history.first(where: { $0.id == sourceID })
                {
                    let next = queue.removeFirst()
                    scenarioQueueByPair[pairID] = queue
                    currentScenarioRankByPair[pairID] = (currentScenarioRankByPair[pairID] ?? 1) + 1
                    lastScenarioByPair[pairID] = next.scenario
                    lastAltByPair[pairID] = queue.first?.scenario
                    guard next.scenario.entry != nil else {
                        // Skip malformed fallback, schedule fresh run.
                        if cfg.enabled {
                            stateByPair[pairID] = .idle
                            scheduleReAnalysis(for: pairID, delay: 30)
                        }
                        continue
                    }
                    stageScenario(next.scenario, alt: queue.first?.scenario, from: sourceEntry)
                    continue
                }

                // Queue exhausted (or TP / manual close): schedule
                // the next Confluence Trade Scanner run after a short settle delay
                // so the OHLC stream has caught up. Replaces any
                // in-flight scheduled re-run (latest close wins).
                if cfg.enabled {
                    stateByPair[pairID] = .idle
                    scenarioQueueByPair[pairID] = []
                    scheduleReAnalysis(for: pairID, delay: 30)
                }
            }
        }
    }

    // ── Auto-trigger Confluence Trade Scanner ─────────────────────────────────────

    /// Schedule a Confluence Trade Scanner run for `pairID` after `delay` seconds.
    /// Debounced — the latest call wins, so a flurry of trade
    /// closes only fires one analysis. Skipped silently when
    /// there's no candle loader (engine boots before dashboard
    /// attaches) — the user can still kick a run from the page.
    private func scheduleReAnalysis(for pairID: String, delay: TimeInterval) {
        reAnalyzeTimer[pairID]?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + delay)
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.triggerConfluenceScanner(for: pairID)
            }
        }
        t.resume()
        reAnalyzeTimer[pairID] = t
    }

    /// Headless Confluence Trade Scanner fire — loads the 15m/1h/4h bundle via
    /// the dashboard-attached `candleLoader` and routes through
    /// `analysisStore.runConfluenceScanner` with the prior-run hint baked
    /// in. No-op when the loader isn't attached or the pair isn't
    /// in the catalog.
    func triggerConfluenceScanner(for pairID: String) {
        guard let loader = candleLoader,
              let analysisStore = analysisStore
        else { return }
        guard let pairDef = TradingPair.catalog.first(where: { $0.id == pairID }) else { return }
        let pair = TradingPair(
            id: pairDef.id, name: pairDef.name, symbol: pairDef.symbol,
            price: 0, change: 0, changePercent: 0, high24h: 0, low24h: 0,
            isOnline: true, colorHex: pairDef.colorHex, category: pairDef.category
        )
        let session = analysisStore.session(kind: .confluenceScanner, pairID: pairID)
        if session.phase == .running { return }

        let hint = priorRunHint(for: pairID)
        // Bundle the profile's three timeframes (Swing = 15m/1h/4h,
        // Scalp = 1m/5m/15m, Position = 1h/4h/1d). Falls back to
        // the swing default if config can't be reached.
        let profile = configStore?.config(for: pairID).strategyProfile ?? .swing
        let tfs: [Timeframe] = profile.meta.timeframes
        Task { [weak self] in
            var bundle: [(Timeframe, [Candle])] = []
            for tf in tfs {
                let cs = await loader(pairID, tf)
                bundle.append((tf, cs))
            }
            await MainActor.run {
                guard let self = self else { return }
                // Same-read suppression: hash the last 5 closes per
                // TF; if identical to the prior run's input, skip.
                // Market hasn't moved enough to change the read —
                // the model would just produce the same scenario.
                let inputHash = self.hashBundle(bundle)
                if self.lastRunInputHashByPair[pairID] == inputHash {
                    self.continuousNoteByPair[pairID] = "Market unchanged · skipped"
                    return
                }
                self.lastRunInputHashByPair[pairID] = inputHash
                analysisStore.runConfluenceScanner(
                    engineKind: self.selectedEngine,
                    pair: pair,
                    candlesByTF: bundle,
                    priorRunHint: hint,
                    horizonHint: profile.meta.horizonText
                )
            }
        }
    }

    /// Cheap content-hash of a candle bundle's tail. Combines the
    /// last 5 closes per TF, rounded to 4 decimals so float noise
    /// doesn't bust the hash. Used by the same-read suppression
    /// gate in `triggerConfluenceScanner`.
    private func hashBundle(_ bundle: [(Timeframe, [Candle])]) -> Int {
        var hasher = Hasher()
        for (tf, candles) in bundle {
            hasher.combine(tf.rawValue)
            for c in candles.suffix(5) {
                hasher.combine((c.close * 10_000).rounded())
            }
        }
        return hasher.finalize()
    }

    /// User flipped the per-pair toggle ON. Reuse the most recent
    /// Confluence Trade Scanner history entry when it's still fresh (< 60min) and
    /// hasn't been fully resolved, instead of burning another LLM
    /// call. Falls back to a fresh `triggerConfluenceScanner` when there's
    /// nothing reusable.
    func kickstart(for pairID: String) {
        guard let configStore = configStore,
              configStore.config(for: pairID).enabled
        else { return }
        if let entry = mostRecentReusableEntry(for: pairID) {
            resumeFromEntry(entry, pairID: pairID)
            return
        }
        triggerConfluenceScanner(for: pairID)
    }

    private func mostRecentReusableEntry(for pairID: String) -> AnalysisStore.HistoryEntry? {
        guard let analysisStore = analysisStore else { return nil }
        let recent = analysisStore.history
            .filter { $0.pairID == pairID && $0.kind == .confluenceScanner }
            .max { $0.date < $1.date }
        guard let entry = recent,
              Date().timeIntervalSince(entry.date) < 60 * 60
        else { return nil }
        return entry
    }

    /// Resume staging from an existing HistoryEntry. Three branches:
    /// (1) an auto-tradered trade for this entry is still open →
    /// nothing to do, `observeTrades` already reflects state.
    /// (2) our in-memory queue tracking still points to this entry →
    /// advance based on the most recent trade outcome (re-stage head,
    /// pop on invalidation, fresh run on success / exhaustion).
    /// (3) cold path → seed queue from scratch and stage the top.
    private func resumeFromEntry(
        _ entry: AnalysisStore.HistoryEntry,
        pairID: String
    ) {
        let tradesForEntry = (tradeStore?.byPair[pairID] ?? [])
            .filter { $0.sourceHistoryEntryID == entry.id }

        if tradesForEntry.contains(where: { !$0.isClosed }) {
            return
        }

        if sourceEntryByPair[pairID] == entry.id {
            let mostRecent = tradesForEntry
                .filter { $0.isClosed }
                .max { ($0.closedAt ?? .distantPast) < ($1.closedAt ?? .distantPast) }
            let invalidated: Bool = mostRecent.map {
                $0.status == .closedHitSL
                    || ($0.status == .cancelled && $0.closeReason == .invalidatedNoFill)
            } ?? false

            if let last = mostRecent, !invalidated {
                _ = last
                triggerConfluenceScanner(for: pairID)
                return
            }

            if invalidated,
               var queue = scenarioQueueByPair[pairID],
               !queue.isEmpty
            {
                let next = queue.removeFirst()
                scenarioQueueByPair[pairID] = queue
                currentScenarioRankByPair[pairID] = (currentScenarioRankByPair[pairID] ?? 1) + 1
                lastScenarioByPair[pairID] = next.scenario
                lastAltByPair[pairID] = queue.first?.scenario
                guard next.scenario.entry != nil else {
                    triggerConfluenceScanner(for: pairID)
                    return
                }
                stageScenario(next.scenario, alt: queue.first?.scenario, from: entry)
                return
            }

            if invalidated {
                triggerConfluenceScanner(for: pairID)
                return
            }

            if let lastScenario = lastScenarioByPair[pairID],
               lastScenario.entry != nil
            {
                stageScenario(lastScenario, alt: lastAltByPair[pairID], from: entry)
                return
            }
        }

        seedFromEntry(entry, pairID: pairID)
    }

    /// Cold-path seed from a HistoryEntry — fills the queue, sets
    /// tracking fields, and stages the top-ranked scenario. Mirrors
    /// the `observeHistory` seeding path but driven by `kickstart`
    /// instead of a fresh `history` emission.
    private func seedFromEntry(
        _ entry: AnalysisStore.HistoryEntry,
        pairID: String
    ) {
        if let scored = entry.scoredScenarios, !scored.isEmpty {
            let head = scored[0]
            let rest = Array(scored.dropFirst())
            scenarioQueueByPair[pairID] = rest
            currentScenarioRankByPair[pairID] = 1
            currentScenarioTotalByPair[pairID] = scored.count
            sourceEntryByPair[pairID] = entry.id
            lastScenarioByPair[pairID] = head.scenario
            lastAltByPair[pairID] = rest.first?.scenario
            seededQueueFromEntry.insert(entry.id)
            stagedEntryIDs.insert(entry.id)
            guard head.scenario.entry != nil else {
                triggerConfluenceScanner(for: pairID)
                return
            }
            stageScenario(head.scenario, alt: rest.first?.scenario, from: entry)
            return
        }

        if let scenario = entry.taScenario, scenario.entry != nil {
            scenarioQueueByPair[pairID] = []
            currentScenarioRankByPair[pairID] = nil
            currentScenarioTotalByPair[pairID] = nil
            sourceEntryByPair[pairID] = entry.id
            lastScenarioByPair[pairID] = scenario
            lastAltByPair[pairID] = entry.taAltScenario
            stagedEntryIDs.insert(entry.id)
            stageScenario(scenario, alt: entry.taAltScenario, from: entry)
            return
        }

        triggerConfluenceScanner(for: pairID)
    }

    private func inCooldown(pairID: String) -> Bool {
        guard let until = cooldownExpiry[pairID] else { return false }
        return Date() < until
    }

    // ── Safety gates ──────────────────────────────────────────────

    /// Returns nil when the order is safe to place; otherwise the
    /// reason as a short string for the state badge.
    private func safetyGate(
        pairID: String,
        scenario: PromptBuilder.TAScenario
    ) -> String? {
        guard let configStore = configStore else { return nil }
        let cfg = configStore.config(for: pairID)

        if inCooldown(pairID: pairID) {
            return "Cooldown after losses"
        }

        if let analysisStore = analysisStore {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            let todayPL = analysisStore.history
                .filter { ($0.outcomeAt ?? $0.date) >= today }
                .reduce(0.0) { $0 + ($1.outcomeRealisedPL ?? 0) }
            let balance = max(1, UserDefaults.standard.double(forKey: "trade.accountBalance"))
            let lossPct = (todayPL < 0 ? -todayPL : 0) / balance * 100
            if lossPct >= cfg.maxDailyLossPercent {
                return "Daily loss limit hit (\(String(format: "%.1f", lossPct))%)"
            }
        }

        if cfg.pauseDuringHighImpactNews, let news = news {
            let now = Date()
            let window: TimeInterval = 15 * 60
            let nearEvent = news.events.contains { event in
                guard event.impactLevel == .high,
                      event.currency.uppercased() == "USD",
                      let at = event.eventAt
                else { return false }
                return abs(at.timeIntervalSince(now)) <= window
            }
            if nearEvent { return "Paused for upcoming USD event" }
        }

        if let tradeStore = tradeStore {
            let openCount = (tradeStore.byPair[pairID] ?? [])
                .filter { !$0.isClosed }
                .count
            if openCount >= cfg.maxConcurrentPositions {
                return "Concurrent-position cap reached"
            }
        }

        return nil
    }

    // ── Public helpers (UI) ───────────────────────────────────────

    /// Compose the prior-run hint to feed into the next Confluence Trade Scanner
    /// re-run for this pair. Returns nil when there's nothing to
    /// hint about (no prior scenario, or the scenario is stale
    /// >60min).
    func priorRunHint(for pairID: String) -> PromptBuilder.PriorRunHint? {
        guard let scenario = lastScenarioByPair[pairID],
              let analysisStore = analysisStore
        else { return nil }
        let matching: AnalysisStore.HistoryEntry?
        if let sourceID = sourceEntryByPair[pairID] {
            matching = analysisStore.history.first { $0.id == sourceID }
        } else {
            matching = analysisStore.history.first { $0.taScenario?.id == scenario.id }
        }
        // Walk the trade list for this pair to see if the matching
        // trade was invalidated (TP hit before the limit filled)
        // — distinct from a generic cancellation since the setup
        // played out, just without us.
        let trades = tradeStore?.trades(for: matching?.pairID ?? pairID) ?? []
        let invalidatedNoFill = trades.contains { t in
            t.sourceHistoryEntryID == matching?.id
                && t.status == .cancelled
                && t.closeReason == .invalidatedNoFill
        }
        // Append a queue-exhaustion suffix when the prior run had
        // multiple scored scenarios and the queue is now empty —
        // signals to the model that the whole read was wrong, not
        // just the top pick.
        let queueSuffix: String = {
            let total = currentScenarioTotalByPair[pairID] ?? 0
            let queueEmpty = (scenarioQueueByPair[pairID] ?? []).isEmpty
            guard total > 1, queueEmpty else { return "" }
            return " — all \(total) scored scenarios from the prior read were tried and invalidated, regime likely shifted."
        }()
        let outcome: String = {
            if invalidatedNoFill {
                return "INVALIDATED — price ran straight to TP without filling the limit. The setup played out without us; the entry zone was wrong." + queueSuffix
            }
            switch matching?.outcome {
            case .hitTP:     return "hit TP" + queueSuffix
            case .hitSL:     return "stopped out at SL" + queueSuffix
            case .manual:    return "closed manually" + queueSuffix
            case .cancelled: return "cancelled before fill" + queueSuffix
            case .none:      return "still open or never activated"
            }
        }()
        return PromptBuilder.PriorRunHint(
            main: scenario,
            alt: lastAltByPair[pairID],
            outcome: outcome
        )
    }

    /// Quick state read for the dashboard's AUTO pill.
    /// "ANALYZING" wins over the underlying state machine when a
    /// Confluence Trade Scanner session is actively streaming — the AI run is the
    /// most informative thing to surface in that moment.
    func displayState(for pairID: String) -> (label: String, color: Color) {
        guard let configStore = configStore else {
            return ("OFF", Theme.Color.textMuted)
        }
        let cfg = configStore.config(for: pairID)
        guard cfg.enabled else { return ("OFF", Theme.Color.textMuted) }
        if let analysisStore = analysisStore,
           analysisStore.session(kind: .confluenceScanner, pairID: pairID).phase == .running
        {
            return ("ANALYZING", Theme.Color.accentStart)
        }
        let liveTint: Color = cfg.paperMode ? Theme.Color.warn : Theme.Color.danger
        let rankSuffix: String = {
            guard let rank = currentScenarioRankByPair[pairID],
                  let total = currentScenarioTotalByPair[pairID],
                  total > 1
            else { return "" }
            return " \(rank)/\(total)"
        }()
        switch stateByPair[pairID] ?? .idle {
        case .idle:                  return ("IDLE", liveTint)
        case .staged:                return ("STAGED" + rankSuffix, liveTint)
        case .active:                return ("ACTIVE" + rankSuffix, liveTint)
        case .cooldown:              return ("COOLDOWN", Theme.Color.textMuted)
        case .killed(let reason):    return (reason.uppercased(), Theme.Color.danger)
        }
    }

    // ── Rich continuous-mode status (dashboard banner) ────────────

    /// Pro-trader status line for the dashboard banner. Combines
    /// the underlying state machine with the continuous loop's
    /// note ("Valid · refresh in 8m", "Price 1.9% off entry —
    /// re-analyzing", etc.) so the user always sees what the
    /// engine is thinking right now.
    struct ContinuousStatus {
        let label: String
        let detail: String
        let color: Color
    }

    func continuousStatus(for pairID: String) -> ContinuousStatus {
        guard let configStore = configStore else {
            return ContinuousStatus(label: "OFF", detail: "", color: Theme.Color.textMuted)
        }
        let cfg = configStore.config(for: pairID)
        guard cfg.enabled else {
            return ContinuousStatus(label: "OFF", detail: "Auto-trader disabled", color: Theme.Color.textMuted)
        }

        // Underlying-state lookup, mirroring displayState's
        // priorities so the badge + banner stay in lockstep.
        let liveTint: Color = cfg.paperMode ? Theme.Color.warn : Theme.Color.danger

        if let analysisStore = analysisStore,
           analysisStore.session(kind: .confluenceScanner, pairID: pairID).phase == .running
        {
            let detail = continuousNoteByPair[pairID] ?? "Streaming Confluence Trade Scanner output…"
            return ContinuousStatus(label: "ANALYZING", detail: detail, color: Theme.Color.accentStart)
        }

        let state = stateByPair[pairID] ?? .idle
        let note = continuousNoteByPair[pairID] ?? ""

        switch state {
        case .killed(let reason):
            return ContinuousStatus(label: "KILL-SWITCH", detail: reason, color: Theme.Color.danger)

        case .cooldown(let until):
            let mins = max(0, Int(until.timeIntervalSinceNow / 60))
            return ContinuousStatus(label: "COOLDOWN", detail: "Resumes in \(mins)m", color: Theme.Color.textMuted)

        case .active:
            let detail = scenarioSummary(for: pairID).map { "Holding \($0)" } ?? "Position open"
            return ContinuousStatus(label: "ACTIVE", detail: detail, color: liveTint)

        case .staged:
            let detail = scenarioSummary(for: pairID).map { "Waiting on \($0)" } ?? "Limit pending"
            return ContinuousStatus(label: "STAGED", detail: detail, color: liveTint)

        case .idle:
            // Continuous mode running: surface the loop's last
            // assessment. Idle without continuous mode shows the
            // generic "IDLE — waiting for analysis" line.
            if cfg.continuousMode {
                let prefix = scenarioSummary(for: pairID).map { "\($0)" } ?? "No scenario yet"
                let detail = note.isEmpty ? prefix : "\(prefix) · \(note)"
                let isStale = note.contains("Re-analyzing")
                    || note.contains("unreachable")
                    || note.contains("broken")
                    || note.contains("off entry")
                return ContinuousStatus(
                    label: isStale ? "STALE" : "LIVE",
                    detail: detail,
                    color: isStale ? Theme.Color.warn : liveTint
                )
            }
            return ContinuousStatus(label: "IDLE", detail: "Waiting for next run", color: liveTint)
        }
    }

    /// One-line summary of the currently-staged scenario, e.g.
    /// "Long 4710 → 4820". nil when nothing's staged yet.
    private func scenarioSummary(for pairID: String) -> String? {
        guard let s = lastScenarioByPair[pairID], let entry = s.entry else { return nil }
        let side = s.bias.rawValue.capitalized
        let arrow = s.bias == .short ? "↓" : "↑"
        return "\(side) \(fmtPrice(entry)) \(arrow) \(fmtPrice(s.takeProfit))"
    }

    private func fmtPrice(_ v: Double) -> String {
        if v >= 1000 { return String(format: "%.0f", v) }
        if v >= 1    { return String(format: "%.2f", v) }
        return String(format: "%.4f", v)
    }
}
