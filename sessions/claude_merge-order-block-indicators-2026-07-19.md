# Merge `origin/add-order-block-indicators` into `main` — 2026-07-19

## What happened

Merged the cached `origin/add-order-block-indicators` branch (commit
`46f4989`) into `main`. Note: `git fetch` failed (SSH publickey denied),
so the merge used the **locally-cached** remote-tracking ref — it may not
reflect the latest remote state. Worth re-checking once SSH auth works.

The branch forked from `d3258e5`, the same point `main`'s `0c8f3c6`
branched from, so both sides independently added an indicator named
`RankedOrderBlocks`.

## The collision

Two incompatible indicators shared the name `RankedOrderBlocks`:

| | main (`0c8f3c6`) | branch (`46f4989`) |
|---|---|---|
| Detection | swing pivot + BOS | displacement candle (body > ATR×mult) |
| Lifecycle | breakers, zone merging | mitigation, remove-or-grey |
| Zone API | `top`/`bottom`, `Grade` enum | `high`/`low`, `String` grade, `Output` + VP |

Git auto-merged the *supporting* code on both sides rather than
conflicting, so the tree had duplicate declarations that could never
compile: two `RankedOBSig`/`rankedOBSlot` pairs, two `rankedOBMarks`, two
`case rankedOrderBlock` enum cases, two `rob*` config blocks, and two
decoder blocks.

**Decision (user's call): keep main's swing-based version, drop the
branch's.** The branch's *other* indicators were all kept.

## Kept from the branch

- `Ichimoku.swift`, `IchimokuOrderBlocks.swift`,
  `VolumeFilteredOrderBlocks.swift`
- Volume Profile overhaul (three modes: session / ZigZag-trend /
  visible-range)
- `VolumeProfileTests.swift`, `VolumeFilteredOrderBlocksTests.swift`
- App icons, `project.yml` changes

## Removed (branch's ranked-OB implementation)

- `RankedOrderBlocks.swift` → took main's version wholesale
- `GoldMonitorMacTests/RankedOrderBlocksTests.swift` (tested the dropped
  engine)
- `ChartDerivedCache.swift`: branch's `RankedOBSig`/`rankedOBSlot`/
  `rankedOrderBlocks(...)` block; dropped the `rankedOBIchimoku` field
  from `OverlayData` + its yDomain scan
- `ChartView.swift`: `rankedOBOutput`, `rankedOBIchimokuOutput`, and the
  whole `// MARK: - Ranked Order Blocks [VP + Ichimoku]` renderer
  (`rankedOBMarks(visible:)`, `rankedIchimokuMarks`, `rankedVPMarks`,
  `rankedOBZoneMark`, `rankedOBLegend`, `robLegendRow`, `rob*` colors)
- `ChartViewiPad.swift`: same two properties + renderer section
- `Oscillators.swift`: branch's `rob*` config block and its
  `decodeIfPresent` lines (note `robUseVP`/`robVPLookback`/`robVPRows`
  are shared names — main already declares and decodes them, so only the
  branch's copies went)
- `Indicators.swift`: duplicate `case rankedOrderBlock` + its `title`,
  `color`, and `params` switch arms
- `IndicatorSettingsSheet.swift`, `DashboardViewiPad.swift`: the
  "Ranked OB · VP+Ichimoku" settings sections
- `DashboardView.swift`: duplicate `case .rankedOrderBlock` preset parser

## Gotcha worth remembering

A same-named type added independently on two branches produces an
add/add conflict on **that file only** — every *call site* auto-merges
into a union of both sides. The build breaks in files git reported as
clean. After any such merge, grep for duplicate declarations rather than
trusting the conflict list.

## Verification

- `xcodegen generate` → OK
- macOS `HelixTradingApp` build → **BUILD SUCCEEDED**
- iPad `HelixTradingAppiPad` build → **BUILD SUCCEEDED**
- `xcodebuild test` → **51 tests, 0 failures**
