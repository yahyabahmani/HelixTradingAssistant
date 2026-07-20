# Session: claude / grid-pane-indicator-legend-2026-07-15
Date: 2026-07-15
Project: HelixTradingApp (GoldMonitorMac)

## Summary
User asked that in the multi-chart columns/rows/2x2 grid view, each pane
show a TradingView-style indicator list on the top-left of the chart with
hide/show toggles and a settings icon — like the primary single-chart view
already has. Implemented the legend overlay on ChartPaneView, filtered
hidden layers out of the render, and wired settings panels. Build succeeds.

## Changes Made
- GoldMonitorMac/Features/Dashboard/ChartPaneView.swift:
  - Added @State: indicatorLegendExpanded, editingIndicatorID, editingOscillatorID.
  - Added `indicatorLegendOverlay` (top-left, collapsible) + `legendInstanceRow`
    (swatch/label/eye/gear) + `legendOscillatorRow` (gear/label/eye), mirroring
    DashboardView's legend but scoped to the pane and writing back via onUpdate.
  - Added `visibleIndicatorInstances` / `visibleOscillatorInstances` (filter !hidden);
    ChartView (mac + iPad) and oscillator ForEach now use the visible lists, so the
    eye toggle actually adds/removes marks + oscillator sub-panels.
  - Added toggleIndicatorHidden / toggleOscillatorHidden / updateIndicatorInstance /
    updateOscillatorInstance helpers (mutate a copy of `pane`, call onUpdate).
  - Overlaid IndicatorSettingsPanel / OscillatorSettingsPanel (top-left) driven by
    the editing IDs, opened by the legend gear buttons.

## Decisions & Reasoning
- Reused existing IndicatorSettingsPanel/OscillatorSettingsPanel and the same
  legend styling as DashboardView for consistency, rather than a new UI.
- Kept the header's existing "Indicators" dropdown (add/remove) — legend only
  manages existing layers (hide/show/settings), matching how the primary chart
  pairs its Layers popover with the on-chart legend.
- Persistence is free: edits go through ChartPane -> onUpdate -> MultiChartLayoutStore.

## Unfinished / Next Steps
- Not manually run in the app UI this session; build (xcodebuild macOS Debug) passed.
- If the legend feels crowded in `.grid2x2` compact panes, consider auto-collapsing
  it when `isCompact`.
