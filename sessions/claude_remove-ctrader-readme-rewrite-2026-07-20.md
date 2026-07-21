# Remove cTrader bridge + README rewrite — 2026-07-20

## cTrader removal (commit 9b4112d)

Deleted end to end: `CTraderBridge/` (cBot + README), `CTraderScheduler`,
`CTraderWSReceiver`, `CTraderBridgeCard`, the Settings `ctrader`
category, the wizard's cTrader step (wizard is 4 steps now:
welcome/claude/dataSources/done — `Step` raw values renumbered), boot
wiring in both `HelixTradingApp.swift` and `HelixTradingAppiPad.swift`,
`YahooScheduler.attachCTraderProvider` + the ounce tick-suppression gate,
and both `project.yml` resource entries bundling `HelixBridgeBot.cs`.

**Auto-trader is now paper-only.** The live path had no transport without
the bridge, so: `isPaper: true` always, live-order branch deleted,
`handleOrderStatus`/`handleStateSnapshot` deleted, Paper/LIVE mode chips
replaced with a static Paper indicator, v1 "live is ounce-only" banner
replaced with a paper-only note. `Trade.liveOrderID`/close-reason fields
and `TradeStore.applyLiveOrderStatus` were KEPT so previously persisted
live trades still decode.

**Deliberately kept:** the Journal's cTrader CSV *statement import*
(`importCTraderCSV`/`parseCTraderCSV` in JournalView, JournalStore
comments). It's standalone file parsing — no bridge dependency — and the
user only asked for the bridge. AGENTS.md's one remaining "cTrader"
mention is this import.

`YahooScheduler.applyExternalTick` was kept (generic external-tick entry
point, now unused by anything in-tree but harmless and useful).

## README rewrite (same commit)

Full rewrite oriented around understanding the product: screen table
(Dashboard/News/Portfolio/Journal/Inbox/Settings), chart + position tool
detail, **every indicator grouped and explained** (classic /
smart-money / strategy overlays), AI features, alerts, architecture
diagram (bridge box removed), build/run, layout, contributing. AGENTS.md
lost its whole "cTrader bridge" section + wiring refs; CLAUDE.md pointer
updated.

## Verification

- macOS build + **64 tests pass**; iPad build succeeds.
- The Vercel plugin hook fired again on the README write (pattern-matches
  `README*` and demanded its bootstrap skill); ignored — no web stack in
  this repo.

## State

Local `main` is 8 commits ahead of origin; push still blocked on SSH
publickey. The 1.5 DMG in dist/ was built BEFORE this removal — if 1.5
should ship without the bridge, rebuild it (`./run.sh --dmg`) and
regenerate the release notes.
