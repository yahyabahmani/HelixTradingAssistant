# Helix Trading Assistant — Working Brief

The single source of truth for anyone (human or AI) editing this codebase.
It merges the old `README.md`, `CLAUDE.md`, `CHANGELOG.md`, release notes,
`CTS_IMPROVEMENT_PLAN.md`, `ipadapp/REDESIGN.md`, and `CTraderBridge/README.md`
— those files were removed in favour of this one. If a behaviour or
convention here conflicts with what you'd guess from reading a single
file, this document wins.

> **Rebrand note**: the app is "Helix Trading App" (display name) /
> "Helix Trading Club" (org). The source directory `GoldMonitorMac/`
> kept its old name to avoid churning git history — only user-visible
> branding (bundle name, display name, window titles, copyright,
> keychain service, app-support dir) was renamed.

> **⚠️ Not financial advice.** Personal-use research tool. The AI engines
> generate trade ideas from market snapshots; no trades are placed against
> a live broker. The auto-trader is paper-only.

---

## What it is

A native SwiftUI macOS app (plus an iPad/iPhone target) that monitors
gold + crypto markets, charts them with indicators and drawings, and runs
AI-driven technical analyses via local CLI engines. Built on Apple Charts,
GRDB, and the local `claude` / `codex` / `opencode` CLIs.

**Feature surface (macOS):**
- **Live multi-source price feed** — Yahoo Finance for XAU/USD (10s ticks),
  TwelveData WebSocket for BTC/ETH/SOL, Faraz WebSocket feed (gold + crypto,
  with automatic in-app re-login on HTTP 401 via WKWebView cookie capture),
  gold-api fallback, and an optional cTrader bridge (see below) that takes
  priority for XAU/USD when connected. WTI symbol also supported.
- **Interactive charts** — line / candle / Heikin Ashi; pan + zoom; vertical
  price-axis scaling; replay mode; "scroll to latest"; infinite-scroll
  history paging; multi-chart grid (2-col / 2-row / 2×2) with per-pane
  pair/timeframe/indicators, per-pane legend, focus ring + focused-pane
  symbol targeting, and pane/grid fullscreen.
- **Indicators** — SMA, EMA, Bollinger, UT Bot, RSI, MACD, Stochastic,
  Order Blocks (+ exhaustion lifecycle), Steroid Order Blocks
  (volume-validated), Sonarlab OB, Ranked OB (swing OBs graded A/B/C on
  Volume-Profile + Ichimoku confluence, with breakers), Fair Value Gaps,
  Volume Profile (three modes — per-trading-day sessions anchored to
  18:00 ET, last ZigZag trend segment, or visible-range with ranked
  high-volume levels; two-tone up/down buckets, POC + VAH/VAL), Trading
  Sessions, ZigZag, Change of Character (CHoCH,
  incl. higher-timeframe zones projected onto the current TF), NY Open
  Setup, SP2L, Pin Bar Combo / BTB, MicroMap, Major Trend Reversal,
  Ichimoku Cloud, Ichimoku-confluence Order Blocks, and
  Volume-Filtered Order Blocks (swing-anchored OBs with a volumetric
  up/down split + balance %, ATR size filter, breaker/invalidation
  lifecycle, and overlapping-zone merging — PineScript v6 port).
  Multi-instance: indicators/oscillators are `[IndicatorInstance]` /
  `[OscillatorInstance]` arrays with per-instance params
  (`ParamSpec`/`ParamValue`), hide/show, and floating settings panels.
- **AI analysis** — Full TA, Support/Resistance (`LEVELS_JSON` → chart
  lines), FVG (`FVG_JSON` → shaded zones), Multi-Timeframe, Confluence
  Trade Scanner (2-stage). Engines: Claude Code CLI (no API key — reuses
  the CLI session), Codex CLI, OpenCode (local CLI or remote server with
  free Zen models). Model + reasoning-effort pickers per engine.
- **Auto-trader (paper)** — risk-% lot sizing, paper P&L, strategy
  profiles; queues scored scenarios from the Confluence Scanner.
