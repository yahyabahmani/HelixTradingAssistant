# Session: claude / ipad-chart-energy-2026-07-16
Date: 2026-07-16
Project: HelixTradingApp (iPad target)

## Summary
Continuation of the same thread. User ran the iPad build, showed Xcode's
Energy gauge reading **High** (CPU ~53%) plus a console flooded with
"Modifying state during view update, this will cause undefined behavior."
Diagnosed two *separate* issues:
1. **High energy** — `ChartViewiPad` was never made `Equatable` / applied
   with `.equatable()` (unlike the Mac `ChartView`), so every ~1 Hz
   `YahooScheduler` tick (and every unrelated `@Published` write)
   cascaded a full Charts mark-tree relayout. This is the documented
   AGENTS open item and the real energy driver. Fixed.
2. **"Modifying state during view update" flood** — a pre-existing
   SwiftUI re-render loop. Confirmed it is NOT from this session's
   CHoCH/indicator work: that code updates state asynchronously
   (`@MainActor` task + `onChange`), never during `body`. Could not
   statically pin the exact offending view; left as a follow-up (best
   caught with a symbolic breakpoint on the runtime warning).

## Changes Made
- ipadapp/HelixTradingApp-iPad/Features/Dashboard/ChartViewiPad.swift:
  - Added `extension ChartViewiPad: Equatable` with a `==` mirroring the
    Mac `ChartView.==` (candles via `Candle.seriesEqual`, all
    render-affecting value props incl. the new `htfChochZones`; closures
    + internal `@State` deliberately excluded).
- ipadapp/HelixTradingApp-iPad/Features/Dashboard/DashboardViewiPad.swift:
  - Applied `.equatable()` to the `ChartViewiPad(...)` call in
    `ChartPlotiPad` (right after the initializer, before `.frame`).
- AGENTS.md: marked the "mirror Equatable to ChartViewiPad" item done;
  added a new follow-up for the state-during-update warning flood.

## Decisions & Reasoning
- Mirrored the Mac `==` field-for-field (minus props the iPad chart
  doesn't have: `indicatorInstances`, `isPickingReplayAnchor`,
  `showHoverTooltip`) to avoid a stale-overlay bug from a missing field.
- `.equatable()` only gates *parent-driven* invalidations; the chart's
  own `@StateObject derived` (ChartDerivedCache) still re-runs `body`
  when a background compute publishes, so overlays keep refreshing — same
  as the Mac, which ships this exact pattern.
- Did NOT attempt a blind fix for the "modifying state during view
  update" warnings — my static search of the iPad views (body-level
  assignments, AppState/scheduler writes, bridges, chart overlay) didn't
  surface an obvious during-body mutation, and guessing risks churn.

## Build/Verify
- `xcodebuild -scheme HelixTradingAppiPad -destination
  'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build`
  → BUILD SUCCEEDED.
- Not re-run on device/simulator this session — the energy improvement
  needs confirming in Xcode's Energy gauge after the user re-runs.

## Unfinished / Next Steps
- Re-run on device and re-check the Energy gauge; expect a large CPU drop
  now that the chart isn't relaying out every tick.
- Hunt the "Modifying state during view update" source: add a symbolic
  breakpoint on the SwiftUI runtime-warning symbol (or `os_log` fault)
  to capture the offending view's stack, then fix that view to mutate in
  `.task`/`.onChange`/`onReceive` instead of during `body`.
