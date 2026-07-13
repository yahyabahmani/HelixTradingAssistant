# Changelog

All notable changes to Helix Trading App are documented here.

---

## [Unreleased] — 2026-07-13

**Close-confirmed price-action strategies, chart overlays, and reliable layer-driven notifications.**

### New Price-Action Strategies

- **SP2L Strategy** — detects a two-to-four-bar spike, balance, breakout, pressure-gap follow-through, and the first pullback limit entry. Draws the structure, entry, stop, configurable targets, add-on level, and lifecycle state on the chart.
- **Pin Bar Combo** — adds close-confirmed rejection entries for both SP2L pullbacks and BTB (break-and-retest) structures. Includes configurable wick/body quality, ATR touch and stop buffers, confirmation expiry, risk/reward, and trade timeout.
- **MicroMap Strategy** — detects a strong directional spike followed by a weak counter-trend micro-channel, up to three close-confirmed entry attempts, configurable confluence scoring, invalidation, and trade resolution.
- **Major Trend Reversal** — detects an established pivot channel, close-confirmed channel break, second test of the old extreme, and neckline confirmation. Supports higher-low/double-bottom/failed-lower-low bullish variants and mirrored bearish variants, with entry, stop, target, expiry, and stop-first handling for ambiguous candles.

### Chart and Settings

- Added full overlays for all four strategies, including structure lines, setup labels, confirmation points, entry/stop/target plans, and resolved or expired states.
- Added persistent per-instance parameters to the indicator settings model, with backward-compatible optional decoding for existing saved configurations.
- Added derived-data cache slots and visible-window filtering so strategy computation is reused across chart redraws and only recent relevant setups render.
- Added layers-menu integration and vertical-domain expansion for every price in a visible trade plan.
- Kept Major Trend Reversal hidden from the iPad indicator picker for now while preserving iPad/iPhone build compatibility; shared SP2L, Pin Bar, BTB, and MicroMap overlays remain available on the touch chart.

### Notifications

- The chart layer eye is now the per-indicator notification switch; the global Strategy Signals setting remains the master switch.
- Added closed-candle notifications for SP2L formation, SP2L + Pin Bar confirmation, BTB + Pin Bar confirmation, MicroMap formation/entries/invalidation, and confirmed Major Trend Reversals.
- Visible Change of Character, Order Block, and Steroid Order Block layers now follow the same global and eye-based notification policy.
- Indicator activation, visibility changes, symbol/timeframe changes, and parameter edits seed a fresh baseline so historical setups do not generate alerts.
- Added stable event deduplication, persisted Inbox records, foreground macOS banners, notification-permission diagnostics, and a permission status row in Settings.
- Clicking a strategy or Change of Character notification now opens its symbol and timeframe, centers the triggering candle, and highlights the notified entry or structure-break price on the chart. The same deep link works from macOS banners and Inbox rows.
- Order Block and Steroid Order Block overlays are now chart-only and no longer generate lifecycle notifications.

### Tests and Reliability

- Added macOS unit-test coverage for bullish and bearish detections, rejection cases, expiry, exact entry/stop/target calculations, stop-first ambiguous candles, and backward-compatible settings decoding.
- Added dedicated test suites for SP2L, Pin Bar Combo/BTB, MicroMap, and Major Trend Reversal.
- Verified the complete macOS test suite and the iPad/iPhone simulator build after merging the latest upstream main branch.

---

## [v1.4 build 7] — 2026-07-12

**Adaptive iPhone + iPad redesign, and automatic Faraz re-login.**

### New Features

- **iPhone support** — the touch app is no longer iPad-only. `TARGETED_DEVICE_FAMILY` is now `1,2` with iPhone orientations, and the whole UI adapts to compact width. One codebase drives both form factors.
- **Adaptive navigation** — `AdaptiveRootView` picks the shell by size class: iPad (regular width) keeps the `NavigationSplitView` with a **Navigate + live Watchlist** sidebar; iPhone (compact width) gets a bottom `TabView` (Chart · Markets · Journal · Inbox · More).
- **Markets watchlist** — a first-class searchable, category-grouped pair list, replacing the pair-selector dropdown that used to be buried in the chart header.
- **Automatic Faraz re-login** — when a Faraz API call returns HTTP 401, the app now opens an in-app faraz.io browser (`WKWebView`), lets you log in, captures the session cookies, and saves them so the feed resumes — on macOS **and** iPad/iPhone. A "Log in to Faraz…" button in Settings triggers the same flow proactively (no more DevTools copy-paste). After capture, the live WebSocket restarts and history backfills automatically.

