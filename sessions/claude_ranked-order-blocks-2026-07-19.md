# Ranked Order Blocks indicator — 2026-07-19

## Goal

Add the PineScript v6 "Ranked Order Blocks Pro [Swing + VP + Ichimoku]"
indicator to the app as a new indicator kind.

## What landed

New file `GoldMonitorMac/Features/Dashboard/RankedOrderBlocks.swift` —
pure-function port of the Pine logic:

- **Swing engine.** Pivot high/low confirmed `swingLength` bars later
  becomes the protected swing; a close through it (BOS) walks back to the
  impulse's extreme candle and marks its range. Zones wider than
  `maxATRMult × ATR` (Wilder ATR, seeded like `ta.atr`) are discarded.
- **Lifecycle.** Live → breaker (right edge freezes at the break bar) →
  removed once price passes fully through the far side. Mitigation probe
  is wick or body per `invalidation`.
- **Ranking.** 0–2 Volume Profile (zone's busiest row vs the profile
  peak, over `vpLookback` bars) + 0–3 Ichimoku (cloud position +
  Tenkan/Kijun agreement). ≥70% → A, ≥40% → B, else C. Either leg can be
  switched off; `maxScore` reports the live divisor so the badge reads
  `A 4/5`, `B 2/3`, etc. Both off → unranked.
- **Merging.** Same-direction zones whose rectangles overlap by more than
  `mergeThreshold`% of their union fuse into one; bounded at 16 passes so
  a pathological input can't spin (Pine's `while` is unbounded).

Wiring, mirroring the Sonarlab OB layer:

- `Indicators.swift` — `.rankedOrderBlock` case + label/colour/paramSpecs
  (18 tunables; the floating per-instance panel builds itself from these).
- `Oscillators.swift` — `rob*` persisted fields (lenient `decodeIfPresent`
  so existing saved configs survive) + `rankedOrderBlockConfiguration`.
- `DashboardView.swift` — param→config sync case.
- `ChartDerivedCache.swift` — memo slot keyed on candle signature +
  config, plus `OverlayData`/extremes plumbing for the auto Y-domain.
- `ChartView.swift` + `ChartViewiPad.swift` — `rankedOBMarks`: graded
  rectangles (A bold, B half, C grey; breakers dashed grey) with a
  `A 4/5 ·M ·BRK` badge, gated on `robShowLabels`.
- `IndicatorSettingsSheet.swift` — a section in the global sheet for parity
  with the other indicators.

## Deliberately not ported

The Pine script also *draws* the VP histogram, the Ichimoku cloud, and a
legend table. Here VP and Ichimoku are scoring inputs only — the app
already ships a standalone Volume Profile indicator, and the chart layer
renders just the graded zones. Pine's `alertcondition`s were skipped too;
wiring them into the notification Inbox is a separate change.

## Verification

- `xcodebuild` Debug: macOS ✅, iPad simulator ✅.
- Engine driven standalone (`swiftc` harness, synthetic OHLC): uptrend →
  3 bull zones / 0 bear, downtrend → the exact mirror, choppy series →
  both directions plus breakers and a merged zone, all three grades seen.
  Degenerate inputs (empty, 5 bars, flat prices, `volume == nil`) return
  cleanly rather than trapping.

Then driven in the running Mac app on XAU 15m, which turned up a real bug:
**the grade badges didn't render at all.** Three compounding causes, all
in the annotation, none of them in the engine:

1. Anchored at `xEnd` (the last bar) with `.trailing`, the capsule sat
   flush against the price axis and the plot area clipped it away. Moved
   it to the centre of the zone, which is also what the Pine original
   does (`text_halign/valign = center`).
2. Once visible it collapsed to an unreadable ~14pt sliver: an overlay
   annotation on a zero-size `PointMark` is proposed zero width, so the
   `Text` truncated. `.fixedSize()` on the label is load-bearing —
   worth remembering for any future annotation built this way.
3. A plain midpoint puts the badge off-screen for zones whose order
   block is far to the left (they all run to the right edge of the
   chart). `rankedOBLabelX` now clamps the anchor into the visible slice
   of the zone, inset 5% from the plot edges.

Verified on screen afterwards: bear zones read `B 2/5` / `B 3/5`, the
merged bull zone reads `B 3/5 ·M`, and all four badges stay in view
after panning back through history.

## Follow-ups worth considering

- Strategy-signal notifications on new A-grade zones / breaker formation
  (the Pine alerts).
- Ichimoku as its own line-series indicator, if the cloud is wanted
  visually rather than just as a score input.
