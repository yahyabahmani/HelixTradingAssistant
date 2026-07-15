# Session: claude / htf-choch-zones-2026-07-14
Date: 2026-07-14
Project: HelixTradingApp (macOS)

## Summary
Added a multi-timeframe option to the Change of Character (CHoCH)
indicator: the user picks a higher timeframe in the CHoCH settings and the
last N (default 3) HTF CHoCH zones are projected onto whatever lower
timeframe is currently displayed, drawn muted and tagged "·HTF" as
reference context for LTF entries. macOS only for now (iPad ChartViewiPad
not yet wired). Reference-only — no notifications, per the chosen design.

## Changes Made
- `GoldMonitorMac/Features/Dashboard/Oscillators.swift`: 3 new config
  fields on OscillatorConfig — `chochHTFEnabled` (Bool, false),
  `chochHTFTimeframe` (String, "1h"), `chochHTFCount` (Int, 3) — with
  back-compat `decodeIfPresent` lines. Synthesized CodingKeys/encode pick
  them up automatically.
- `GoldMonitorMac/Features/Dashboard/Indicators.swift`: 3 new ParamSpecs
  under `.changeOfCharacter` (htfEnabled bool, htfTimeframe enum
  15m/30m/1H/4H/1D, htfCount double 1...8) — drives the settings UI
  automatically.
- `GoldMonitorMac/Features/Dashboard/ChangeOfCharacter.swift`: new
  `DatedZone` struct (price fields carry over; bar indices → `bucketStart`
  Dates) + `static func datedZones(...)` adapter that runs `compute` then
  re-anchors each zone's indices to dates.
- `GoldMonitorMac/Features/Dashboard/ChartView.swift`: new
  `htfChochZones: [ChangeOfCharacter.DatedZone]` prop (defaulted, so grid
  panes don't break); `htfChochMarks` / `htfChochMark` renderers that map
  each zone Date → LTF x via the existing `barIndex(forDate:)` and reuse
  `chochZoneRect` with muted/dashed styling + "·HTF" tags; inserted before
  `chochMarks`; folded into `autoYDomain`.
- `GoldMonitorMac/Features/Dashboard/DashboardView.swift`: `@State
  htfChochZones`; `reloadHTFChoch()` (loads HTF candles via
  `OHLCCandleLoader.loadAsync`, computes `datedZones`); param-decode
  mapping for the 3 new keys; passes `htfChochZones` into ChartView;
  triggers reload from `reloadCandles()` and from add/remove/update/toggle
  of the CHoCH indicator.

## Decisions & Reasoning
- The chart X axis is bar-index based on the CURRENT timeframe, so HTF zone
  indices are meaningless there. Fix: re-anchor to `bucketStart` dates, map
  back with the existing `barIndex(forDate:)` binary search. Prices are
  timeframe-independent → plot directly on Y.
- Guard `htf.seconds > timeframe.seconds` so you can't show a same/lower TF
  as "higher". Also gate on the CHoCH indicator being visible + HTF enabled;
  clears the overlay otherwise.
- Reference-only (no alerts) + muted "·HTF" styling + configurable count
  (default 3) — the three product choices the user picked.
- Computation lives in DashboardView (owns repo/pair/tf/replay), not
  ChartView (a pure render struct with no repo access).

## Unfinished / Next Steps
- BUILD NOT YET VERIFIED: `xcodegen generate` cleared the SwiftPM cache and
  GRDB is re-cloning over a very slow link (~30 KiB/s); package resolution
  hadn't finished at commit time. Re-run `xcodebuild ... build` once the
  clone completes and fix any compile errors before merging.
- iPad `ChartViewiPad` not wired — Mac-only so far. Mirror the same
  DatedZone projection there if desired.
- Consider clamping the yDomain fold if an HTF zone sits far from current
  price (could zoom the chart out); currently folded like other overlays.
