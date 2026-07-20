import SwiftUI
import Combine

// Entry point. Sets up the single window scene with sidebar+content
// layout. CleanMyMac X uses a single ~1100×720 window with custom
// title bar — we match that here.
@main
struct HelixTradingApp: App {
    // Single source of truth for cross-cutting state. Bound at the
    // root so every screen can reach it via @EnvironmentObject
    // without prop drilling.
    @StateObject private var appState = AppState()
    @StateObject private var yahoo = YahooScheduler()
    @StateObject private var ctrader = CTraderScheduler()
    @StateObject private var news = NewsStore()
    @StateObject private var analysisStore = AnalysisStore()
    /// Paper-trade store — also the mirror for live trades when
    /// the auto-trader is in live mode (TradeStore tracks both
    /// flavors; the `isPaper` flag gates which evaluator runs).
    @StateObject private var tradeStore = TradeStore()
    /// Hand-written trade journal — what the user actually traded, with
    /// realised P/L + notes, optionally referencing the AI run that
    /// produced the idea. Distinct from the paper-trade simulator.
    @StateObject private var journalStore = JournalStore()
    /// Saved AI reviews of a trading day/week/month — separate from
    /// `journalStore` since a review isn't tied to a single trade.
    @StateObject private var dayReviewStore = DayReviewStore()
    /// Per-pair auto-trader configuration. Separate from the
    /// engine so the Settings card can bind to its `byPair` map
    /// directly without going through the engine for every
    /// keystroke.
    @StateObject private var autoTraderConfig = AutoTraderConfigStore()
    /// Running paper-trading balance — `startingBalance + Σ realised
    /// P/L on closed paper trades`. Drives the auto-trader's
    /// risk-% lot sizing AND the visible balance number on the
    /// Auto-trader card.
    @StateObject private var paperBalance = PaperBalance()
    /// User-configurable data-source endpoints + API keys captured
    /// during the first-run setup wizard. Lives at the app root so
    /// any screen that needs a key (Twelve Data, calendar, etc.)
    /// reads from the same source of truth.
    @StateObject private var dataConfig = DataSourceConfig.shared
    /// App-wide history of every notification the app has sent
    /// (price/RSI alerts, order-block lifecycle, scanner
    /// opportunities). No DB dependency, so — unlike `ScannerStore`,
    /// which needs `bootDatabase()` first — it's constructed eagerly
    /// here alongside the other app-root stores.
    @StateObject private var notificationInbox = NotificationInbox()

    /// Auto-trader orchestrator — constructed eagerly with no
    /// deps so it's always in the SwiftUI environment from first
    /// render. The boot `.task` calls `engine.attach(...)` once
    /// the surrounding @StateObjects exist to wire stores +
    /// subscriptions.
    @StateObject private var autoTrader = AutoTraderEngine()

    /// Combine subscription that syncs `appState.selectedPairID` →
    /// `yahoo.selectedPairID` for dual-speed ticking.
    @State private var selectedPairCancellable: AnyCancellable?

    var body: some Scene {
        WindowGroup("Helix Trading", id: "main") {
            RootView()
                .environmentObject(appState)
                .environmentObject(yahoo)
                .environmentObject(ctrader)
                .environmentObject(news)
                .environmentObject(analysisStore)
                .environmentObject(tradeStore)
                .environmentObject(journalStore)
                .environmentObject(dayReviewStore)
                .environmentObject(autoTraderConfig)
                .environmentObject(paperBalance)
                .environmentObject(autoTrader)
                .environmentObject(dataConfig)
                .environmentObject(notificationInbox)
                .frame(minWidth: 980, idealWidth: 1180, minHeight: 640, idealHeight: 760)
                .preferredColorScheme(.dark)
                .task {
                    ProxyTransport.shared.configure(ProxyConfig.load())
                    // Warm the economic calendar at boot so the chart's
                    // news flags have data even before the News tab is
                    // ever opened. One-shot; the News tab / chart layer
                    // drive live refresh via retain/release.
                    news.refresh()
                    // Wire dependencies on the engine once the
                    // surrounding @StateObjects exist. Both
                    // attaches are idempotent.
                    paperBalance.attach(tradeStore: tradeStore)
                    autoTrader.attach(
                        configStore: autoTraderConfig,
                        analysisStore: analysisStore,
                        tradeStore: tradeStore,
                        cTrader: ctrader,
                        news: news,
                        paperBalance: paperBalance
                    )

                    do {
                        try appState.bootDatabase(notificationInbox: notificationInbox)
                    } catch {
                        appState.lastError = "Database init failed: \(error.localizedDescription)"
                        return
                    }

                    // First run? Show the wizard. The wizard sets
                    // `setup.completed` once the user clicks Done.
                    if !UserDefaults.standard.bool(forKey: "setup.completed") {
                        appState.showWizard = true
                    }

                    if let db = appState.database {
                        // Live schedulers — Yahoo for chart history +
                        // crypto polling, cTrader bridge for the
                        // ounce live feed (when running).
                        yahoo.start(database: db)
                        yahoo.attachCTraderProvider(ctrader)
                        ctrader.start(database: db) { [weak yahoo] price, pairID, source in
                            yahoo?.applyExternalTick(price: price, pairID: pairID, source: source)
                        }
                        // Mac dual-speed: selected pair gets live data
                        // every 5s, all others every 60min.
                        yahoo.selectedPairID = appState.selectedPairID
                        selectedPairCancellable = appState.$selectedPairID
                            .removeDuplicates()
                            .sink { [weak yahoo] id in
                                yahoo?.selectedPairID = id
                            }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}


