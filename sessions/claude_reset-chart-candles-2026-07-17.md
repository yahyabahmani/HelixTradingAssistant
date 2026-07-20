# Session: claude / reset-chart-candles-2026-07-17
Date: 2026-07-17
Project: HelixTradingApp (GoldMonitorMac + iPad target)

## Summary
User: "the reset chart button, from anywhere in both ipad and mac app, must
reset chart based on the candles, not indicators." Root cause: every Reset
path ended by handing the Y axis back to `autoYDomain`, which folds in
indicator/overlay extremes (`derived.overlayExtremes` — S/R, FVG, order
blocks, scenarios, HTF CHoCH, …). So a far-away SMA / target line would
expand the price scale and squash the candles after a reset. The Mac
`resetChart()` even computed a correct candle-only Y fit, then reverted
`yDomain` to nil after 350ms — snapping right back to the indicator-inclusive
fit.

Fixed by giving every Reset a shared candle-only Y fit that **persists**
(no revert to nil), leaving normal live/pan auto-fit and the price-axis
double-click auto-fit unchanged.

## Changes Made
- Features/Dashboard/ChartWindowing.swift: new
  `ChartWindow.candleYDomain(candles:domain:)` — padded low/high over the
  window's visible bars, ignoring indicators/overlays. Single source of
  truth for all Reset actions.
- Features/Dashboard/DashboardView.swift `resetChart()`: use `candleYDomain`
  over `ChartWindow.defaultDomain(count:visible:150)`; dropped the
  `Task { … yDomain = nil }` revert so the candle fit stays. (Drives the FAB
  Reset + the "Reset Chart" context-menu item.)
- Features/Dashboard/ChartPaneView.swift: new `resetChart()` (mirrors the
  above); the grid pane's "Reset Zoom" menu now calls it instead of setting
  xDomain/yDomain = nil.
- ipadapp/.../ChartViewiPad.swift: new `resetChart()`; the chart's
  double-tap-to-reset calls it.
- ipadapp/.../DashboardViewiPad.swift (`ChartPlotiPad`): new `resetChart()`;
  the "Reset Zoom" tap-and-hold context menu calls it.

## Decisions & Reasoning
- **Scoped to Reset, not global auto-fit**: left `autoYDomain`'s overlay
  fold-in intact so live viewing / pan still keep indicators + AI overlays
  (S/R lines, scenario targets) on-scale. Only the explicit Reset actions
  frame candles. Avoids clipping AI overlays during normal use.
- **Persist the pinned Y (don't revert to nil)**: reverting was the actual
  bug — it re-introduced indicators. Pinning matches the existing
  "manual Y pin" semantics (drag the price axis); the user can double-click
  the price axis to return to full overlay-inclusive auto-fit.
- One shared `candleYDomain` helper so Mac single/grid + iPad single all
  behave identically ("from anywhere").
- Left the Mac price-axis / time-axis double-click auto-fit affordances as-is
  (they're "auto-fit axis", distinct from "Reset Chart").

## Build/Verify
- macOS build → BUILD SUCCEEDED. iPad build → BUILD SUCCEEDED.
- NOT yet exercised in the running app.

## Unfinished / Next Steps
- Manual check: enable an indicator/overlay that sits well away from price
  (e.g. an SMA on a long period, or an AI S/R line far from spot), then hit
  Reset from each surface (Mac FAB, Mac right-click "Reset Chart", grid pane
  "Reset Zoom", iPad double-tap, iPad tap-and-hold "Reset Zoom") and confirm
  the candles fill the pane vertically instead of being squashed by the
  overlay. Confirm pan/live behaviour and the price-axis double-click still
  auto-fit including overlays.
- If the user also wants the price-axis double-click (and normal auto-fit) to
  ignore indicators, that's a one-line change in `autoYDomain` (drop the
  `overlayExtremes` fold-in) in both charts — deferred pending confirmation.
