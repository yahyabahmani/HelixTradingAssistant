import Foundation
import SwiftUI
import Combine

/// Paper-trade state model + store. Drives the "Activate as trade"
/// flow from `AnalysisPanel` and tracks each trade through its
/// lifecycle (pending → active → closed*) by evaluating the live
/// price stream against TP / SL / entry levels.
///
/// No real broker integration — this is a personal-use simulator so
/// the user can see how the AI's plan would have played out.

// MARK: - Trade

/// One paper trade. Created via `ActivateTradeSheet` from an AI
/// `TAScenario`. Codable so the store can persist trades across
/// launches; mutable status / fill / close fields evolve as the
/// `TradeStore.evaluate` engine processes live ticks.
struct Trade: Identifiable, Codable, Equatable {
    let id: UUID
    let pairID: String
    /// HistoryEntry that produced this trade. Threaded back through
    /// the activation sheet so when the trade closes we can mutate
    /// the source entry's `outcome` field — that's how win-rate
    /// stats get built. Optional + `decodeIfPresent`-friendly so
    /// pre-existing persisted trades (which didn't carry this) keep
    /// loading; their outcome simply won't feed the win-rate stat.
    let sourceHistoryEntryID: UUID?
    /// True when this trade is paper-only — `TradeStore.evaluate`
    /// drives its lifecycle by replaying live ticks against
    /// entry/TP/SL. False for live trades whose lifecycle is owned
    /// by a broker integration (none in the current paper-only
    /// build; the fields remain for previously persisted trades).
    /// `decodeIfPresent`-friendly default `true` so pre-existing
    /// persisted trades (which all predate the live path) keep
    /// loading as paper.
    let isPaper: Bool
    /// Broker-side order id for `isPaper: false` trades from
    /// older builds.
    /// Used by the cBot reconciliation path to find + mutate the
    /// matching local Trade when an `order_status` event arrives.
    /// Nil for paper trades.
    let liveOrderID: String?
    /// Mirrors `TAScenario.Bias`; `.neutral` is allowed but treated
    /// as long-with-tight-stops semantically (the AI rarely emits
    /// neutral plans with both TP and SL set on the same side).
    let side: Side
    /// The price the AI proposed as entry. For Market orders this is
    /// also `fillPrice` after creation; for Pending orders it's the
    /// trigger level.
    let entry: Double
    let takeProfit: Double
    let stopLoss: Double
    /// Position size in lots where 1 lot = 100 oz (forex/CFD
    /// convention). 0.01 = 1 oz "micro", 1.0 = 100 oz "standard".
    let lots: Double
    let createdAt: Date

    var status: Status
    /// When the trade flipped from `.pending` to `.active`. For
    /// Market orders set at creation; for Pending, only after the
    /// price touched entry.
    var filledAt: Date?
    /// The price recorded when the trade filled. Used as the cost
    /// basis for P/L; never changes after fill.
    var fillPrice: Double?
    var closedAt: Date?
    var closePrice: Double?
    var closeReason: CloseReason?
    /// Layers popover visibility — false hides chart marks while
    /// preserving the trade in the store.
    var visible: Bool

    enum Side: String, Codable {
        case long, short, neutral
    }

    enum Status: String, Codable {
        case pending          // limit-style: waiting for price to touch entry
        case active           // filled, P/L tracking live
        case closedHitTP
        case closedHitSL
        case closedManually
        case cancelled        // pending trade the user cancelled before it filled
    }

    enum CloseReason: String, Codable {
        case hitTP, hitSL, manual, cancelled, trailing, reconciliation
        /// The pending order never filled because price ran to TP
        /// without retracing to entry — the setup played out
        /// without us. Treated as a `.cancelled` status (no money
        /// risked, no W/L contribution) but a distinct reason so
        /// the engine / UI can surface "Invalidated" rather than
        /// "Cancelled".
        case invalidatedNoFill
    }

    // ── Initializers ────────────────────────────────────────────────

    init(
        id: UUID,
        pairID: String,
        sourceHistoryEntryID: UUID? = nil,
        isPaper: Bool = true,
        liveOrderID: String? = nil,
        side: Side,
        entry: Double,
        takeProfit: Double,
        stopLoss: Double,
        lots: Double,
        createdAt: Date = Date(),
        status: Status,
        filledAt: Date? = nil,
        fillPrice: Double? = nil,
        closedAt: Date? = nil,
        closePrice: Double? = nil,
        closeReason: CloseReason? = nil,
        visible: Bool = true
    ) {
        self.id = id
        self.pairID = pairID
        self.sourceHistoryEntryID = sourceHistoryEntryID
        self.isPaper = isPaper
        self.liveOrderID = liveOrderID
        self.side = side
        self.entry = entry
        self.takeProfit = takeProfit
        self.stopLoss = stopLoss
        self.lots = lots
        self.createdAt = createdAt
        self.status = status
        self.filledAt = filledAt
        self.fillPrice = fillPrice
        self.closedAt = closedAt
        self.closePrice = closePrice
        self.closeReason = closeReason
        self.visible = visible
    }

