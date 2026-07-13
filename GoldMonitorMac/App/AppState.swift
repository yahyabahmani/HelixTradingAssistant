import Foundation
import Combine

// Global app-wide state. ObservableObject (not @Observable) so we stay
// compatible with macOS 13 — @Observable / Observation framework is 14+.
//
// Lives at the root of the view tree (see HelixTradingApp). Sub-systems
// that need their own state get nested holders rather than ballooning
// this.
final class AppState: ObservableObject {
    // ── Navigation ─────────────────────────────────────────────────
    @Published var selectedSidebarItem: SidebarItem? = .dashboard

    /// Selected trading pair on the dashboard. Persisted across
    /// launches via UserDefaults so the app reopens on the same
    /// pair the user was last looking at.
    @Published var selectedPairID: String? = UserDefaults.standard.string(forKey: "selectedPairID") {
        didSet {
            if let id = selectedPairID {
                UserDefaults.standard.set(id, forKey: "selectedPairID")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedPairID")
            }
        }
    }

    // ── Modals / sheets ────────────────────────────────────────────
    @Published var showSettings: Bool = false

    /// "Chart fullscreen" mode: hides the sidebar and removes outer
    /// padding so the chart can dominate the whole window. Owned at
    /// the app level rather than DashboardView so RootView can react
    /// and collapse the sidebar.
    @Published var isChartFullscreen: Bool = false

    /// When true, the dashboard renders the full-window AI analysis
    /// page as a ZStack overlay covering its chart content.
    @Published var showAnalysisFullPage: Bool = false

    /// When true, the root view presents the first-run setup wizard
    /// (or the user explicitly re-ran it from Settings).
    @Published var showWizard: Bool = false

    /// Deep-link target for the Settings page. Lifted from
    /// `SettingsView`'s local state so other screens (e.g. the
    /// dashboard's auto-trader gear button) can navigate
    /// straight to a specific category. SettingsView reads/writes
    /// it via a Binding so manual sidebar clicks still work.
    @Published var settingsCategory: SettingsCategory = .general

    /// When non-nil, the AutoTraderCard expands the matching
    /// pair row on appear. Lets the dashboard's gear button
    /// deep-link to per-symbol auto-trader config. Cleared by
    /// the card once consumed so subsequent visits open the
    /// card with whichever row was last expanded.
    @Published var autoTraderInspectorPairID: String? = nil

    /// Journal entry whose entry/TP/SL lines are currently pinned on
    /// the chart. Set by JournalView's "Show on chart" button; cleared
    /// when the user dismisses the overlay or switches pair/timeframe.
    @Published var journalChartEntry: JournalEntry? = nil

    /// One-shot chart deep link created by clicking an Inbox row or a
    /// macOS notification banner.
    @Published var notificationChartTarget: NotificationChartTarget? = nil

    func openNotificationChart(_ target: NotificationChartTarget) {
        selectedPairID = target.pairID
        notificationChartTarget = target
        selectedSidebarItem = .dashboard
    }

    // ── AI analysis tabs (per pair) ────────────────────────────────
    /// Open analysis tabs per symbol — browser-style. Lazily seeded
    /// with one tab the first time a pair's page is shown. In-memory
    /// for the app session (not persisted across launches).
    @Published var analysisTabsByPair: [String: [AnalysisTab]] = [:]
    /// The selected tab id per pair.
    @Published var currentAnalysisTabID: [String: UUID] = [:]

    /// Tabs for a pair, guaranteeing at least one exists (creates a
    /// default tab on first access).
    func analysisTabs(for pairID: String) -> [AnalysisTab] {
        if let tabs = analysisTabsByPair[pairID], !tabs.isEmpty { return tabs }
        let seed = AnalysisTab()
        analysisTabsByPair[pairID] = [seed]
        currentAnalysisTabID[pairID] = seed.id
        return [seed]
    }

