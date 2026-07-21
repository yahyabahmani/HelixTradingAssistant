import Foundation

/// App version metadata, read from the bundle so it always matches what
/// `project.yml` baked into Info.plist (no second source of truth to
/// drift). Used by the About row and the "What's New" popup.
enum AppInfo {
    /// Marketing version, e.g. "1.1" (CFBundleShortVersionString).
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    /// Build number, e.g. "2" (CFBundleVersion).
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}

/// One line in the "What's New" popup — an SF Symbol, a headline, and a
/// one-sentence detail.
struct ReleaseHighlight: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
}

/// The release notes shown by the What's New popup after an update.
///
/// To cut a release: bump `version`/`build` in `project.yml`, then update
/// `ReleaseNotes.latest` here with the new `version` + highlights. The
/// popup fires automatically when the running `version` differs from the
/// last one the user dismissed (see `RootView`).
struct ReleaseNotes {
    let version: String
    let tagline: String
    let highlights: [ReleaseHighlight]

    static let latest = ReleaseNotes(
        version: "1.5",
        tagline: "On-chart position planning, four new order-block indicators, news markers, and a corrected risk calculator.",
        highlights: [
            .init(icon: "arrow.up.right.square",
                  title: "On-chart position tool",
                  detail: "Drop a long or short position straight onto the chart and drag its entry, stop, target, or time extent. Each position carries its own account balance and risk %, and shows live lot size, profit, loss, and R:R as you move it. Sizing uses per-instrument contract specs, so gold, oil, crypto, and indices each size correctly."),
            .init(icon: "exclamationmark.triangle.fill",
                  title: "Risk calculator sizing fix",
                  detail: "Gold position sizes were 10× too large. The calculator treated the entry-to-stop distance as \"points\" ($0.10 each) while measuring it in dollars — a 4035 → 4045 stop at 1% returned 0.1 lot instead of 0.01. Sizes now come from the same contract spec the chart tool uses."),
            .init(icon: "square.stack.3d.up.badge.a",
                  title: "Four new order-block indicators",
                  detail: "Ranked OB grades swing order blocks A/B/C on Volume-Profile and Ichimoku confluence with a breaker lifecycle. Volume-Filtered OB adds a volumetric up/down split, ATR size filter, and zone merging. Plus a full Ichimoku Cloud and Ichimoku-confluence Order Blocks."),
            .init(icon: "newspaper.fill",
                  title: "News markers on the chart",
                  detail: "Economic events plot as TradingView-style flags along the time axis — click one for the full detail popover, on both Mac and iPad."),
            .init(icon: "chart.bar.xaxis.ascending",
                  title: "Volume Profile overhaul",
                  detail: "Three modes: per-trading-day sessions anchored to 18:00 ET, the last ZigZag trend segment, or visible-range with ranked high-volume levels. Two-tone up/down buckets with POC and value-area highs/lows."),
            .init(icon: "arrow.left.and.right",
                  title: "Draw anywhere, including ahead of price",
                  detail: "Drawings are no longer pinned to the last candle — drag one into the empty space right of the chart to plan a setup ahead of price. On iPad, drawings can now be dragged and reshaped at all, which previously did nothing."),
            .init(icon: "waveform.path.ecg",
                  title: "New strategies and symbols",
                  detail: "SP2L, Pin Bar Combo, MicroMap, and Major Trend Reversal close-confirmed strategies, higher-timeframe CHoCH zones projected onto the current timeframe, and WTI Crude plus the US Dollar Index as tradeable symbols."),
        ]
    )