    /// Custom decoder so older persisted trades (no `isPaper` /
    /// `liveOrderID` columns) keep loading — they default to paper
    /// + nil live id, matching the historical behaviour.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        pairID = try c.decode(String.self, forKey: .pairID)
        sourceHistoryEntryID = try c.decodeIfPresent(UUID.self, forKey: .sourceHistoryEntryID)
        isPaper = try c.decodeIfPresent(Bool.self, forKey: .isPaper) ?? true
        liveOrderID = try c.decodeIfPresent(String.self, forKey: .liveOrderID)
        side = try c.decode(Side.self, forKey: .side)
        entry = try c.decode(Double.self, forKey: .entry)
        takeProfit = try c.decode(Double.self, forKey: .takeProfit)
        stopLoss = try c.decode(Double.self, forKey: .stopLoss)
        lots = try c.decode(Double.self, forKey: .lots)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        status = try c.decode(Status.self, forKey: .status)
        filledAt = try c.decodeIfPresent(Date.self, forKey: .filledAt)
        fillPrice = try c.decodeIfPresent(Double.self, forKey: .fillPrice)
        closedAt = try c.decodeIfPresent(Date.self, forKey: .closedAt)
        closePrice = try c.decodeIfPresent(Double.self, forKey: .closePrice)
        closeReason = try c.decodeIfPresent(CloseReason.self, forKey: .closeReason)
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
    }

    // ── Computed helpers ─────────────────────────────────────────────

    /// Live P/L in USD. For active trades: `(price − fillPrice) × oz`
    /// (with sign flipped for shorts). For closed trades: frozen at
    /// `closePrice − fillPrice`. For pending: zero.
    func currentPL(at price: Double) -> Double {
        switch status {
        case .pending, .cancelled:
            return 0
        case .closedHitTP, .closedHitSL, .closedManually:
            guard let close = closePrice, let fill = fillPrice else { return 0 }
            return rawPL(from: fill, to: close)
        case .active:
            guard let fill = fillPrice else { return 0 }
            return rawPL(from: fill, to: price)
        }
    }

    /// Money at risk if the SL is hit, in USD. Surfaced in the
    /// activation sheet so the user sees the bite before confirming.
    var riskUSD: Double {
        abs(entry - stopLoss) * 100 * lots
    }

    /// Money to make if TP is hit, in USD.
    var rewardUSD: Double {
        abs(takeProfit - entry) * 100 * lots
    }

    /// Reward / risk ratio. Returns 0 if the SL distance is zero
    /// (defensive — Claude shouldn't emit that, but parser bugs do
    /// happen).
    var rewardToRisk: Double {
        guard riskUSD > 0 else { return 0 }
        return rewardUSD / riskUSD
    }

    /// Status colour for the Layers popover swatch + the trade's
    /// chart marks. Closed-good = bright green; closed-bad = dark
    /// red; pending = amber; active long/short = success/danger.
    var colorSwatch: Color {
        switch status {
        case .pending:                   return Theme.Color.warn
        case .active:                    return side == .short ? Theme.Color.danger : Theme.Color.success
        case .closedHitTP:               return Theme.Color.success
        case .closedHitSL:               return Theme.Color.danger
        case .closedManually:            return Theme.Color.textSecondary
        case .cancelled:                 return Theme.Color.textMuted
        }
    }

    /// Short label used in the Layers popover and chart capsules.
    var statusLabel: String {
        switch status {
        case .pending:        return "Pending"
        case .active:         return "Active"
        case .closedHitTP:    return "Hit TP"
        case .closedHitSL:    return "Hit SL"
        case .closedManually: return "Closed"
        case .cancelled:      return "Cancelled"
        }
    }

    /// Short side label — `L` / `S` / `N`.
    var sideLabel: String {
        switch side { case .long: return "L"; case .short: return "S"; case .neutral: return "N" }
    }

    /// `true` for any of the terminal `closed*` / `cancelled` cases.
    /// Used to drop trades from the chart's active-mark builder.
    var isClosed: Bool {
        switch status {
        case .closedHitTP, .closedHitSL, .closedManually, .cancelled:
            return true
        case .pending, .active:
            return false
        }
    }

    /// Internal: raw P/L without sign-flipping logic for the closed
    /// case — keeps `currentPL` readable.
    private func rawPL(from fill: Double, to current: Double) -> Double {
        let oz = 100 * lots
        switch side {
        case .long, .neutral: return (current - fill) * oz
        case .short:          return (fill - current) * oz
        }
    }
}

