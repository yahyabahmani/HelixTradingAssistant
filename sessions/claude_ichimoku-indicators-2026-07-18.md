# Session: claude / ichimoku-indicators-2026-07-18
Date: 2026-07-18
Project: Helix Trading Assistant (macOS target)

## Summary
User asked whether Ichimoku can detect order blocks (answer: not directly, but
it's good confluence), then asked to develop new indicator(s) and chose "Both".
Added two new `IndicatorKind`s to the macOS target: **Ichimoku Cloud**
(`.ichimoku`) and **Ichimoku-confluence Order Blocks** (`.ichimokuOrderBlock`).
Built green with `xcodebuild` (BUILD SUCCEEDED). iPad target NOT yet ported.

## Changes Made
- **GoldMonitorMac/Features/Dashboard/Ichimoku.swift** (new): pure-function
  Ichimoku engine. Monotonic-deque rolling midlines (O(n)), returns five line
  series + a `CloudPoint` array for the two-tone Kumo. Displacement (±26) baked
  into each point's plot index. Also exposes `snapshots()` giving per-bar
  Tenkan/Kijun + visible cloud edges for confluence scoring.
- **GoldMonitorMac/Features/Dashboard/IchimokuOrderBlocks.swift** (new): reuses
  `OrderBlocks.compute` for base zones, scores each by Ichimoku confluence
  (Kijun/Tenkan/Kumo overlap + cloud-trend agreement; 0–4), filters by
  `minScore`, optional `requireTrendAgreement`.
- **Indicators.swift**: two enum cases + label/color/paramSpecs.
- **Oscillators.swift** (`OscillatorConfig`): `ichi*` and `iob*` fields +
  `decodeIfPresent` lines (synthesized CodingKeys/encode).
- **ChartDerivedCache.swift**: `ichimoku(...)` + `ichimokuOrderBlocks(...)`
  memoized slots; added both to `OverlayData` + signature + the
  `overlayExtremes` Y-domain scan.
- **ChartView.swift**: `ichimokuOutput` / `ichimokuOBZones` computed props;
  `ichimokuMarks(visible:)` (cloud AreaMark ribbon + 5 LineMarks) composed on
  top of candles; `ichimokuOBMarks` zones composed with the other OB zones;
  added both to the `OverlayData` construction in `autoYDomain`.
- **IndicatorSettingsSheet.swift**: "Ichimoku Cloud" + "Ichimoku OB" sections.
- **DashboardView.swift**: `syncIndicatorParamsToConfig` cases for both kinds.

## Decisions & Reasoning
- Cloud rendered as per-bar `AreaMark(yStart:yEnd:)` with per-point green/red
  foregroundStyle — the standard Swift Charts two-tone-ribbon approach.
- Ichimoku goes through a custom `ichimokuMarks` (like UT Bot), NOT the generic
  `indicatorMarks`, because of the cloud fill + displacement + Chikou lag.
- OB confluence detector reuses the existing `OrderBlocks` engine rather than
  re-implementing OB detection — only the Ichimoku scoring is new.

## Unfinished / Next Steps
- **iPad port**: `ipadapp/HelixTradingApp-iPad` has its own parallel copies of
  Indicators/Oscillators/ChartDerivedCache/ChartViewiPad/etc. Same code needs
  mirroring there. Not started.
- **Known limitation**: the cloud's forward 26-bar projection past the last
  candle sits outside the fixed x-domain and is clipped; the cloud over all
  historical candles renders fully. To show the forward tongue, extend
  `effectiveXDomain` by `displacement` when Ichimoku is enabled.
- Not yet run/verified visually in the app; two-tone cloud rendering is the one
  novel path worth eyeballing.
- No unit tests added for the two new engines yet.