    static let v1_4 = ReleaseNotes(
        version: "1.4",
        tagline: "Multiple journals, an in-app updater, the OpenCode engine, and a smoother, faster chart.",
        highlights: [
            .init(icon: "books.vertical.fill",
                  title: "Multiple journals",
                  detail: "Keep separate trade logs — e.g. \"Prop firm challenge,\" \"Personal account,\" \"Backtests\" — each with its own trades, win rate, and P&L. The Journal screen now opens to a list of journals; tap one to log trades inside it, rename, or delete."),
            .init(icon: "arrow.down.app.fill",
                  title: "In-app updates",
                  detail: "Settings → Updates now checks GitHub releases directly, shows the new version's notes, and downloads + opens the .dmg for you — no more digging up the releases page by hand."),
            .init(icon: "terminal",
                  title: "OpenCode engine",
                  detail: "A third AI engine alongside Claude and Codex — runs locally via the OpenCode CLI, or against your own remote OpenCode server, with 5 free Zen models (no API key needed) plus 12 paid models from Anthropic, OpenAI, Google, DeepSeek, and more."),
            .init(icon: "sparkles",
                  title: "Improved journal AI reviews",
                  detail: "Day/week/month review prompts now include full OHLC data for each timeframe, giving the AI richer context. Review history is persisted and browsable from the Journal's overflow menu."),
            .init(icon: "gauge.with.dots.needle.67percent",
                  title: "Smoother, faster charts",
                  detail: "Indicator/oscillator recomputation now runs off the main thread, Order Block exhaustion scanning dropped from quadratic to linear time, and switching multi-chart layouts or toggling fullscreen no longer tears down and rebuilds the chart — panning, zooming, and replay all feel noticeably snappier on years of 1-minute data."),
        ]
    )

    static let v1_3 = ReleaseNotes(
        version: "1.3",
        tagline: "Steroid Order Blocks, Volume Profile, multi-chart grid, AI-reviewed journal days, and a real notification inbox.",
        highlights: [
            .init(icon: "bolt.badge.a.fill",
                  title: "Steroid Order Blocks",
                  detail: "Order Blocks cross-validated against real trading volume — a zone only survives if its originating candle's volume beats its 20-period average, or it overlaps a High Volume Node from the Volume Profile. Toggle it as its own indicator with a tunable volume multiplier."),
            .init(icon: "square.stack.3d.up.badge.a",
                  title: "Order Block exhaustion lifecycle",
                  detail: "Every zone now tracks fresh → tested → exhausted with a retest counter. Hide dead zones with \"Show exhausted blocks,\" and optionally get notified on appear / retest / exhaust."),
            .init(icon: "chart.bar.xaxis.ascending",
                  title: "Volume Profile drawing",
                  detail: "Drag a box over any price/time range to render a horizontal volume histogram — 30 buckets, Point of Control highlighted — resizable and repositionable like a rectangle."),
            .init(icon: "square.grid.2x2",
                  title: "Multi-chart grid",
                  detail: "Split the dashboard into 2 or 4 independent panes, each with its own pair, timeframe, and indicators. Optionally sync the symbol across panes, and go fullscreen on one pane or the whole grid."),
            .init(icon: "calendar.badge.sparkles",
                  title: "AI review for a whole journal day, week, or month",
                  detail: "Beyond per-trade post-mortems, run a full-session AI review across every trade in a period — overview, what drove the result, OB quality, discipline patterns, and rules to carry forward. Reviews now save and browse from AI Review History instead of vanishing when the sheet closes."),
            .init(icon: "bell.fill",
                  title: "Notification Inbox",
                  detail: "A new sidebar section collects every alert — order blocks, price/RSI alerts, Scanner opportunities — into one filterable history with unread badges and the triggering timeframe, instead of relying on macOS Notification Center."),
            .init(icon: "scope",
                  title: "Strategy Scanner",
                  detail: "Continuously scans every enabled pair for Swing and Scalp confluence setups, surfacing long/short opportunities with entry/stop/target/R:R and a push notification the moment one appears."),
            .init(icon: "function",
                  title: "Risk Calculator",
                  detail: "A new Journal toolbar popover: enter balance, risk %, entry, and stop loss to get a suggested lot size."),
        ]
    )