// MARK: - TradeStore

/// Per-pair persistent store of paper trades. Mirrors `DrawingStore`
/// for shape and persistence; adds an `evaluate(price:for:)` engine
/// that drives status transitions from price ticks.
///
/// Persisted to UserDefaults under `dashboard.trades.v1`. Capped at
/// 50 trades per pair — closed/cancelled trades count toward the cap,
/// oldest fall off first. Keeps the store bounded over months of use.
@MainActor
final class TradeStore: ObservableObject {
    @Published private(set) var byPair: [String: [Trade]] = [:]

    private static let perPairCap = 50
    private static let storageKey = "dashboard.trades.v1"

    init() {
        load()
    }

    // ── Reads ────────────────────────────────────────────────────────

    /// All trades for a pair. Returns an empty array when the pair
    /// has nothing — keeps callers null-safe.
    func trades(for pairID: String) -> [Trade] {
        byPair[pairID] ?? []
    }

    /// Convenience for the chart: open (pending or active) trades
    /// only, filtered by visibility. Closed trades stay in the
    /// store but the chart doesn't draw them — they're history.
    func openVisibleTrades(for pairID: String) -> [Trade] {
        trades(for: pairID).filter { !$0.isClosed && $0.visible }
    }

    // ── Mutations ────────────────────────────────────────────────────

    func add(_ trade: Trade, for pairID: String) {
        var list = byPair[pairID] ?? []
        list.append(trade)
        // Trim the oldest if we're over the cap. Newest in front of
        // the cap because we append (oldest at index 0).
        if list.count > Self.perPairCap {
            list = Array(list.suffix(Self.perPairCap))
        }
        byPair[pairID] = list
        save()
    }

    /// Replace an existing trade in place (matched by `id`). Used by
    /// the evaluator and any future drag-to-edit flow.
    func update(_ trade: Trade, for pairID: String) {
        guard var list = byPair[pairID],
              let idx = list.firstIndex(where: { $0.id == trade.id })
        else { return }
        list[idx] = trade
        byPair[pairID] = list
        save()
    }

    func remove(id: UUID, for pairID: String) {
        guard var list = byPair[pairID] else { return }
        list.removeAll { $0.id == id }
        if list.isEmpty {
            byPair.removeValue(forKey: pairID)
        } else {
            byPair[pairID] = list
        }
        save()
    }

    func setVisible(_ visible: Bool, id: UUID, for pairID: String) {
        guard var list = byPair[pairID],
              let idx = list.firstIndex(where: { $0.id == id })
        else { return }
        list[idx].visible = visible
        byPair[pairID] = list
        save()
    }

    /// Manually close an active trade at the supplied price (usually
    /// the latest tick). Pending trades transition to `.cancelled`.
    /// No-op for already-closed trades.
    func closeManually(id: UUID, at price: Double, for pairID: String) {
        guard var list = byPair[pairID],
              let idx = list.firstIndex(where: { $0.id == id })
        else { return }
        var t = list[idx]
        switch t.status {
        case .pending:
            t.status = .cancelled
            t.closeReason = .cancelled
            t.closedAt = Date()
        case .active:
            t.status = .closedManually
            t.closeReason = .manual
            t.closedAt = Date()
            t.closePrice = price
        case .closedHitTP, .closedHitSL, .closedManually, .cancelled:
            return
        }
        list[idx] = t
        byPair[pairID] = list
        save()
    }

    func clear(for pairID: String) {
        byPair.removeValue(forKey: pairID)
        save()
    }

    /// Wholesale replace a pair's trade list — used by the paper-
    /// balance reset flow which drops historic closed trades to
    /// re-baseline the running ledger.
    func replaceList(_ trades: [Trade], for pairID: String) {
        if trades.isEmpty {
            byPair.removeValue(forKey: pairID)
        } else {
            byPair[pairID] = trades
        }
        save()
    }

    // ── Evaluation engine ───────────────────────────────────────────