- **Journal** — multiple journals, trades + P/L analytics, date-range
  filters, OB-zone win-rate table, risk calculator, cTrader CSV import
  (idempotent), per-trade AI post-mortems and day/week/month AI reviews
  with persisted review history.
- **Alerts + Inbox** — price/RSI alerts, strategy-signal notifications
  (layer eye = per-indicator switch; global Strategy Signals = master),
  persisted filterable notification Inbox with unread badges.
- **Strategy Scanner** — continuous Swing/Scalp confluence scans across
  pairs with entry/SL/TP/R:R and one-shot notifications.
- **News / Economic calendar** — ForexFactory feed, impact-filtered.
  Also overlaid **on the chart's time axis** (TradingView-style): small
  impact-coloured flags (high=red, med=orange, low=yellow, none=grey)
  pinned to the bottom axis at each event's time, click/tap → detail
  popover. Renders on Mac + iPad in every layout (single + grids). See
  `NewsChartLayer.swift`.
- **First-run wizard** — collects keys / endpoints / CLI paths; re-runnable
  from Settings. In-app updater checks GitHub releases and downloads DMGs.

**What this app is NOT:**
- Not an order backtester (replay is chart-visual only) and not a broker
  bridge — analysis output is informational; nothing executes on a venue.
- Not for the App Store — unsandboxed process spawning, open ATS, CLI
  shell-outs. Distribution is "build it yourself or grab a notarised DMG".
- Not a server replacement — the Go backend (separate repo/root) remains
  the source of truth for production data; the app can import from it.

---

## Build & run

```bash
# From the REPO ROOT (project.yml and the .xcodeproj live here,
# NOT inside GoldMonitorMac/):
./run.sh                 # bootstrap deps (brew, xcodegen, node, CLIs), regen, build, launch
./run.sh --release       # release configuration
./run.sh --ipad          # list iPad/iPhone sims + devices, pick, build & run
./run.sh --clean         # wipe ./build (forces SPM re-resolve)
./run.sh --no-launch     # build only
./run.sh --quiet         # suppress xcodebuild noise
./run.sh --skip-deps     # don't install tooling
```

Manual:

```bash
brew install xcodegen node
npm i -g @anthropic-ai/claude-code @openai/codex   # codex optional
xcodegen generate        # regenerates HelixTradingApp.xcodeproj from project.yml
xcodebuild -project HelixTradingApp.xcodeproj -scheme HelixTradingApp \
  -configuration Debug -destination 'platform=macOS' build
```

- `project.yml` is the **source of truth**; the `.xcodeproj` is gitignored
  and regenerated. Never edit `.xcodeproj` files directly.
- Tests: `xcodebuild -project HelixTradingApp.xcodeproj -scheme
  HelixTradingApp -destination 'platform=macOS' test` (target
  `HelixTradingAppTests` is wired into the scheme's test action via the
  `schemes:` block in project.yml — keep that block if you regenerate).
- Toolchain: Xcode 15+, Swift 5.9, macOS 13+ / iOS 16+ deployment (Apple
  Charts baseline).
- Real iPad/iPhone device deploys: `DEVELOPMENT_TEAM=<team-id> ./run.sh --ipad`.
- SPM deps are **GRDB and swift-markdown-ui only** — no new deps without
  discussion.

---

## Architecture at a glance

```
App lifecycle
  HelixTradingApp          @main; @StateObjects:
                             • AppState       — selected pair, db handle, errors, fullscreen flag
                             • FetchScheduler — periodic snapshot fetch
                             • YahooScheduler — live ticks (Yahoo 10s, TwelveData WS,
                               Faraz WS, cTrader bridge), OHLC writes, focusedPairID
                           Boots the database, kicks schedulers, hands env objects to RootView.

RootView (Features/)
  HStack { SidebarView | mainArea }
  Auto-enters macOS fullscreen on first launch (WindowConfigurator).
  Sidebar collapses when AppState.isChartFullscreen.

DashboardView (Features/Dashboard/)
  The crown jewel. Pair header (live price, layout picker), chart card
  (type/timeframe/zoom/fullscreen/indicators/layers/drawings/replay/AI),
  ChartView + VolumeBarsView + OscillatorPanels, stats row, sheets.
  Swaps chartCard for ChartGridView when the multi-chart layout ≠ .single.
```

