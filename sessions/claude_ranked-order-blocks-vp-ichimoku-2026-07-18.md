# Session: claude / ranked-order-blocks-vp-ichimoku-2026-07-18
Date: 2026-07-18
Project: Helix Trading Assistant (macOS + iPad targets)

## Summary
User asked to add the PineScript v6 indicator "Ranked Order Blocks
[VP + Ichimoku]" to the app, stressing the settings options must match
exactly. Ported it as a new `IndicatorKind` (`.rankedOrderBlock`) with a
faithful bar-by-bar detection/scoring/mitigation engine, wired it into the
config + cache + Y-domain plumbing, and rendered it (graded OB boxes with
grade labels, an on-chart Ichimoku overlay, a right-margin volume profile +
POC, and a grade legend) on both the Mac and iPad charts. All 22 Pine
inputs are exposed with matching labels/defaults/ranges. Both targets build
green; 55 unit tests pass (8 new).

## Changes Made
- **GoldMonitorMac/Features/Dashboard/RankedOrderBlocks.swift** (new): the
  engine. Walks the series bar-by-bar exactly like the Pine runtime — OB =
  last opposite-colour candle before a displacement impulse (body >
  `dispMult` × Wilder-ATR), optional BOS gate, wick/body zones, remove-or-
  grey mitigation, `maxOBs` cap. Each new block is graded A/B/C from a
  Volume-Profile score (0–2, busiest overlapping bucket vs global max over
  the lookback) + an Ichimoku score (0–3, cloud position + Tenkan/Kijun
  alignment). Reuses `Ichimoku.snapshots` for the displaced cloud edges.
  Also returns the final-bar VP histogram (`VPProfile`) for drawing.
- **Indicators.swift**: `.rankedOrderBlock` case + label/color + full
  `paramSpecs` (22 params, Pine labels/defaults/order, enum pickers for
  `zoneSrc`/`mitBy`).
- **Oscillators.swift** (`OscillatorConfig`): 22 `rob*` fields +
  `decodeIfPresent` lines (synthesized CodingKeys/encode; lenient decode).
- **ChartDerivedCache.swift**: `rankedOrderBlocks(...)` memoized slot
  (signature includes last-bar TS/close/volume — live-tick aware). Added
  `rankedOBZones` + `rankedOBIchimoku` to `OverlayData` + its signature +
  the `overlayExtremes` scan (blocks + Ichimoku spans folded into yDomain).
- **ChartView.swift** (Mac): `rankedOBOutput` / `rankedOBIchimokuOutput`
  computed props; `rankedOBMarks(visible:)` composed after `ichimokuOBMarks`
  (Ichimoku cloud+lines, VP histogram+POC, graded boxes+labels, legend);
  OverlayData init updated. `==` needed no change (compares
  `indicatorConfig`, which now carries the `rob*` fields).