    /// Archive of past release notes. Not shown in the popup, but kept here
    /// as a source of truth for the changelog history.
    static let v1_2 = ReleaseNotes(
        version: "1.2",
        tagline: "Fair Value Gaps, smarter journal, AI trade post-mortems, and chart fixes.",
        highlights: [
            .init(icon: "rectangle.inset.filled",
                  title: "Fair Value Gap indicator",
                  detail: "LuxAlgo-ported FVG detector overlays bullish and bearish imbalance zones directly on the chart. Each gap extends rightward from where it formed, with a 50% midline and a direction capsule. Mitigated gaps (price closed back inside) dim to lower opacity with dashed borders. Tune the minimum gap size and toggle mitigated zones in Indicator Settings."),
            .init(icon: "calendar",
                  title: "Journal date-range filter",
                  detail: "Filter the journal by Today, This Week, This Month, or a custom date range. The summary cards (entries, win rate, net P/L) and all three analytics charts (daily P/L, cumulative curve, win-rate trend) update live to reflect only the selected window."),
            .init(icon: "sparkles",
                  title: "AI trade post-mortem",
                  detail: "Tap the ✦ AI button on any journal entry to open a post-mortem sheet. Pick your engine, model, and reasoning effort, then let the AI walk through Why it won/lost, What Went Right, What Could Have Been Better, What You Should Have Done, and a Key Takeaway — each as a styled card."),
            .init(icon: "chart.xyaxis.line",
                  title: "Candlestick chart in AI review",
                  detail: "The AI post-mortem sheet now loads real OHLC candles from the database for the trade's pair and time period, rendered as a mini candlestick chart behind the entry/TP/SL/close level lines. The timeframe is auto-selected based on trade duration (1m up to 4h)."),
            .init(icon: "arrow.up.and.down.square",
                  title: "Reset button now fits Y axis",
                  detail: "The chart reset button (↺) now correctly re-fits the vertical scale to show all candles in the reset window, even after manually dragging the price axis. Continuous auto-fit is restored after the reset animation completes."),
            .init(icon: "chart.bar.doc.horizontal",
                  title: "Trade metrics + save to journal",
                  detail: "The AI review sheet shows a live R:R ratio bar, price move in points, lot size, and trade duration. After analysis completes, hit Save to Journal to append the full report to the entry's notes with a timestamp."),
        ]
    )

    /// Archive of past release notes. Not shown in the popup, but kept here
    /// as a source of truth for the changelog history.
    static let v1_1 = ReleaseNotes(
        version: "1.1",
        tagline: "Charting controls, smarter AI analysis, and more data sources.",
        highlights: [
            .init(icon: "squareshape.split.2x2.dotted",
                  title: "Order Blocks indicator",
                  detail: "Institutional bullish/bearish order-block zones with an equilibrium midline — toggle it from the indicators menu and tune it in indicator settings."),
            .init(icon: "clock",
                  title: "Trading Sessions indicator",
                  detail: "Shades the Tokyo, London, and New York sessions as per-day high/low boxes with open/close and average lines — toggle it from the indicators menu and choose which sessions and lines show in settings."),
            .init(icon: "scope",
                  title: "NY Open Setup",
                  detail: "Detects the New York 5-minute opening-range breakout with an FVG retest on the 1m and 5m charts — marks the range, the breakout gap, and the entry/stop/target, alerts you on the retest, and activates as a trade in one click."),
            .init(icon: "arrow.up.and.down",
                  title: "Vertical price scaling",
                  detail: "Drag the price axis to compress or expand the candles, TradingView-style. Double-click the axis to snap back to auto-fit."),
            .init(icon: "hand.draw",
                  title: "Free chart panning",
                  detail: "Click and drag anywhere on the chart to move through time and price together — in any direction."),
            .init(icon: "slider.horizontal.3",
                  title: "Model + effort on the analysis page",
                  detail: "Click an engine icon to pick its model and reasoning effort. Opus 4.8 added; Codex models now show too."),
            .init(icon: "brain",
                  title: "Consistent reasoning trace",
                  detail: "The thinking stream now shows for every model, not just Sonnet."),
            .init(icon: "bitcoinsign.circle",
                  title: "Faraz for crypto",
                  detail: "Bitcoin, Solana, and Ethereum can now be sourced from Faraz, just like gold."),
        ]
    )
}