### Subsystems

| Folder | Responsibility |
|---|---|
| `GoldMonitorMac/App/` | `HelixTradingApp` (entry), `AppState`, `Theme`, `DataSourceConfig` (ALL user-configurable values, persisted under `dataSourceConfig.v1`) |
| `GoldMonitorMac/Models/` | `Snapshot`, `Candle`, `TradingPair` (catalog), `MarketCalendar` (COMEX weekend filter; Sunday 6pm ET reopen respected) |
| `GoldMonitorMac/Storage/` | `AppDatabase` (GRDB pool under `~/Library/Application Support/HelixTrading/`), `Schema`, `SnapshotRepo`, `OHLCRepo` (batched multi-row upserts), `Importer`, `ServerImporter`, `OHLCCandleLoader.loadAsync` (all DB reads off-main) |
| `GoldMonitorMac/Fetching/` | `PriceFetcher` (concurrent sources), `Sources.swift`, `BackendClient`, `ProxyTransport` (SOCKS5), `YahooGoldSource` (incremental via `period1`), Faraz sources + `FarazAuthCoordinator`/`FarazLoginWebView` (401 → in-app login), TwelveData WS, `CTraderWSReceiver` |
| `GoldMonitorMac/Scheduling/` | `FetchScheduler` (60s), `YahooScheduler` (10s ticks, 1 Hz `@Published` throttle, `focusedPairID`, `dataResetToken`), `CTraderScheduler`, `NewsStore` |
| `GoldMonitorMac/AI/` | `AIEngine` protocol (`run(system:user:)` → `AsyncThrowingStream<String, Error>`), `ClaudeEngine` (spawns `claude --print --output-format stream-json --include-partial-messages --verbose`, prompt on stdin, `StreamJSONParser` for NDJSON deltas), `CodexEngine`, OpenCode engine (local `opencode run` or remote `opencode serve` + basic auth), `PromptBuilder` (kinds, system prompts, JSON-block parsers), `AnalysisStore` (per-(pair,kind) sessions, history capped at 50), `MarketSnapshot` |
| `GoldMonitorMac/Features/Dashboard/` | `DashboardView`, `ChartView`, `ChartGridView`/`ChartPane`/`ChartPaneView` (multi-chart grid), `ChartDerivedCache`, `ChartWindowing`, indicators/oscillators + setups (`OrderBlocks`, `SteroidOrderBlocks`, `SonarlabOrderBlocks`, `FairValueGap`, `VolumeProfile`, `TradingSessions`, `ZigZag`, `ChangeOfCharacter`, `NYOpenSetup`, `SP2LSetup`, `PinBarComboSetup`, `MicroMapSetup`, `MTRSetup`, `UTBot`), `Drawings`/`DrawingInspector`, `ReplayController`, `RiskCalculatorView`, `IndicatorSettingsPanel`/`Sheet`, `Trades`, `TimeframeCountdown` |
| `GoldMonitorMac/Features/…` | `AIAnalysis` (report UI, MarkdownUI theme), `AutoTrader`, `Journal`, `Alerts`, `Inbox`, `News`, `Portfolio`, `Sidebar`, `Settings`, `Wizard`, `WhatsNewView` |
| `GoldMonitorMac/UI/` | `Card`, buttons, `KeychainHelper` (secrets → macOS Keychain), `WindowConfigurator` |
| `GoldMonitorMacTests/` | macOS unit tests — SP2L, Pin Bar Combo/BTB, MicroMap, MTR detection/geometry/decoding suites |
| `ipadapp/HelixTradingApp-iPad/` | Touch target overrides (see iPad/iPhone section) |
| `CTraderBridge/` | `HelixBridgeBot.cs` cBot (see cTrader bridge section) |
| `Tools/` | `HelixIconGen.swift` — regenerates app icons |