- **ChartViewiPad.swift**: mirrored props + `rankedOBMarks(visLo:visHi:)`
  (self-contained — brings its own Ichimoku compute/colours/line helper,
  since the base Ichimoku indicator still isn't wired on iPad); composed +
  OverlayData init updated with real ranked values (was a `.empty` stub).
- **DashboardView.swift** (Mac): `syncIndicatorParamsToConfig` case mapping
  all 22 params → config.
- **DashboardViewiPad.swift**: `IndicatorSettingsBody` gained a "Ranked OB ·
  VP+Ichimoku" section (steppers/toggles/pickers bound to `rob*`), plus a
  `robToggle` helper — iPad edits the global config directly (no per-
  instance sync there).
- **IndicatorSettingsSheet.swift** (Mac, shared file): matching section +
  a `robCheckbox` helper (platform toggle style via `#if os`).
- **GoldMonitorMacTests/RankedOrderBlocksTests.swift** (new): 8 tests —
  wick/body geometry, grade "–" when no ranking, `maxScore` per enabled
  ranking, close-vs-wick mitigation, remove-vs-grey, empty input.
- **AGENTS.md**: indicator list + Unreleased row updated.

## Decisions & Reasoning
- Built a standalone engine rather than reusing the run-length `OrderBlocks`
  detector: the Pine detection (single opposite candle + displacement) and
  its per-block A/B/C grading differ from the existing engines, and "exactly
  as it is" mattered. Reused `Ichimoku.compute`/`snapshots` (same periods)
  for both the drawn overlay and the confluence scoring.
- The generic per-instance floating `IndicatorSettingsPanel` (Mac) renders
  every `ParamSpec` automatically, so it's the guaranteed exact-settings
  surface on Mac; the explicit Sheet/iPad sections are for parity.
- VP scoring recomputes the lookback histogram only at OB-creation bars
  (sparse), so it stays cheap; the drawn profile is one window at the last
  bar. Both go through the live-tick-aware cache slot.
- iPad renders the indicator fully (its ranking Ichimoku is self-contained),
  but iPad's `OverlayData` still stubs the *base* `.ichimoku` indicator to
  `.empty` — unchanged, that base indicator remains Mac-only.

## Build/Verify
- `xcodebuild -scheme HelixTradingApp -destination platform=macOS build` →
  BUILD SUCCEEDED.
- `xcodebuild -scheme HelixTradingAppiPad -destination 'iPad Pro 11-inch
  (M5)' build` → BUILD SUCCEEDED.
- `… -scheme HelixTradingApp test` → 55 tests, 0 failures (8 new
  RankedOrderBlocksTests + 47 pre-existing).
- NOT yet eyeballed in the running app — worth a visual pass: add the
  indicator, toggle Show Ichimoku / Show VP / Show POC / Show legend /
  Show grade labels, and confirm A/B/C boxes + the right-margin VP render
  and the mitigation remove/grey behaviour.

## Unfinished / Next Steps
- Visual QA on Mac + iPad (see above); the grade legend is anchored at the
  top-right domain corner (`position: .bottomLeading`) and may want nudging.
- The right-margin VP uses the shared `vpMargin` geometry (hugs the visible
  right edge) rather than Pine's fixed `bar_index+2` offset, so it stays on
  screen while panning — a deliberate deviation from the literal Pine draw.
- No forward Ichimoku tongue past the last candle (same fixed-x-domain
  clipping limitation noted for the standalone Ichimoku indicator).

## Addendum — second indicator (Volume-Filtered Order Block Detector)
User then asked to add a second Pine indicator, Mehdi Pirhayati's
"Volume-Filtered Order Block Detector". Added it end-to-end with the same
integration pattern.

### Changes
- **GoldMonitorMac/Features/Dashboard/VolumeFilteredOrderBlocks.swift**
  (new): one-sided swing-pivot detection (right length = `swingLength`),
  OB anchored to the lowest-low / highest-high candle between the pivot and
  the close-through break, breakout volume split into up/down shares +
  balance %, ATR(10)×3.5 size filter, breaker lifecycle (wick/close
  invalidation → removed once price trades back through), 30-per-side cap,
  and optional merge of overlapping same-direction zones. Bar-index based
  (Pine's `time`/box geometry mapped to indices); detection window is the
  last 1750 bars like the original.
- **Indicators.swift**: `.volumeFilteredOrderBlock` + label/color +
  `paramSpecs` (Show Historic Zones, Volumetric Info, Zone Invalidation
  Wick/Close, Swing Length 3…50, Zone Count High/Medium/Low/One — the
  non-DEBUG Pine inputs; colours use the app theme since `ParamSpec` has no
  colour type).
- **Oscillators.swift**: 5 `vfob*` fields + decode. **DashboardView.swift**
  + **DashboardViewiPad.swift**: sync case / settings section.
  **IndicatorSettingsSheet.swift**: Mac section.
- **ChartDerivedCache.swift**: `volumeFilteredOrderBlocks(...)` slot
  (live-bar-aware sig) + `volumeFilteredOBZones` in OverlayData/sig/scan.
- **ChartView.swift / ChartViewiPad.swift**: `volumeFilteredOBZones` prop +
  `vfobZoneCount` preset→count helper + `volumeFilteredOBMarks` (zone box,
  dashed border + faded fill for breakers, a top/bottom volumetric split
  bar, and a "volume (balance%)" label) composed after `rankedOBMarks`;
  OverlayData init updated.
- **GoldMonitorMacTests/VolumeFilteredOrderBlocksTests.swift** (new): 4
  tests — bullish detection, volume-split invariant + pct bounds,
  historic-off ≤ historic-on breaker count, empty input.

### Decisions
- Standalone engine again (swing-pivot detection + volumetric split are
  unlike the existing OB engines). The Pine multi-timeframe scaffolding
  collapses to single-TF here (`timeframe1 = ""`, one enabled TF), so it's
  omitted. Persian zone labels replaced with a compact volume/percentage
  tag; the left-anchored mirrored volume bars became a simple two-tone
  top/bottom split at the block's left edge.
- Colour inputs from the Pine script are dropped (theme colours, like every
  other OB overlay) — the functional bool/enum/int settings are matched
  exactly.

### Build/Verify
- macOS + iPad: BUILD SUCCEEDED. Tests: 59 total, 0 failures (4 new
  VolumeFilteredOrderBlocksTests + 55 previous). Not yet eyeballed in the
  running app — worth a visual pass on the zone boxes + volumetric split.
