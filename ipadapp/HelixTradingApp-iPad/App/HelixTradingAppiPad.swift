import SwiftUI

@main
struct HelixTradingAppiPad: App {
    @StateObject private var appState = AppState()
    @StateObject private var yahoo = YahooScheduler()
    @StateObject private var news = NewsStore()
    @StateObject private var analysisStore = AnalysisStore()
    @StateObject private var tradeStore = TradeStore()
    @StateObject private var journalStore = JournalStore()
    @StateObject private var dayReviewStore = DayReviewStore()
    @StateObject private var autoTraderConfig = AutoTraderConfigStore()
    @StateObject private var paperBalance = PaperBalance()
    @StateObject private var dataConfig = DataSourceConfig.shared
    @StateObject private var notificationInbox = NotificationInbox()
    @StateObject private var autoTrader = AutoTraderEngine()

    var body: some Scene {
        WindowGroup("Helix Trading", id: "main") {
            RootViewiPad()
                .environmentObject(appState)
                .environmentObject(yahoo)
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
                .preferredColorScheme(.dark)
                .task {
                    ProxyTransport.shared.configure(ProxyConfig.load())
                    // Warm the economic calendar so the chart's news
                    // flags have data before the News tab is opened.
                    news.refresh()
                    paperBalance.attach(tradeStore: tradeStore)
                    autoTrader.attach(
                        configStore: autoTraderConfig,
                        analysisStore: analysisStore,
                        tradeStore: tradeStore,
                        news: news,
                        paperBalance: paperBalance
                    )

                    do {
                        try appState.bootDatabase(notificationInbox: notificationInbox)
                    } catch {
                        appState.lastError = "Database init failed: \(error.localizedDescription)"
                        return
                    }

                    if let db = appState.database {
                        yahoo.start(database: db)
                        // iPad: only sync the selected pair to reduce CPU
                        yahoo.focusedPairID = appState.selectedPairID
                    }

                    seedOpenCodeRemoteIfNeeded()
                }
                .onChange(of: appState.selectedPairID) { newID in
                    yahoo.focusedPairID = newID
                }
        }
    }

    /// Pre-seed OpenCode remote config so the AI engine works
    /// immediately without manual setup.
    private func seedOpenCodeRemoteIfNeeded() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "opencode.seeded") {
            defaults.set(true, forKey: "ai.opencode.useRemote")
            defaults.set(true, forKey: "opencode.seeded")
        }
    }
}