**Secrets**: nothing hardcoded, ever. User config → `DataSourceConfig`;
secrets (API keys, SOCKS5/backend/OpenCode passwords) → Keychain via
`KeychainHelper`. The open-source build ships empty and asks via the wizard.

---

## Key patterns

### State persistence

Persist what should survive a relaunch via `@AppStorage` (or UserDefaults
`didSet` for non-View state); keep ephemera (pan/zoom, sheets, fullscreen,
pane focus) in `@State` / in-memory `@Published`.

| What | Where | Key |
|---|---|---|
| Selected pair | `AppState.selectedPairID` (@Published + UserDefaults) | `selectedPairID` |
| Chart timeframe / type / volume strip | `@AppStorage` in DashboardView | `dashboard.timeframe`, `dashboard.chartType`, `dashboard.showVolume` |
| Indicator/oscillator instances | JSON-encoded `[IndicatorInstance]` / `[OscillatorInstance]` (multi-instance, per-instance params + hidden flag) | `dashboard.indicators` / `dashboard.oscillators` |
| Indicator parameters | UserDefaults via `OscillatorConfig.save()` | `dashboard.indicator.config.v2` |
| Multi-chart layout + panes | `MultiChartLayoutStore` | `dashboard.multichart.v3` |
| Fetch intervals | UserDefaults inside schedulers | `fetch.interval` |
| AI analysis history | `AnalysisStore.saveHistory()` (Codable JSON) | `analysis.history.v1` |
| Data-source config | `DataSourceConfig` | `dataSourceConfig.v1` |

Back-compat rules:
- **Schema-breaking `@AppStorage` change?** Bump the key
  (`…config.v2` → `…config.v3`) — see `OscillatorConfig.storageKey`.
- **New Codable field on a persisted struct?** Make it optional / use
  `decodeIfPresent` in a custom `init(from:)` so old payloads load —
  see `AnalysisStore.HistoryEntry`, `PromptBuilder.TAScenario`,
  `OscillatorConfig`.

### AI analysis

Three layers:

1. **PromptBuilder** — `AnalysisKind` (`full`, `supportResistance`, `fvg`,
   `multiTimeframe`, `confluenceScanner` = raw `"betaTSA"`) + per-kind
   system prompts. Overlay kinds demand structured `### XXX_JSON` blocks
   (`LEVELS_JSON`, `FVG_JSON`, `SCENARIO_JSON`, `SUPPLY_DEMAND_JSON`,
   `SCENARIOS_JSON`); parsers brace-walk via `extractJSONBlock`.
2. **AIEngine** implementations spawn the local CLI as a `Process`, write
   the prompt to stdin, and stream parsed text deltas.
3. **AnalysisStore** (`@MainActor`) — sessions keyed `(pairID, kind)` so
   running pair A's TA while viewing pair B works; on completion parses
   payloads and appends a persisted `HistoryEntry`.

Adding a new analysis kind: add the `AnalysisKind` case (+label/noun) →
system prompt → wire `systemPrompt(for:)` → Codable struct + parser if
structured → `@State` in DashboardView + ChartView param +
`@ChartContentBuilder` if it draws → sibling `userPromptXxx` if the user
prompt differs → `AnalysisStore.recordCompletion` → the exhaustive
`AnalysisPanel.applyOverlayButtons` switch.

### Chart overlays

ChartView's X axis is **bar-index based** (`Double`), not time-based, so
COMEX weekend gaps don't open holes — all marks plot at `Double(barIndex)`
and pan/zoom moves a `ClosedRange<Double>` `xDomain`, never dates.
Cross-timeframe overlays (e.g. HTF CHoCH) carry Dates and re-anchor via
`barIndex(forDate:)` (binary search).

