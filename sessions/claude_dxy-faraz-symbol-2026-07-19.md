# Add DXY (Faraz `TVC_DXY`) — Mac + iPad/iPhone

**Date:** 2026-07-19

## Goal

Add the US Dollar Index as a tradable pair sourced from Faraz's
TradingView-UDF feed under the symbol `TVC_DXY`.

## Changes

- `GoldMonitorMac/Models/TradingPair.swift` — catalog entry
  `dxy` / "US Dollar Index" / `DXY`, category `.indices`, `#22C55E`.
- `GoldMonitorMac/Fetching/FarazHistorySource.swift` — `"dxy": "TVC_DXY"`
  in `symbolByPairID`.
- `GoldMonitorMac/Scheduling/YahooScheduler.swift` — `PairConfig` for
  `dxy` (`yahooSymbol: "DX-Y.NYB"`, no Twelve Data feed,
  `respectsWeekend: true`).
- Settings copy on both targets: Indices toggle subtitle now mentions DXY.

## Notes for next time

- `FarazHistorySource.symbolByPairID` is the single switch that makes a
  pair Faraz-capable. It feeds `usesFaraz()`, `farazPairIDs`, the history
  fetch, and the WS room subscriptions (`FarazWebSocketStream` inverts
  the map), so live ticks + 1m/5m/1h/1d bars all follow from one entry.
- iPad/iPhone needed **no** separate work: the `HelixTradingAppiPad`
  target in `project.yml` compiles `GoldMonitorMac/` wholesale and the
  excludes list doesn't cover the model / scheduler / source files.
  Sidebar filtering is by `TradingPair.Category`, so DXY shows up under
  Indices on both automatically.
- WTI sits under `.forex` despite being a commodity; DXY was filed under
  `.indices`. Grouping is purely UX — revisit if the sidebar feels off.

## Unverified

`TVC_DXY` and `DX-Y.NYB` were not exercised against the live APIs — that
needs a valid Faraz session cookie. A wrong symbol surfaces as a
`faraz dxy/<tf>: …` string in `YahooScheduler.lastError` rather than a
hard failure.

## Build

Both targets build clean (`platform=macOS`, `generic/platform=iOS Simulator`).
