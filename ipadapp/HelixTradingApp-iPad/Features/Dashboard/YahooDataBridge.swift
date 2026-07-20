import SwiftUI
import Combine

/// Lightweight view that subscribes to YahooScheduler's published
/// properties and forwards only the values the parent body actually
/// needs. The parent does NOT subscribe to `yahoo` as an
/// `@EnvironmentObject` — that would re-evaluate the entire body
/// (and dismiss open menus) on every @Published write from the
/// scheduler.
///
/// This bridge subscribes via Combine and writes to `@Binding`s,
/// so the parent body only re-evaluates when the bridged values
/// actually change.
struct YahooDataBridge<Content: View>: View {
    @EnvironmentObject private var yahoo: YahooScheduler

    @Binding var livePrices: [String: Double]
    @Binding var isFetching: Bool
    @Binding var dataResetToken: Int
    let content: (YahooScheduler) -> Content

    var body: some View {
        content(yahoo)
            .onReceive(
                yahoo.$latestPrices
                    .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
                    .removeDuplicates()
            ) { prices in
                livePrices = prices
            }
            .onReceive(yahoo.$isFetching.removeDuplicates()) { fetching in
                isFetching = fetching
            }
            .onReceive(yahoo.$dataResetToken.removeDuplicates()) { token in
                dataResetToken = token
            }
    }
}

/// Self-contained fetch timer chip. Subscribes to YahooScheduler's
/// `lastUpdateAt` and `isFetching` directly via @EnvironmentObject,
/// so the parent DashboardViewiPad body never re-evaluates for
/// fetch-timer updates. The internal `FetchTimerView` already has
/// its own 1-second Timer for the countdown display.
struct FetchTimerBridge: View {
    @EnvironmentObject private var yahoo: YahooScheduler
    let intervalSeconds: Int

    var body: some View {
        FetchTimerView(
            lastFetchAt: yahoo.lastUpdateAt,
            intervalSeconds: intervalSeconds,
            isFetching: yahoo.isFetching
        )
    }
}