New overlay: `let` param on ChartView → `@ChartContentBuilder` property →
insert before `candleMarks` (behind price) or after (top layer) → fold its
values into `yDomain` → **wire it into `layersPopoverContent`** so the
user can hide it. Hidden state: per-instance `hidden` flags for
indicators/oscillators; boolean `@State` (`srVisible` etc.) for AI overlays.

### News chart layer (time-axis flags)

The economic-calendar flags are the one overlay that is **not** ChartContent
marks — they live in the `chartOverlay`'s `GeometryReader` as SwiftUI views
positioned via `proxy.position(forX:)`, so flags, click hit-testing, and the
detail popover all share one coordinate system and never fight the plot clip.
Shared pieces (`ImpactLevel.chartColor`, `NewsFlagView`, `NewsMarkerPopover`,
`NewsChartMarker`) live in `NewsChartLayer.swift` and compile into both
targets. `ChartView` / `ChartViewiPad` each take `newsEvents:` +
`newsTimeZone:`, expose `visibleNewsMarkers` (events whose `eventAt` maps —
via `barIndex(forDate:)` — into the loaded candle range *and* the visible
domain), and hit-test the bottom ~26–30px band in the drag/tap `onEnded`.
Data comes from `NewsStore.chartEvents` (currency+impact filters, no date
filter); `newsEvents` is in both charts' `Equatable` `==` (compared cheaply
by id + `actual`). The layer is gated by the shared
`@AppStorage("dashboard.showNews")` toggle (Layers popover, on by default),
and `NewsStore` uses `retain/releaseAutoRefresh` refcounting so the News tab
closing doesn't starve the chart's feed (both app entry points also fire one
`news.refresh()` at boot).

### Multi-chart grid

`ChartGridView` renders a **fixed 2×2 grid** every time; unused slots
collapse to zero frame + zero opacity instead of leaving the hierarchy, so
layout switches never tear down a `ChartPaneView` (same trick as the
fullscreen toggle — `Card` varies chrome in place, no `if/else` teardown).
Pane state lives in `MultiChartLayoutStore` (`panes`, `layout`,
`syncSymbol`, `fullscreenPaneID`, in-memory `focusedPaneID`). Drawings are
per-pair and shared with the primary chart via the same `DrawingStore`.

Sidebar symbol selection in grid mode: with `syncSymbol` on, a pick
updates every pane; with it off it updates the **focused** pane (clicking
anywhere in a pane focuses it — `ChartPaneView.onFocus` via a
`simultaneousGesture` tap — with fallback to the first pane, marked by an
accent focus ring). A pick must never be a silent no-op.

### Performance rules (hard-won — do not regress)

- **Heavy chart views are `Equatable`** (`ChartView`, `VolumeBarsView`,
  `OscillatorPanel`) and applied with `.equatable()` at every call site.
  Candle arrays compare via `Candle.seriesEqual` (O(1): count + first id +
  last bar), not full `==`. If an overlay ever fails to refresh, the
  culprit is a missing field in `ChartView.==` — add it there.
- **`ChartDerivedCache`** memoizes indicator/oscillator/OB computation on
  background Tasks (including first compute — no main-thread block on
  split); signature set optimistically at spawn; stale computes re-check
  the signature before publishing.
- **Skip no-op reassignments** — trailing-refresh paths compare the merged
  tail and skip `candles` writes when unchanged (both DashboardView and
  ChartPaneView).
- **1 Hz throttles** — `YahooScheduler` throttles `@Published` tick
  writes; panes throttle their trailing refresh; hidden panes
  (`isVisible == false`) skip loading/refresh entirely and catch up when
  shown.
- Windowed rendering bounds drawn candles; bar-index lookups binary-search;
  OB exhaustion scans are O(n); replay splices one bar instead of
  reloading; AI streaming renders trailing chunks as `Text()` and
  throttles markdown re-chunking to 5 Hz.

---

## Conventions & gotchas

- **macOS 13 / iOS 16 baseline** — no `@Observable`, no `symbolEffect`,
  no `chartScrollableAxes`, no `Stepper(value:in:step:format:)`. Use
  `ObservableObject` + `@Published` + `@StateObject`. `onChange` is the
  single-closure form (no `initial:`).