    /// The currently-selected tab for a pair (ensures one exists).
    func currentAnalysisTab(for pairID: String) -> AnalysisTab {
        let tabs = analysisTabs(for: pairID)
        if let id = currentAnalysisTabID[pairID], let t = tabs.first(where: { $0.id == id }) {
            return t
        }
        let first = tabs[0]
        currentAnalysisTabID[pairID] = first.id
        return first
    }

    func selectAnalysisTab(_ id: UUID, for pairID: String) {
        currentAnalysisTabID[pairID] = id
    }

    /// Add a fresh tab seeded from the given defaults; selects it. The
    /// new tab inherits the caller's current engine so opening a tab
    /// keeps the last-used model. Its name is left to derive from the
    /// kind (the user can double-click the chip to rename).
    @discardableResult
    func addAnalysisTab(
        for pairID: String,
        aspectsCSV: String,
        profile: StrategyProfile,
        engine: AIEngineKind = .opencode
    ) -> AnalysisTab {
        var tabs = analysisTabs(for: pairID)
        let tab = AnalysisTab(aspectsCSV: aspectsCSV, profile: profile, engine: engine)
        tabs.append(tab)
        analysisTabsByPair[pairID] = tabs
        currentAnalysisTabID[pairID] = tab.id
        return tab
    }

    /// Close a tab. Refuses to remove the last one. Re-selects a
    /// neighbour when the closed tab was current.
    func closeAnalysisTab(_ id: UUID, for pairID: String) {
        var tabs = analysisTabs(for: pairID)
        guard tabs.count > 1, let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)
        analysisTabsByPair[pairID] = tabs
        if currentAnalysisTabID[pairID] == id {
            currentAnalysisTabID[pairID] = tabs[min(idx, tabs.count - 1)].id
        }
    }

    /// Persist edits to a tab's per-tab state (kind / aspects / profile / title).
    func updateAnalysisTab(_ tab: AnalysisTab, for pairID: String) {
        var tabs = analysisTabs(for: pairID)
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        guard tabs[idx] != tab else { return }
        tabs[idx] = tab
        analysisTabsByPair[pairID] = tabs
    }

    // ── Database lifecycle ────────────────────────────────────────
    @Published private(set) var database: AppDatabase?

    /// Static pair catalog. The open-source build doesn't fetch a
    /// pair list from anywhere — the YahooScheduler / TwelveData
    /// streams populate live prices into `latestPrices` maps, and
    /// `pairs` is the menu of supported symbols. Adding a pair is
    /// a one-line edit to `TradingPair.catalog`.
    @Published var pairs: [TradingPair] = TradingPair.seed()

    // ── Errors ────────────────────────────────────────────────────
    @Published var lastError: String?

    // ── Boot ──────────────────────────────────────────────────────
    /// Open (or create) the SQLite DB at its canonical location and
    /// run schema migrations. Called once from the app's `.task`
    /// block.
    @MainActor func bootDatabase(notificationInbox: NotificationInbox) throws {
        let url = try AppDatabase.defaultURL()
        let db = try AppDatabase(url: url)
        self.database = db
        // Seed the selection if there's nothing saved yet. We don't
        // need to re-fetch pairs — the catalog is static.
        if selectedPairID == nil, let first = pairs.first {
            selectedPairID = first.id
        } else if let saved = selectedPairID, !pairs.contains(where: { $0.id == saved }) {
            // The saved ID may point at a legacy Iran pair from an
            // older install; fall back to the first available pair.
            selectedPairID = pairs.first?.id
        }
    }
}

/// The sidebar's top-level navigation entries.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case news
    case portfolio
    case journal
    case inbox
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .news:      return "News"
        case .portfolio: return "Portfolio"
        case .journal:   return "Journal"
        case .inbox:     return "Inbox"
        case .settings:  return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "chart.line.uptrend.xyaxis.circle.fill"
        case .news:      return "newspaper.fill"
        case .portfolio: return "briefcase.fill"
        case .journal:   return "book.closed.fill"
        case .inbox:     return "bell.fill"
        case .settings:  return "gearshape.fill"
        }
    }
}