### Design System

- **`AdaptiveMetrics`** — size-class-aware spacing, type ramp, and tap targets (≥44pt) read from the environment.
- **Touch controls** — `IconButton` (≥44pt hit area + haptics), `PillButton`, `SegmentedChips`, and a unified `Surface` card, replacing the copy-pasted 32×32 buttons throughout the chart chrome.

### iPad / iPhone UI

- **Chart toolbar decomposed** — the crammed single-row `IPadChartHeaderToolbar` is split into composed control groups: on iPhone a slim primary row (timeframe · type · Analyze) plus a horizontally scrollable icon row; on iPad a single clean row. The network-debug tool moved out of the always-visible chrome into a `•••` overflow menu.
- **Indicator settings** — the draggable floating panel stays on iPad; iPhone presents a proper detented `.sheet` (its fixed 360pt width didn't fit small iPhones).

### Bug Fixes

- **iPad AI overlay could not be dismissed** — the analysis page's close and "Add to chart" buttons set the macOS-only `AppState.showAnalysisFullPage`, which the iPad dashboard never observed. Dismissal now routes through an `onClose` callback wired to the dashboard's local state.
- Modernized the analysis history sheet's deprecated `NavigationView` → `NavigationStack`; removed no-op `.help()` tooltips from the touch app.

---

## [v1.5] — 2026-07-06

**iPad app, device deploy tooling, and chart performance overhaul.**

### New Features

- **Native iPad app** — a full SwiftUI iPad target (`HelixTradingAppiPad`) sharing the same data model, AI engines, indicators, and storage layer as the Mac app. Uses `NavigationSplitView` with a sidebar for navigation and a pair-selector dropdown in the dashboard header. All chart controls (timeframe, chart type, indicators, layers, drawings, replay, alerts, AI analyze, debug, fullscreen) are available in the chart toolbar. Supports portrait, landscape, and all orientations on iPad.
- **`./run.sh --ipad`** — lists all iPad simulators (with iOS version and boot state) and real devices, prompts for a selection, builds the iPad target, and installs + launches on the chosen device. Handles automatic signing, simulator boot, and `xcrun devicectl` for real device deployment.
- **Focused pair syncing** — `YahooScheduler.focusedPairID` limits data fetching to the currently selected pair. iPad sets this automatically on boot and on pair change, reducing CPU usage and battery drain. Grid chart panes skip data loading entirely when hidden.

### Performance — iPad Chart

- **Crosshair uses `onContinuousHover`** — replaced the `LongPressGesture` + `DragGesture` crosshair with the system-optimized `onContinuousHover` handler (iOS 16+), eliminating the full gesture state machine overhead on every touch frame.
- **Drag gesture deadzone** — added a 3px movement threshold before panning begins, preventing finger jitter from triggering state writes. Y-axis lock threshold increased from 3px to 6px.
- **Throttled pinch-to-zoom** — increased `minimumScaleDelta` from 0.01 to 0.02 and clamped scale range to 0.1–20, reducing gesture update frequency on ProMotion displays.
- **Hidden pane optimization** — `ChartPaneView` now guards its initial `.task` data load with `isVisible`, so grid panes that aren't on screen skip candle loading entirely.

### iPad UI

- **Fullscreen charts** — single chart and grid pane fullscreen both use the same `chartCard` view (chromeless, zero padding, full toolbar). Exiting fullscreen from the chartCard button properly restores the grid layout.
- **Pair selector dropdown** — replaces the sidebar pair list; shows all pairs with a checkmark on the active one.
- **Compact toolbar** — chart toolbar buttons reduced from 44×44 with circle backgrounds to 32×32 flat icons, matching the Mac toolbar style.
- **App icon** — generated all iPad icon sizes from the Mac 1024px source icon.
- **Launch storyboard** — `LaunchScreen.storyboard` with landscape fullscreen device configuration, added via `project.yml` so it survives `xcodegen generate`.
- **SF Symbol fix** — replaced invalid `"layers"` symbol with `"square.3.layers.3d"`.

### Mac App

- **ChartGrid fullscreen sync** — `ChartGridView` now watches `app.isChartFullscreen` and clears `fullscreenPaneID` when fullscreen exits externally, fixing the case where a grid pane stayed "fullscreen" internally after the chartCard's exit button was tapped.
- **ChartPaneView hidden-pane guard** — grid pane initial data load skips when the pane is not visible.

### Bug Fixes

- **Info.plist keys survive regeneration** — `UILaunchStoryboardName` and `UISupportedInterfaceOrientations~ipad` are now set in `project.yml` properties instead of directly in the plist, so `xcodegen generate` doesn't strip them.
- **Removed hardcoded credentials** — OpenCode server URL, model, and password no longer baked into the iPad entry point.
---

## [v1.6] — 2026-07-08

**Multi-instance indicator system with per-instance settings, new Volume Profile indicator, and floating settings panels.**

### New Features

- **Multi-instance indicators/oscillators** — indicators and oscillators are now stored as JSON-encoded `[IndicatorInstance]` arrays instead of `Set<IndicatorKind>` / comma-separated `@AppStorage`. This unlocks multiple instances of the same kind (e.g. two SMAs with different periods), per-instance hide/show, and per-instance parameter tuning without the old global settings sheet. Backward compatible — old persisted data decodes with defaults for missing fields.
- **Volume Profile indicator (WIP)** — session-based volume profile overlay that groups candles by calendar day, builds per-day volume histograms, and identifies POC (Point of Control), VAH, and VAL (Value Area High/Low). Each session renders horizontal histogram bars, a solid POC line, dashed VAH/VAL boundaries, and faint vertical session separators. Configurable bucket count (10–100) and value area percentage (50–95%). Coexists with the existing VP drawing tool. Memoized via `ChartDerivedCache` with background Task recomputation.
- **Per-instance floating settings panel** — `IndicatorSettingsPanel` replaces the old monolithic settings sheet for per-kind tuning. A draggable floating panel opens for the selected indicator/oscillator instance, applying changes in real-time so the user sees the effect on the chart immediately.
- **`ParamSpec` / `ParamValue` / `ParamOption` model** — new generic parameter model supporting `Double`, `Bool`, and `String enum` parameter types, used by `IndicatorInstance.params` and `OscillatorInstance.params`. Enables the indicator menu, Layers popover, and settings panel to auto-discover each indicator's tunable knobs.

### Performance

- **OscillatorPanel reads per-instance params** — each oscillator pane now builds an `OscillatorConfig` from its instance's params dict rather than reading the global config, so per-instance tuning doesn't require an app-wide config republish.

### Internal

- **`ChartDerivedCache.indicators()` keyed on `[IndicatorInstance]`** — the indicator computation slot now uses the instances array (with their UUIDs and params) as its signature instead of `Set<IndicatorKind>`, so adding, removing, or re-tuning an instance correctly busts the cache per-instance.
- **`ChartPane` stores instances** — pane state migrated from `Set<IndicatorKind>` / `Set<OscillatorKind>` to `[IndicatorInstance]` / `[OscillatorInstance]`, making multi-instance state survive across layout changes and relaunches.
- **`OscillatorInstance` with display label** — each oscillator instance renders a label showing its kind + key params (e.g. "RSI (14)", "MACD (12, 26, 9)") in the oscillator panel header.

---

## [v1.4 build 6] — 2026-07-07

**Chart interaction polish, iPad live-tick performance, and gesture optimizations.**

### Performance — macOS Chart

- **Drawing hit-test now skipped when no drawings exist** — `ChartView`'s drag gesture no longer iterates all drawings on every mouse-pixel during pan unless there are drawings on screen or a drawing tool is armed.
- **Hover tooltip uses transition instead of value animation** — replaced `.animation(easeOut, value: hovered)` with `.transition(opacity.animation(easeOut))` so rapid mouse sweeps no longer queue up animation transactions.

### Performance — iPad Chart

- **iPad now uses trailing-window splice for live ticks** — `refreshTrailingCandles()` reads only the last ~6h window from DB and splices onto in-memory candles instead of doing a full synchronous DB read + fold on every 1 Hz tick, eliminating main-thread blocking during live streaming.
- **iPad deep-history backfill on pair/timeframe change** — `warmHistory()` calls `ensureDeepHistory` before reloading, so switching timeframes no longer risks showing an empty chart while the backfill completes.

### Bug Fixes

- **iPad timeframe change race condition** — removed the redundant immediate `reloadCandles()` task from timeframe `onChange` (same fix as the macOS bug in build 5). `warmHistory()` now handles the reload in the correct order — after deep history is populated.
- **iPad pair change now also warms history** — `warmHistory()` called from the pair-selection `.task(id:)` modifier, matching the macOS behaviour.

---

## [v1.4 build 5] — 2026-07-05

**Async data pipeline, incremental fetching, and streaming AI performance.**

### Performance — Data Fetching

- **All DB reads now off the main thread** — `OHLCCandleLoader.loadAsync()` uses GRDB's async `repo.read()` so SQLite work never blocks the UI. `DashboardView.reloadCandles()`, `refreshTrailingCandles()`, and `ChartPaneView` candle loading all route through it. The 1 Hz live-tick trailing refresh and pair/timeframe changes no longer cause visible hangs on large histories.
- **Incremental Yahoo fetching** — periodic sync now checks `latestBucket` per timeframe and passes `period1` (Unix timestamp) to Yahoo's chart API, fetching only bars newer than what's stored. Eliminates re-downloading and re-upserting ~11,520 stale 1m bars every 60 seconds.
- **Batched upserts** — `OHLCRepo._upsertMany()` now uses multi-row INSERT (124 rows per statement, 992 params) instead of individual INSERT per row. 11,520 bars go from ~11,520 SQL executions to ~93.
- **Parallel bootstrap** — `bootstrapAndGapFill()` now uses `TaskGroup` to process all pairs concurrently (each pair's 4 timeframes already ran concurrently via `backfillAll`). Seed price reads also parallelized. Startup history fetch is no longer sequential across pairs.
- **`@Published` cascade reduction** — `publishTick()` and `publishLastUpdate()` throttle `latestPrices` / `lastUpdateAt` / `activeLiveSource` writes to 1 Hz, so the entire DashboardView → ChartView → OscillatorPanel view tree re-evaluates at most once per second instead of on every live tick (5–20 Hz per symbol).

### Performance — AI Analysis Streaming

- **Conversation turn `Text()` fallback** — follow-up turns now render plain `Text()` while streaming (same optimization as the main report's trailing chunk), promoting to `Markdown()` only once the turn completes. Eliminates cmark re-parse + SwiftUI view tree rebuild on every 100 ms flush.
- **Conversation turn flush no longer triggers store-level `@Published`** — removed `sessions[key] = sess` from the flush path. Session is a class, so the mutation is in-place; the `@ObservedObject` on the report column picks it up without cascading the store's `@Published` to the entire AnalysisPage.
- **`stripStructuredBlocks` fast path** — a single `contains` check per marker returns the report unchanged when no `### *_JSON` markers are present. During streaming, markers only appear near the end, so the common path is O(1) instead of 7 marker scans + string rebuilding every 100 ms.
- **`renderChunks()` throttled to 5 Hz** — the 100 ms chunk flush invalidates the cache every time, but the actual `stripStructuredBlocks` + `chunkAtH3` recomputation is deferred until at least 200 ms has elapsed. The stale cache is returned in the interim; the trailing `Text()` chunk covers the visual gap.

### Bug Fixes

- **Faraz WebSocket-fresh periods skip Yahoo sync entirely** — when Faraz is the active source, the periodic Yahoo history sync is now fully skipped (not just gated per-pair), avoiding redundant HTTP requests for pairs Faraz already serves.
- **Twelve Data socket lifecycle matches source selection** — the socket is now opened/closed as a unit (`startTwelveDataStream` / `stopTwelveDataStream`) instead of being left open while Faraz ticks drop every incoming message. `switchGoldSource` toggles both sockets cleanly.

---

## [v1.4] — 2026-07-04

**Multiple journals, an in-app updater, the OpenCode engine, and a much faster chart.**

### New Features

- **Multiple journals** — the Journal screen now opens to a list of independently-tracked journals (e.g. "Prop firm challenge," "Personal account," "Backtests"), each with its own trades, win rate, and net P&L shown at a glance. Tap a journal to open its trade log (rename or delete from the row's context menu); an "all-time" AI review is available per journal. Entries added from outside the Journal screen (e.g. "Add to journal" from an AI analysis run) file into whichever journal was opened most recently. Existing single-journal installs migrate automatically into a "My Journal" journal — no data loss.

- **In-app updates** — `Settings → Updates` now checks GitHub releases for a newer version, shows the release notes, and downloads + opens the `.dmg` in Finder, replacing the old "open the releases page manually" placeholder link.

- **OpenCode engine** — a third AI engine alongside Claude and Codex. Runs locally via the OpenCode CLI (`opencode run`), or against a self-hosted remote OpenCode server (`opencode serve`) reachable over HTTP with optional basic-auth. Ships with a curated catalog of 5 free Zen models (MiMo V2.5 Free, DeepSeek V4 Flash Free, North Mini Code Free, Nemotron 3 Ultra Free, Big Pickle Free) that work out of the box without billing, plus 12 paid models from Anthropic, OpenAI, Google, DeepSeek, Alibaba, and Moonshot. Free models don't require an API key — authentication is handled automatically. An API key for paid Zen models, and the remote server's password, are stored in Keychain via Settings → AI → OpenCode.

- **Improved journal AI reviews** — day/week/month review prompts now include full OHLC data for each relevant timeframe alongside the trade log, giving the AI richer context for session analysis. Review history is persisted and browsable from the Journal's overflow menu.

- **Trading Sessions now track the live day** — instead of drawing every historical session box in view, the indicator now shows only each venue's current (or most recently closed) run, with its high/low/average extended as dotted reference lines through to the live edge — so, e.g., Tokyo's range stays visible while London/New York are trading.

### Performance

- **Smoother panning, zooming, and replay** — indicator and oscillator recomputation (Order Blocks, FVG, NY Open Setup, MACD, RSI, etc.) now runs off the main thread. Order Block / Steroid Order Block exhaustion scanning dropped from O(n²) to a single O(n) forward pass. Bar-index lookups (drawing placement, hover) now binary-search instead of scanning linearly. Replay stepping and auto-play splice one bar into memory instead of reloading and re-folding the entire stored series on every tick.
- **No more chart teardown on layout/fullscreen changes** — switching multi-chart grid layouts, toggling a pane (or the main chart) fullscreen, and dragging the pair-header sidebar all previously destroyed and rebuilt the underlying `ChartView` (and its indicator cache), causing a visible stall. These now vary a `Card`'s chrome/frame in place, so chart state and caches survive the transition.

### Bug Fixes

- **Grid-mode header no longer clips** — the pair header could get squeezed to a sliver (and cropped) when a 2-row/2×2 grid demanded more vertical space than the window had; it now keeps its intrinsic size and lets the grid absorb any overflow instead.
- **Sidebar pair selection now updates every pane** — with "Sync symbol across panes" on, picking a new pair from the sidebar while in grid mode previously only affected the primary chart; it now propagates to all panes.
- **Faraz WebSocket-fresh periods skip redundant HTTP polling** — once the socket is confirmed live, the 10s poll now only fetches the 1h/1d history the socket doesn't broadcast, instead of re-polling every timeframe on every tick.
- **AI analysis sessions no longer lose in-flight state** — a session looked up before its first run returned a fresh, un-stored placeholder each time; it's now created once and reused, so state started on one lookup is visible on the next.

---

## [v1.3] — 2026-07-02

**Steroid Order Blocks, Volume Profile, multi-chart grid, AI-reviewed journal days, and a real notification inbox.**

### New Features

- **Steroid Order Blocks** — a volume-validated take on Order Blocks. A zone only survives if its originating candle's volume is ≥1.2x (adjustable 0.5x–3x) the 20-period volume average, or its price range overlaps a High Volume Node from an internally computed Volume Profile — filtering structural-looking-but-thin order blocks down to the ones with real trading activity behind them. Toggle it as its own indicator ("Steroid OB," coral accent) with its own settings section (run length, min % move, wick mode, show-exhausted, notify-on-events, volume multiplier).

- **Order Blocks exhaustion lifecycle** — every Order Block / Steroid Order Block zone now tracks `fresh → tested → exhausted` as price interacts with it, with a retest counter and a "Show exhausted blocks" toggle so old, dead zones don't clutter the chart. Optional push notifications on appear / retest / exhaust, routed through the new Inbox (see below).

- **Volume Profile drawing tool** — a new manual drawing (alongside horizontal line / trend line / rectangle): drag a box over any price/time range and the chart renders a horizontal volume histogram along its right edge, 30 buckets, Point of Control highlighted in red. Resizes and repositions like a rectangle; shows up in the Drawing Inspector as "Vol Profile."

- **Multi-chart grid** — a layout picker in the pair header switches between a single chart and 2-column / 2-row / 2×2 split layouts. Each pane has its own pair, timeframe, chart type, and indicators (drawings are shared per-pair with the main chart); new panes seed at a useful timeframe spread (15m/1h/4h/1d). An optional "Sync symbol across panes" toggle propagates a pair change to every pane. Any pane can go fullscreen on its own, or the whole grid can go fullscreen together. Layout and per-pane settings persist across relaunches.

- **AI review for a whole journal day, week, or month** — beyond the existing per-trade AI post-mortem, a new "Analyse Day" button on each day-group header (and a dynamic "AI Today / This Week / This Month / Custom" toolbar button tied to the journal's date filter) runs a full-session AI review across every trade in the period: session overview, what drove the result, order-block quality per trade, discipline patterns, and concrete rules to carry forward. Reviews can now be saved and browsed later from **AI Review History** in the Journal's overflow menu — previously the report vanished the moment the sheet closed.

- **Notification Inbox** — a new sidebar section collecting every notification the app sends (order-block lifecycle events, price/RSI alerts, Scanner opportunities) into one persisted, filterable history with unread badges, instead of relying on macOS Notification Center. Each entry now also shows the timeframe the condition fired on.

- **Strategy Scanner** — new sidebar section that continuously scans every enabled pair for Swing (4H/1H/15M) and Scalp (15M/5M/1M) confluence setups, surfacing long/short opportunities with entry/stop/take-profit/R:R, a running opportunity log, and a push notification the moment a new setup appears.

- **Risk Calculator** — a new toolbar popover in the Journal view: enter account balance, risk % (0.5/1/2/3% presets), entry, and stop loss to get a suggested lot size.

- **OB Zone Win Rate analytics** — the Journal's analytics section gained a table bucketing trades into 25-point price zones (min 2 trades to show) with win/loss counts, a win-rate bar, and net P/L per zone, to spot which price levels have actually been profitable.

- **Live Faraz streaming** — the Faraz gold/BTC/SOL/ETH feed now uses a real-time WebSocket stream for spot ticks and 1m/1D candles instead of pure HTTP polling, with polling kept only as a fallback (socket stale >20s, or to backfill 5m/1h/1d bars the socket doesn't push). The Faraz API base URL is also now configurable in Settings for pointing at a custom host.

- **Sonnet 4.6 set as the default AI model** across the Analysis panel, per-trade AI sheet, and the new day-review sheet.

### Bug Fixes

- **Order-block notifications no longer flood the Inbox** — zone identity was keyed on the zone's position in whatever candle window happened to be recomputed, which shifted on every live-tick refresh or history backfill and made existing zones look "new" again. Zones are now identified by their stable price range, so a zone only notifies once per real lifecycle transition.
- **Scanner opportunities no longer re-notify hourly** — a setup that stayed valid for more than an hour used to fall outside the old dedup window and get re-announced roughly every hour it stayed open; it now only notifies once, when it first becomes active.
- **Sunday reopening respected** — COMEX's actual Sunday 6pm ET reopen is no longer blanked out for the whole day, fixing missing Sunday-evening bars for users in timezones ahead of ET.
- **Smoother panning/zooming on long histories** — indicator and oscillator recomputation (Order Blocks, FVG, NY Open Setup, MACD, etc.) now runs off the main thread, so charts with years of 1-minute data no longer stutter while panning or zooming.
- **Re-importing a cTrader CSV statement is fully idempotent** — duplicate-detection now also matches on pair, closing the small gap where two different pairs could theoretically collide on entry price + side + timestamp.

---

## [v1.2] — 2026-06-27

**Fair Value Gaps, smarter journal, AI trade post-mortems, and chart fixes.**

### New Features

- **Fair Value Gap indicator** — LuxAlgo-ported FVG detector overlays bullish and bearish imbalance zones directly on the chart. Each gap extends rightward from where it formed, with a 50% midline and a direction capsule. Mitigated gaps (price closed back inside) dim to lower opacity with dashed borders. Tune the minimum gap size and toggle mitigated zones in Indicator Settings.

- **Journal date-range filter** — Filter the journal by Today, This Week, This Month, or a custom date range. The summary cards (entries, win rate, net P/L) and all three analytics charts (daily P/L, cumulative curve, win-rate trend) update live to reflect only the selected window.

- **AI trade post-mortem** — Tap the ✦ AI button on any journal entry to open a post-mortem sheet. Pick your engine, model, and reasoning effort, then let the AI walk through five structured sections — Why it won/lost, What Went Right, What Could Have Been Better, What You Should Have Done, and a Key Takeaway — each rendered as a styled card.

- **Candlestick chart in AI review** — The AI post-mortem sheet loads real OHLC candles from the database for the trade's pair and time period, rendered as a mini candlestick chart behind the entry/TP/SL/close level lines. Timeframe is auto-selected based on trade duration (1m → 5m → 1h → 4h).

- **Trade metrics panel** — The AI review sheet shows a live R:R ratio bar (color-coded green/yellow/red), price move in points, lot size, and trade duration alongside the price ruler.

- **Save AI report to journal** — After an AI post-mortem completes, hit Save to Journal to append the full report to the entry's notes with a timestamp. Future re-runs can reference the prior analysis automatically.

### Bug Fixes

- **Chart reset button now re-fits the Y axis** — The ↺ reset button now correctly rescales the vertical axis to show all candles in the reset window, even after manually dragging the price axis. Continuous auto-fit is restored after the reset animation completes.

- **AI review price ruler Y range** — The price ruler now includes loaded candle highs/lows in its Y range calculation so bars never overflow the ruler bounds.

---

## [v1.1] — 2026 (internal)

**Charting controls, smarter AI analysis, and more data sources.**

### New Features

- **Order Blocks indicator** — Institutional bullish/bearish order-block zones with an equilibrium midline. Toggle from the indicators menu, tune in Indicator Settings.

- **Trading Sessions indicator** — Shades the Tokyo, London, and New York sessions as per-day high/low boxes with open/close and average lines. Choose which sessions and lines to show in settings.

- **NY Open Setup** — Detects the New York 5-minute opening-range breakout with an FVG retest on the 1m and 5m charts. Marks the range, the breakout gap, and the entry/stop/target.

- **Vertical price scaling** — Drag the price axis to compress or expand the candles, TradingView-style. Double-click the axis to snap back to auto-fit.

- **Free chart panning** — Click and drag anywhere on the chart to move through time and price together.

- **Model + effort selection on the analysis page** — Click an engine icon to pick its model and reasoning effort. Opus 4.8 added; Codex models now show too.

- **Consistent reasoning trace** — The thinking stream now shows for every model, not just Sonnet.

- **Faraz for crypto** — Bitcoin, Solana, and Ethereum can now be sourced from Faraz, just like gold.

---

## [v1.0] — 2026-05-01

**Initial release.**

- Live gold price monitoring from 7 concurrent sources (HD, TGJU, Digikala, Yahoo Finance, and more).
- OHLC candlestick and line charts with bar-index X axis (no weekend gaps).
- Technical indicators: SMA, EMA, Bollinger Bands, UT Bot, RSI, MACD, Stochastic.
- AI analysis via Claude Code CLI (no API key needed) — full TA, Support/Resistance, FVG, Multi-Timeframe.
- Trading journal with P/L tracking, analytics charts, and cTrader import.
- Sidebar pair switcher, chart fullscreen mode, import from file or Go backend server.
- macOS 13+ native SwiftUI app, no App Store, no sandbox.