- **Apple Charts marks bleed** past the plot area on pan/zoom — wrap
  chart-rendering views in `.clipped()`; the price tag uses
  `.annotation(position: .overlay, alignment: .trailing)` to stay inside.
- **Process spawning**: no App Sandbox entitlements, intentionally — the
  app spawns user CLI binaries from `~/.local/bin` etc.
- **GRDB**: writes serialize, reads parallelize (`DatabasePool`). Keep
  heavy queries off the main actor; use `OHLCCandleLoader.loadAsync`.
- **Yahoo's chart endpoint** updates the current minute's partial bar, so
  10s polling gives a live tail free (`YahooScheduler.tickIntervalSeconds`).
- **Heikin Ashi** is render-only (`candles → displayCandles`); indicators
  still read raw closes (TradingView convention).
- **Info.plist keys** must be set via `project.yml` properties (e.g.
  `UILaunchStoryboardName`), or `xcodegen generate` strips them.
- **Touched `project.yml`?** Re-run `xcodegen generate`. New SPM dep goes
  under `packages:` AND `targets.….dependencies`. New Swift files need no
  project.yml change (recursive sources).
- **Always `xcodebuild build` after substantive changes** — the user
  prefers to know it compiles before reading the diff. Run tests when
  touching strategy/detection code (`GoldMonitorMacTests`).

---

## iPad / iPhone target

`HelixTradingAppiPad` reuses the whole `GoldMonitorMac/` tree and overrides
touch views under `ipadapp/HelixTradingApp-iPad/`. Runs standalone (no Mac
at runtime). iOS 16+; `TARGETED_DEVICE_FAMILY = "1,2"`.

- **Adaptive shell**: `AdaptiveRootView` keys off
  `@Environment(\.horizontalSizeClass)` — regular (iPad) →
  `NavigationSplitView` (Navigate + live Watchlist sidebar); compact
  (iPhone) → bottom `TabView` (Chart · Markets · Journal · Inbox · More).
  Both drive the same `AppState.selectedSidebarItem` / `selectedPairID`.
- **Design system** (`ipadapp/.../DesignSystem/`): `AdaptiveMetrics`
  (size-class spacing/type/≥44pt tap targets), `TouchControls`
  (`IconButton` + haptics, `PillButton`, `SegmentedChips`), `Surface`.
  Extend the shared `Theme`, don't fork it.
- **Chart**: decomposed toolbar (iPhone: primary row + scrollable icon
  row; iPad: single row); indicator settings are a floating panel on iPad,
  a detented `.sheet` on iPhone; crosshair uses `onContinuousHover`; drag
  deadzone 3px / Y-lock 6px; pinch throttled.
