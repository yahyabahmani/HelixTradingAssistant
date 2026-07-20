# Session: claude / multichart-perf-2026-07-15
Date: 2026-07-15
Project: HelixTradingApp (GoldMonitorMac)

## Summary
User reported the dashboard is acceptable in single-chart mode but gets
very laggy once the chart is split into 2 columns/rows or a 2×2 grid.
Read the multi-chart render path, diagnosed the causes, and fixed all of
them. Build (xcodebuild macOS Debug) passes.

## Root causes found
1. Every `ChartPaneView` observes `YahooScheduler` as `@EnvironmentObject`,
   so a single `objectWillChange` (~1 Hz, plus unrelated @Published fields)
   re-evaluated ALL panes' full bodies → N× Apple Charts re-layouts
   (price + volume + each oscillator = its own Chart) per tick.
2. `ChartDerivedCache.resolve` computed the FIRST value for each slot
   synchronously on the main thread. On a split, every new pane's every
   indicator/order-block/etc computed inline over full history for 2–4
   panes at once → the split-moment hitch.
3. Pane `refreshTrailing` / Dashboard `refreshTrailingCandles` reassigned
   `candles` every second even when the trailing bar was unchanged →
   needless redraw cascade 1×/sec/pane.
4. Nothing isolated the heavy `ChartView` from unrelated re-renders (not
   Equatable), so SwiftUI always re-invoked its body + Charts layout.

## Changes Made
- Models/Candle.swift: added `Candle.seriesEqual(_:_:)` — O(1) series
  equality proxy (count + first id + last bar) matching the cache's own
  signature philosophy. Used by the new Equatable chart views.
- Features/Dashboard/ChartView.swift: `extension ChartView: Equatable`
  comparing all render-affecting value inputs (candles via seriesEqual,
  domains, indicators, all overlay arrays, livePrice, flags), ignoring
  closures + internal @State.
- Features/Dashboard/VolumeBarsView.swift, OscillatorPanel.swift: made both
  Equatable (series + accent/instance + xDomain).
- Applied `.equatable()` at every chart call site: ChartPaneView (macOS
  ChartView + volume + oscillators) and DashboardView (primary chart +
  volume + oscillators). iOS ChartViewiPad left untouched (out of scope).
- Features/Dashboard/ChartDerivedCache.swift: `resolve` now runs the
  first-time compute on a background Task too (no more main-thread block
  at split). Sets `signature` optimistically at spawn (prevents perpetual
  cancel/respawn when renders outpace compute) and re-checks
  `slot.signature == signature` before publishing (a stale superseded
  compute can't clobber a fresher value).
- Skip `candles` reassignment when the merged tail is unchanged, in both
  ChartPaneView.refreshTrailing and DashboardView.refreshTrailingCandles.

## Decisions & Reasoning
- Equatable isolation (not removing the @EnvironmentObject) is the reliable
  fix: even after removing observation, an ancestor (DashboardView) still
  re-renders on ticks and cascades down through non-Equatable structs with
  closures. `.equatable()` is what actually lets SwiftUI skip the Charts
  layout. livePrice is IN the comparison so exactly the one pane whose
  price changed redraws; the rest are skipped.
- Compared candles via a cheap signature, not full array ==, to keep the
  hot pan/zoom path (which changes xDomain and legitimately redraws) O(1).
- Making first-time compute async trades an instant first paint of overlays
  for a smooth split; candles still draw immediately, overlays land a frame
  later — consistent with the cache's existing "trails by a frame" design.

## Build/Verify
- `xcodebuild -project HelixTradingApp.xcodeproj -scheme HelixTradingApp
  -configuration Debug -destination 'platform=macOS' build` → BUILD SUCCEEDED.
- NOTE: project.yml + HelixTradingApp.xcodeproj live at the REPO ROOT, not
  in GoldMonitorMac as CLAUDE.md's build snippet says. Build from root.
- Not manually exercised in the running UI this session.

## Unfinished / Next Steps
- Manual UI check recommended: split to 2×2, confirm charts stay smooth on
  live ticks, indicators still appear (a frame later is expected), hover
  crosshair + drawing still work, and that toggling an indicator/overlay
  still updates the chart (validates the Equatable field list is complete).
- If any overlay ever fails to refresh, the culprit is a missing field in
  `ChartView.==` — add it there.
- Consider mirroring the Equatable treatment to iOS ChartViewiPad.
