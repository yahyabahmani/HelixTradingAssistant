# Session: claude / ipad-missing-indicators-2026-07-16
Date: 2026-07-16
Project: HelixTradingApp (GoldMonitorMac / iPad target)

## Summary
User: "add all the indicators that is in macapp and not in ipad/iphone
app." Both targets share the `GoldMonitorMac/` tree and the same
`IndicatorKind` enum, so the gap wasn't the enum — it was that
`ChartViewiPad` never rendered two of the overlays the Mac `ChartView`
draws, and the iPad picker hid one of them. The two missing indicators:
- **Pin Bar Combo** (`.pinBarCombo`) — was in the iPad picker but had no
  `pinBarComboMarks`, so enabling it did nothing.
- **Major Trend Reversal** (`.mtrStrategy`) — filtered out of the iPad
  picker/legend AND had no `mtrMarks`.
Ported both overlays (marks + result computed props + helpers) from the
Mac chart to the iPad chart, folded their prices into the iPad yDomain
auto-scale loop, and removed the `.mtrStrategy` picker/legend filters.
(HTF CHoCH stays macOS-only — it's a cross-TF projection of the CHoCH
indicator, not a separate kind; still a listed follow-up.)

## Changes Made
- ipadapp/HelixTradingApp-iPad/Features/Dashboard/ChartViewiPad.swift:
  - Added `pinBarComboResults` + `pinBarComboResultFitsCurrentCandles`
    and `mtrResults` + `mtrResultFitsCurrentCandles` computed props
    (mirroring the Mac window-clip + index-validate pattern; use the
    shared `derived` ChartDerivedCache `.pinBarComboSetup`/`.mtrSetup`).
  - Added `pinBarComboMarks` + `pinBarComboColor`/`pinBarComboStatusLabel`
    and `mtrMarks` + `mtrDirectionColor`/`mtrStatusLabel`, copied from the
    Mac `ChartView` versions.
  - Wired `pinBarComboMarks` and `mtrMarks` into the chart body (after
    `sp2lMarks` / `microMapMarks`).
  - Folded both results' prices into the inline yDomain min/max loop.
- ipadapp/HelixTradingApp-iPad/Features/Dashboard/DashboardViewiPad.swift:
  - Picker: `IndicatorKind.allCases.filter { $0 != .mtrStrategy }` →
    `IndicatorKind.allCases`.
  - On-chart legend `activeIndicators`: dropped the `$0 != .mtrStrategy`
    condition.
- AGENTS.md: replaced the "MTR is hidden from the iPad picker" note with
  "all Mac indicator overlays now render on ChartViewiPad".

## Decisions & Reasoning
- Copied the Mac overlay code verbatim (same mark structure/labels) for
  visual parity rather than re-deriving; iPad already had matching
  `setupTag`, so only the direction/status helpers were new.
- Kept HTF CHoCH out of scope — it's not a separate IndicatorKind and is
  already tracked as its own follow-up.

## Build/Verify
- `xcodebuild -scheme HelixTradingAppiPad -destination
  'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build`
  → BUILD SUCCEEDED.
- Not manually exercised in the simulator UI.

## Unfinished / Next Steps
- Manual check on iPad/iPhone: enable Pin Bar · SP2L + BTB and
  MTR · Major Trend Reversal from the indicator picker and confirm the
  zones/plan lines draw and the legend toggles hide/show them.
- Still open (pre-existing): mirror the Mac `Equatable` perf treatment to
  `ChartViewiPad`; wire HTF CHoCH into the iPad chart.
