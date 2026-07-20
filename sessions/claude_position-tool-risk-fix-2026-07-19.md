# Risk-calculator 10× fix + on-chart position tool — 2026-07-19

Follows the `origin/add-order-block-indicators` merge earlier the same
day (see [claude_merge-order-block-indicators-2026-07-19.md](claude_merge-order-block-indicators-2026-07-19.md)).

## 1. Risk Calculator was 10× oversized on gold

**Reported:** entry 4035, stop 4045, 1% risk → app said 0.1 lot ($10
loss). Correct answer is 0.01 lot; 0.1 lot loses $100.

**Cause — a unit mismatch in `RiskCalculatorView`:**

- `pipDistance` was `abs(entry - stop)` = **10.00**, a raw *price*
  difference in dollars.
- The constant was `dollarPerPointPerLot = 10.0`, which is the broker
  "$10 per point" convention where a **point is $0.10** of price.

Multiplying a dollar-denominated distance by a per-10-cent rate is a
silent 10× error. A 10-dollar stop was priced as if it were 10 points.

**Fix:** 1 standard XAUUSD lot = 100 oz ⇒ a $1.00 move is **$100/lot**.
Renamed `pipDistance` → `stopDistance` and the constant →
`dollarPerPricePerLot` so the two conventions can't be conflated again.

Knock-on changes the fix forced:

- Lot display `%.2f` → `%.3f` (mini lots `%.1f` → `%.2f`). Every size is
  now 10× smaller, so small positions would have rounded to `0.00`.
- Stop Distance label `"%.2f pts"` → `"$%.2f"` — that field showed
  dollars while labelled points, which is the same confusion that
  produced the bug.

## 2. TradingView-style position tool (Mac + iPad)

New long/short position boxes: drag to place, drag handles to move
entry / SL / TP / time extent, per-position balance + risk %, live lot
size and P/L on the chart.

### New shared model

- `Models/ContractSpec.swift` — per-instrument contract size, unit
  label, min lot. `valuePerPricePerLot` collapses to the contract size
  because every catalog instrument is USD-quoted. **The specs are
  broker-dependent defaults** (indices and DXY vary wildly between
  brokers); `forPair(id:)` is the single place to correct them.
- `PositionMetrics.compute(...)` — lots, risk, reward, R:R, and a
  `belowMinLot` flag. Returns `nil` for degenerate input (zero stop
  distance, zero balance/risk) rather than emitting NaN/∞ onto the
  chart.
- `RiskCalculatorView` now goes through `ContractSpec.forPair(id:
  "ounce")`, so the gold math has exactly one source of truth.

### Model changes (`Drawings.swift`)

- `Kind.longPosition` / `.shortPosition` + `isPosition` / `isLong`.
- New optional fields `stopPrice`, `targetPrice`, `accountBalance`,
  `riskPercent`, all `decodeIfPresent` so pre-existing drawings load.
- New `Handle` cases `.entry`, `.stop`, `.target`, `.timeEnd`.
  `.entry` moves price+time, stop/target are price-only, `.timeEnd` is
  time-only (keeps the box level).
- `ChartDrawing.position(long:...)` builds a position with the drag
  height as the stop distance and the target at 2R.
- For a position, `start` = (left edge, entry) and `end` = (right edge,
  entry) — the vertical extent comes from stop/target, since a position
  needs three levels, not two corners.

### Gotchas hit

- **Adding `Handle` cases silently broke the rectangle/volumeProfile
  resize switches** (they had no `default`). Compiler caught it.
- **`handleAnchors` and `handlePositions` are zipped positionally.**
  Position handles are conditional (no stop ⇒ no stop handle), so the
  anchor list has to be conditional in exactly the same way, or the
  target handle maps onto `.stop`. Both charts.
- **`translated()` rebuilt drawings from scratch**, dropping `color` and
  `lineWidth` — a pre-existing bug that reset a drawing's colour on
  every drag, and would have wiped a position's stop/target entirely.
  Now mutates a copy. A position's stop/target are absolute prices, so
  they translate with the entry.
- **iPad had the drag-edit *state* (`editingDrawingID`,
  `movingDrawingOriginal`) but none of the machinery** — no
  hit-testing, no handle positions, nothing set those vars. Drawings
  were effectively immutable there. Added `hitTestDrawing`,
  `hitTestHandle`, `handlePositions`, `handleAnchors`,
  `handleResizeEnd`, `handleMoveEnd`, `selectionHandleMarks`, plus
  gesture routing ahead of the pan branch. Touch thresholds are larger
  than the Mac's (22pt handles vs 10pt, 16pt bodies vs 8pt).
- `ChartView` is deliberately pair-agnostic, so `contractSpec` is passed
  in from the dashboard rather than looked up from a pair id.
- `Theme.Color` has `warn`, not `warning`.

## Verification

- macOS build ✅ · iPad build ✅
- `xcodebuild test` → **64 tests, 0 failures** (13 new in
  `PositionSizingTests.swift`, incl. the exact reported case and a
  cross-instrument invariant that stop-out loss == risk budget)
- **Ran the app and drew a live long position on the gold chart**:
  green reward zone, red risk zone, dashed entry, four white handles,
  label `LONG 0.007 lots  −$10 +$20 2.00R  below min lot`, inspector
  showing the Long badge with editable balance/risk. Test drawing was
  deleted afterwards.

### Verification gotcha worth remembering

The first screenshot showed the *old* tool menu because `open -a
HelixTradingApp` launched `/Applications/HelixTradingApp.app`, not the
build output. `build/Build/Products/` is also stale — the real output is
under `~/Library/Developer/Xcode/DerivedData/HelixTradingApp-*/Build/
Products/Debug/`, and the app code lives in
`Contents/MacOS/HelixTradingApp.debug.dylib` (the main binary is a 58KB
stub, so `strings` on it finds nothing). Launch by full DerivedData path
when verifying changes.

## Not done

- Contract specs for indices/DXY are best-guess defaults and are not
  user-editable. If sizing looks wrong on US30 or DXY, that table is
  the place to look.
- Nothing pushed — `git fetch`/`push` still fails on SSH publickey.