- **Guardrails**: keep `ChartPlotiPad`'s local `xDomain`/`yDomain`
  isolation (it keeps pan/zoom off the dashboard's hot path); sweep
  AppKit-only `.help()` tooltips (no-op on iOS); AI engines on touch are
  OpenCode-remote (Claude/Codex CLI engines are macOS-only); only the
  selected pair syncs (`focusedPairID`); hidden grid panes skip loading.
- **Redesign status** (from the 6-phase plan): Phases 1–3 (design system,
  adaptive navigation + Markets watchlist, chart chrome) are done and
  shipped in v1.4b7. Remaining: Phase 4 (AI + secondary screens adaptive
  Form/List passes), Phase 5 (iPhone polish — safe area, haptics,
  orientation), Phase 6 (QA on both simulators, chart perf check).
  All Mac indicator overlays now render on `ChartViewiPad` too —
  Pin Bar Combo and Major Trend Reversal were the last two missing and
  are now drawn + exposed in the iPad picker/legend.
  The Mac chart's `Equatable` perf treatment is now mirrored to
  `ChartViewiPad` (`extension ChartViewiPad: Equatable` + `.equatable()`
  at the `ChartPlotiPad` call site) — this stops the whole Charts mark
  tree from re-laying-out on every 1 Hz live tick, the main driver of the
  "High" energy impact on device. HTF CHoCH now renders on iPad too
  (computed in `ChartPlotiPad.reloadHTFChoch`, drawn by
  `ChartViewiPad.htfChochMarks`).

---

## cTrader bridge

`CTraderBridge/HelixBridgeBot.cs` is a cTrader cBot that streams XAU/USD
ticks + bar closes as newline-delimited UTF-8 JSON over loopback TCP
(default `127.0.0.1:7878`) to `CTraderWSReceiver`. When connected and
fresh, it's the **authoritative** XAU/USD source; TwelveData / gold-api
step back in automatically after >10s of silence. Other symbols unaffected.

- **Install**: cTrader → Automate → New cBot `HelixBridgeBot` → paste the
  .cs contents → Build → drag onto an XAU/USD chart (the chart's timeframe
  decides which bar closes stream; attach multiple instances for multiple
  TFs — the Mac merges by `tf`) → confirm host/port/Send ticks/Send bars →
  Start. Mac side: Settings → cTrader → Bridge enabled ("Listening" flips
  to "Connected"; green dot = tick within 10s).
- **Message schema** (versioned by `bot` in the hello frame):

```
{"type":"hello","symbol":"XAUUSD","tf":"M1","account":"Broker/12345","bot":"0.1"}
{"type":"tick","symbol":"XAUUSD","bid":2340.55,"ask":2340.62,"ts":"…"}
{"type":"bar","symbol":"XAUUSD","tf":"M1","o":…,"h":…,"l":…,"c":…,"v":…,"ts":"…"}
{"type":"ping","ts":"…"}
```

- **Customising**: new symbol → `symbolToPairID` in `CTraderScheduler.swift`
  + a pair in `TradingPair.catalog`. Port must match on both sides. LAN
  binding requires editing `CTraderWSReceiver.start` to `.any` — add a
  shared-secret check first; there's **no auth on the bridge today**.
- Troubleshooting: stuck "Listening" = bot not started / wrong port;
  "Connection refused" in the cTrader log = bridge disabled on the Mac;
  connected but no ticks = "Send ticks" off; chip stops counting = cBot
  crashed (check the cTrader Log tab).

---

## Open work

### Confluence Trade Scanner (CTS) improvement plan

Guiding principle: move **detection + scoring** into deterministic Swift;
leave the model to rank, narrate, and judge edge cases. All items open:

- **P0 (correctness)**: emit explicit signed bar indices in `ohlcLine` /
  `mtfSections` (model currently guesses `barStart`/`barEnd` → zones
  render at wrong X); validate trade geometry in parsers (drop
  `tp/entry/sl` violations + entries > N×ATR from close); enforce an R:R
  floor from `StrategyProfile`.
- **P1 (big lever)**: a Swift `SupplyDemandDetector` (impulse ≥ 1.5×ATR(14),
  1–3 base candles) feeding candidate zones with real bar indices — flips
  the model's job to "rank + explain", makes runs reproducible; precomputed
  confluence flags (RSI/EMA trend/FVG/S-R touches/freshness/cross-TF
  nesting) so scoring is mechanical; pass precomputed swing points +
  clustered S/R levels.
- **P2 (flow/feedback)**: one authoritative scored list (Stage 1 vs Stage 2
  disagree today); slim the Expand prompt to Stage 1's JSON, not markdown;
  structured `invalidated_when` `{price, tf, condition}` (fallback queue
  currently triggers on SL touch only); surface per-type/per-score win
  rates and feed back via `PromptBuilder.PriorRunHint`.
- Cross-cutting: verify volume quality for CTS timeframes (Yahoo XAU/USD
  volume is unreliable — else drop the thin-volume rubric line); warn on
  stale data before a scan.
- Key anchors: `AnalysisKind.confluenceScanner`, `systemConfluenceScanner`
  / `…Expand`, `userPromptConfluenceScanner` / `…Expand`, `mtfSections`,
  `ohlcLine`, `parseScoredScenarios` (PromptBuilder.swift);
  `runConfluenceScanner` / `…Expand` (AnalysisStore.swift); expand marker
  `<!--helix-expand-mark-->`.
- Done signals: zones land on the right candles every run; identical bars →
  identical zones + scores; no bad-geometry / sub-floor-R:R scenario ever
  reaches the auto-trader queue; per-type win rate visible.

### Other known follow-ups

- Track down the iPad "Modifying state during view update" warning flood
  (a pre-existing SwiftUI re-render loop; not from the CHoCH/indicator or
  Equatable work — those update state async/off-body). Best caught with a
  symbolic breakpoint on the runtime warning to get the offending view.
- iPad redesign Phases 4–6 (see iPad section).

---

## Version history (condensed)

| Version | Date | Highlights |
|---|---|---|
| Unreleased | 2026-07-13+ | SP2L / Pin Bar Combo / MicroMap / Major Trend Reversal close-confirmed strategies + overlays + unit tests; layer-eye-driven notifications with baselining + dedup; HTF CHoCH zones; grid-pane indicator legend; multi-chart perf overhaul (Equatable views, async first compute); focused-pane sidebar symbol targeting; WTI symbol; Volume Profile overhaul (trading-day sessions at 18:00 ET, ZigZag-trend and visible-range modes, ranked high-volume levels, two-tone up/down buckets, live-tick-aware caching) + unit tests; Ichimoku Cloud + Ichimoku-confluence OBs; Ranked Order Blocks [VP + Ichimoku] graded-OB indicator (Mac + iPad) + unit tests; Volume-Filtered Order Block Detector (swing-anchored OBs, volumetric split, breaker lifecycle, zone merging; Mac + iPad) + unit tests |
| v1.4 b7 | 2026-07-12 | iPhone support (adaptive split/tab shell, Markets watchlist, touch design system), automatic Faraz re-login (WKWebView cookie capture) |
| v1.6 | 2026-07-08 | Multi-instance indicators with per-instance params + floating settings panels; Volume Profile indicator; `ParamSpec` model |
| v1.4 b6 | 2026-07-07 | Chart gesture polish; iPad trailing-window live ticks + deep-history backfill |
| v1.5 | 2026-07-06 | Native iPad target, `./run.sh --ipad`, focused-pair syncing, iPad chart perf |
| v1.4 b5 | 2026-07-05 | Fully async DB reads, incremental Yahoo fetch, batched upserts, 1 Hz publish throttle, AI streaming perf |
| v1.4 | 2026-07-04 | Multiple journals, in-app updater, OpenCode engine, off-main indicator compute, no chart teardown on layout changes |
| v1.3 | 2026-07-02 | Steroid OBs, OB exhaustion lifecycle, VP drawing tool, multi-chart grid, journal day/week/month AI reviews, Inbox, Strategy Scanner, risk calculator, Faraz WebSocket |
| v1.2 | 2026-06-27 | FVG indicator, journal date filters, per-trade AI post-mortems with candle chart |
| v1.1 | 2026-06 | Order Blocks, Trading Sessions, NY Open Setup, axis scaling, free panning, model/effort pickers, Faraz crypto |
| v1.0 | 2026-05-01 | Initial release: multi-source gold feed, bar-index charts, core indicators, Claude CLI analysis, journal, replay, infinite history |

(Full granular notes lived in `CHANGELOG.md` / `RELEASE_NOTES*.md`; recover
via git history if ever needed.)

---

## Session logging (required)

Per the workspace-wide rules (`/Users/pouya/CLAUDE.md`): before starting
work, read `sessions/*.md` from the last 7 days (and `.agentclaw/sessions/`
if present); before ending work, write
`sessions/<agent-name>_<thread-id>.md` with Summary / Changes Made /
Decisions & Reasoning / Unfinished. The `sessions/` folder is committed to
git — never gitignore it. Session logs are the change journal for this
repo; keep decisions there, not in code comments.