    /// Run every open trade for `pairID` against `price`. Triggers
    /// `pending → active` fills and `active → closed*` exits.
    ///
    /// **Evaluation order matters**: TP is checked *before* SL so
    /// that if both are technically touched on the same tick (rare —
    /// usually means the AI's plan was inverted) the more favourable
    /// outcome wins. The order is documented inline so future-us
    /// doesn't reverse it accidentally.
    func evaluate(price: Double, for pairID: String) {
        guard var list = byPair[pairID] else { return }
        var changed = false
        for idx in list.indices {
            var t = list[idx]
            // Critical invariant: live trades are owned by the cBot.
            // Their state transitions arrive via `order_status` events
            // through a broker integration and get applied via
            // `applyLiveOrderStatus(...)`. Replaying our local tick
            // stream against them would race the broker's own fill
            // confirmation and produce desynced state.
            if !t.isPaper { continue }
            switch t.status {
            case .pending:
                if hasTouchedEntry(price: price, trade: t) {
                    t.status = .active
                    t.filledAt = Date()
                    t.fillPrice = t.entry
                    list[idx] = t
                    changed = true
                } else if hasTouchedTP(price: price, trade: t) {
                    // The setup played out without us — price ran
                    // straight to TP without retracing to the
                    // entry. Marking cancelled so it drops out of
                    // open-trade scans; reason = `.invalidatedNoFill`
                    // so the engine + UI distinguish this from a
                    // user-cancelled pending.
                    t.status = .cancelled
                    t.closeReason = .invalidatedNoFill
                    t.closedAt = Date()
                    list[idx] = t
                    changed = true
                }
            case .active:
                if hasTouchedTP(price: price, trade: t) {
                    t.status = .closedHitTP
                    t.closeReason = .hitTP
                    t.closedAt = Date()
                    t.closePrice = t.takeProfit
                    list[idx] = t
                    changed = true
                } else if hasTouchedSL(price: price, trade: t) {
                    t.status = .closedHitSL
                    t.closeReason = .hitSL
                    t.closedAt = Date()
                    t.closePrice = t.stopLoss
                    list[idx] = t
                    changed = true
                }
            case .closedHitTP, .closedHitSL, .closedManually, .cancelled:
                continue
            }
        }
        if changed {
            byPair[pairID] = list
            save()
        }
    }

    // ── Live-trade reconciliation ────────────────────────────────────

    /// Apply an `order_status` event from the cBot to the matching
    /// live trade. Lookup is by `liveOrderID`; no-op when nothing
    /// matches (e.g. stale event after the user manually removed
    /// the trade). Called when a broker event
    /// arrives via the bridge.
    func applyLiveOrderStatus(
        liveOrderID: String,
        state: LiveOrderState,
        fillPrice: Double? = nil,
        closePrice: Double? = nil,
        closeReason: Trade.CloseReason? = nil
    ) {
        // Live trades can belong to any pair — search across all
        // slots. Cost is tiny since each pair holds at most a few
        // dozen trades.
        for pairID in byPair.keys {
            guard var list = byPair[pairID] else { continue }
            guard let idx = list.firstIndex(where: { $0.liveOrderID == liveOrderID && !$0.isPaper })
            else { continue }
            var t = list[idx]
            switch state {
            case .placed:
                t.status = .pending
            case .filled:
                t.status = .active
                t.filledAt = Date()
                t.fillPrice = fillPrice ?? t.entry
            case .rejected, .cancelled:
                t.status = .cancelled
                t.closeReason = .cancelled
                t.closedAt = Date()
            case .closed:
                // Translate the cBot's close reason into the local
                // status. TP/SL/manual map cleanly; "trailing" is a
                // close-by-trailing-stop, which we slot under
                // closedHitSL (it was a stop, just a moving one) +
                // record the reason for the audit trail.
                if let reason = closeReason {
                    switch reason {
                    case .hitTP:             t.status = .closedHitTP
                    case .hitSL:             t.status = .closedHitSL
                    case .trailing:          t.status = .closedHitSL
                    case .manual:            t.status = .closedManually
                    case .cancelled:         t.status = .cancelled
                    case .reconciliation:    t.status = .closedManually
                    case .invalidatedNoFill: t.status = .cancelled
                    }
                } else {
                    t.status = .closedManually
                }
                t.closeReason = closeReason ?? .manual
                t.closedAt = Date()
                t.closePrice = closePrice
            }
            list[idx] = t
            byPair[pairID] = list
            save()
            return
        }
    }

    /// Wire form of the cBot's `order_status.state` field.
    enum LiveOrderState: String {
        case placed, filled, rejected, cancelled, closed
    }

    // Long: filled when price drops *to or below* the limit entry.
    // Short: filled when price rises *to or above* the limit entry.
    // Neutral: treated as long for simplicity (rarely used).
    private func hasTouchedEntry(price: Double, trade: Trade) -> Bool {
        switch trade.side {
        case .long, .neutral: return price <= trade.entry
        case .short:          return price >= trade.entry
        }
    }
    private func hasTouchedTP(price: Double, trade: Trade) -> Bool {
        switch trade.side {
        case .long, .neutral: return price >= trade.takeProfit
        case .short:          return price <= trade.takeProfit
        }
    }
    private func hasTouchedSL(price: Double, trade: Trade) -> Bool {
        switch trade.side {
        case .long, .neutral: return price <= trade.stopLoss
        case .short:          return price >= trade.stopLoss
        }
    }

    // ── Persistence ─────────────────────────────────────────────────

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: [Trade]].self, from: data)
        else { return }
        byPair = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(byPair) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
