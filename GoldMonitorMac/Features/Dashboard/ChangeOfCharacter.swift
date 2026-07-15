import Foundation

/// Change of Character (CHoCH) + Order-Block / Fair-Value-Gap confluence.
///
/// A Smart-Money-Concepts detector. Market structure is read from swing
/// pivots (reusing the `ZigZag` engine): an uptrend prints higher highs +
/// higher lows, a downtrend lower highs + lower lows. A **Change of
/// Character** is the first *close against the prevailing trend* that
/// breaks the last protected swing:
///   • Bullish CHoCH — while in a downtrend, price closes *above* the last
///     swing high (a lower high). The down-leg's character has changed.
///   • Bearish CHoCH — while in an uptrend, price closes *below* the last
///     swing low (a higher low). The up-leg's character has changed.
///
/// Plain continuation breaks (a bullish break while already bullish, i.e.
/// a Break of Structure) are deliberately ignored — this indicator only
/// surfaces trend *reversals*, which is what the user watches for.
///
/// When a CHoCH fires, the impulse leg that caused the break usually
/// leaves behind an **order block** (the last opposite-colour candle
/// before the impulse) and often a **fair-value gap** (a 3-candle
/// imbalance). Their overlap is the high-probability re-entry area. This
/// detector emits that zone: the OB range, tightened to the OB∩FVG
/// intersection when an FVG is present (`hasFVG == true`, high conviction),
/// or the raw OB alone as a lower-conviction fallback.
///
/// Pure-function, no state — `ChartView` / `ChartViewiPad` map the result
/// into `RectangleMark`s, mirroring how `OrderBlocks` / `FairValueGap`
/// overlays are rendered.
enum ChangeOfCharacter {

    /// Lifecycle of a zone after the CHoCH that formed it.
    enum Status: String, Codable, Hashable {
        /// Untouched since it formed.
        case fresh
        /// Price has traded back into the zone at least once.
        case tested
        /// Price has closed clean through the far side — the zone is spent.
        case mitigated
    }

    /// One CHoCH confluence zone.
    struct Zone: Identifiable, Hashable {
        /// Bar index of the order-block candle — the rectangle's left edge.
        let obIndex: Int
        /// Bar index of the candle whose close broke structure (the CHoCH
        /// event). Anchors the "CHoCH" label and the dashed level line.
        let chochIndex: Int
        /// The swing level that was broken — drawn as a dashed rule from
        /// the broken pivot across to the break bar.
        let brokenLevel: Double
        /// Upper boundary of the confluence zone.
        let high: Double
        /// Lower boundary of the confluence zone.
        let low: Double
        /// Bullish (demand) zone vs bearish (supply) zone.
        let isBullish: Bool
        /// True when an FVG overlapped the order block — the zone was
        /// tightened to the overlap and is high-conviction.
        let hasFVG: Bool
        let status: Status
        let testCount: Int

        // ── Constituent SMC elements of the breaking impulse ──────────
        // These let the chart draw the raw order block / fair-value gap /
        // inverse-FVG separately from the tightened confluence zone, each
        // behind its own visibility toggle.

        /// Raw order-block candle range (lower / upper), before any FVG
        /// tightening.
        let obLow: Double
        let obHigh: Double
        /// Same-direction fair-value gap inside the impulse, if one exists
        /// (nil otherwise). `fvgIndex` is the gap's middle-candle bar (its
        /// left edge).
        let fvgLow: Double?
        let fvgHigh: Double?
        let fvgIndex: Int?
        /// Inverse fair-value gap — an *opposite*-direction gap the CHoCH
        /// impulse traded back through, flipping it into support/resistance
        /// for the new direction (a classic ICT change-of-character tell).
        let ifvgLow: Double?
        let ifvgHigh: Double?
        let ifvgIndex: Int?

        var id: String { "\(chochIndex)-\(isBullish ? "bull" : "bear")" }
        var mid: Double { (high + low) / 2 }
    }

    /// A CHoCH zone re-anchored from bar indices to wall-clock dates.
    ///
    /// `Zone` stores positions as integer bar indices into the candle
    /// array it was computed from. To draw a *higher*-timeframe zone on a
    /// *lower*-timeframe chart (whose X axis is that lower timeframe's bar
    /// index) those indices are meaningless — bar 40 on 1H ≠ bar 40 on 5m.
    /// So we swap each index for its candle's `bucketStart`; the chart then
    /// maps every date back to its nearest lower-timeframe bar via
    /// `barIndex(forDate:)`. Price levels are timeframe-independent and
    /// carry over unchanged.
    struct DatedZone: Identifiable, Hashable {
        let obDate: Date
        let chochDate: Date
        let brokenLevel: Double
        let isBullish: Bool
        let hasFVG: Bool
        let status: Status
        let obLow: Double
        let obHigh: Double
        /// Union bounding box of every drawable element (for Y-domain fold).
        let high: Double
        let low: Double
        let fvgLow: Double?
        let fvgHigh: Double?
        let fvgDate: Date?
        let ifvgLow: Double?
        let ifvgHigh: Double?
        let ifvgDate: Date?

        var id: String { "\(Int(chochDate.timeIntervalSince1970))-\(isBullish ? "bull" : "bear")" }
    }

    /// Compute CHoCH zones on `candles` (intended: a higher timeframe than
    /// the chart currently shows) and re-anchor the last `maxZones` to
    /// dates so they can be projected onto a lower-timeframe axis.
    static func datedZones(
        _ candles: [Candle],
        swingLength: Int = 5,
        minSwingPct: Double = 0.2,
        requireFVG: Bool = false,
        showMitigated: Bool = false,
        maxZones: Int = 3
    ) -> [DatedZone] {
        let zones = compute(
            candles,
            swingLength: swingLength,
            minSwingPct: minSwingPct,
            requireFVG: requireFVG,
            showMitigated: showMitigated,
            maxZones: maxZones
        )
        func date(_ i: Int) -> Date? {
            candles.indices.contains(i) ? candles[i].bucketStart : nil
        }
        return zones.compactMap { z in
            guard let ob = date(z.obIndex), let choch = date(z.chochIndex) else { return nil }
            return DatedZone(
                obDate: ob,
                chochDate: choch,
                brokenLevel: z.brokenLevel,
                isBullish: z.isBullish,
                hasFVG: z.hasFVG,
                status: z.status,
                obLow: z.obLow,
                obHigh: z.obHigh,
                high: z.high,
                low: z.low,
                fvgLow: z.fvgLow,
                fvgHigh: z.fvgHigh,
                fvgDate: z.fvgIndex.flatMap(date),
                ifvgLow: z.ifvgLow,
                ifvgHigh: z.ifvgHigh,
                ifvgDate: z.ifvgIndex.flatMap(date)
            )
        }
    }

    /// Scan `candles` for CHoCH confluence zones.
    ///
    /// - swingLength:  pivot depth handed to `ZigZag` — bars of separation
    ///                 required around a swing. Higher ⇒ fewer, more
    ///                 significant structure points.
    /// - minSwingPct:  minimum % move between consecutive pivots (ZigZag
    ///                 noise filter).
    /// - requireFVG:   when true, only emit zones where an FVG overlaps the
    ///                 order block (strict confluence). When false, emit the
    ///                 order block alone as a fallback (`hasFVG == false`).
    /// - showMitigated: keep zones price has already closed through.
    /// - maxZones:     cap on the most-recent zones kept (older CHoCHs have
    ///                 usually played out; piling them up is just noise).
    static func compute(
        _ candles: [Candle],
        swingLength: Int = 5,
        minSwingPct: Double = 0.2,
        requireFVG: Bool = false,
        showMitigated: Bool = false,
        maxZones: Int = 8
    ) -> [Zone] {
        let n = candles.count
        guard n >= swingLength * 2 + 3 else { return [] }

        // ── Structure via swing pivots ─────────────────────────────────
        let pivots = ZigZag.compute(candles, depth: swingLength, minChangePct: minSwingPct)
        guard pivots.count >= 2 else { return [] }
        // A pivot at bar b is only *confirmed* (usable as a break level)
        // once `swingLength` further bars have printed — mirror the
        // lookahead ZigZag itself uses so we never "know" a level before
        // it could actually exist.
        let ordered = pivots.sorted { $0.barIndex < $1.barIndex }

        // ── Walk candles, tracking the trend + the levels to break ──────
        struct RawEvent {
            let chochIndex: Int
            let legStart: Int      // opposite pivot that began the impulse
            let brokenLevel: Double
            let brokenPivotBar: Int
            let isBullish: Bool
        }
        var events: [RawEvent] = []

        var trend = 0                                   // +1 up, -1 down, 0 unknown
        var activeHigh: (bar: Int, price: Double)? = nil // resistance to break
        var activeLow:  (bar: Int, price: Double)? = nil // support to break
        var pi = 0

        for j in 0..<n {
            // Activate every pivot confirmed by bar j.
            while pi < ordered.count && ordered[pi].barIndex + swingLength <= j {
                let p = ordered[pi]; pi += 1
                if p.isHigh { activeHigh = (p.barIndex, p.price) }
                else        { activeLow  = (p.barIndex, p.price) }
            }

            let close = candles[j].close

            if let ah = activeHigh, close > ah.price {
                // Break above the last swing high. A CHoCH only if we were
                // in a downtrend (breaking up against it); otherwise BOS.
                if trend == -1 {
                    let legStart = activeLow?.bar ?? ah.bar
                    events.append(RawEvent(
                        chochIndex: j, legStart: legStart,
                        brokenLevel: ah.price, brokenPivotBar: ah.bar,
                        isBullish: true
                    ))
                }
                trend = 1
                activeHigh = nil    // consume the level until the next pivot high confirms
            } else if let al = activeLow, close < al.price {
                if trend == 1 {
                    let legStart = activeHigh?.bar ?? al.bar
                    events.append(RawEvent(
                        chochIndex: j, legStart: legStart,
                        brokenLevel: al.price, brokenPivotBar: al.bar,
                        isBullish: false
                    ))
                }
                trend = -1
                activeLow = nil
            }
        }

        guard !events.isEmpty else { return [] }

        // ── Resolve OB + FVG confluence for each CHoCH ──────────────────
        var zones: [Zone] = []
        for ev in events {
            let legStart = max(0, min(ev.legStart, ev.chochIndex))
            let breakBar = ev.chochIndex

            // Order block = last opposite-colour candle before the impulse.
            // Bullish CHoCH ⇒ up impulse ⇒ OB is the last DOWN candle.
            var obIdx = breakBar
            if ev.isBullish {
                while obIdx > legStart && candles[obIdx].close >= candles[obIdx].open { obIdx -= 1 }
            } else {
                while obIdx > legStart && candles[obIdx].close <= candles[obIdx].open { obIdx -= 1 }
            }
            let obHigh = candles[obIdx].high
            let obLow  = candles[obIdx].low

            // ── Scan the impulse leg for fair-value gaps ────────────────
            // Same-direction gaps confirm displacement (the "FVG"); an
            // *opposite*-direction gap that the impulse closed back through
            // has inverted into support/resistance for the new trend (the
            // "iFVG"). Collect both; prefer the same-direction gap that
            // overlaps the order block for the confluence tightening.
            struct Gap { let low: Double; let high: Double; let index: Int }
            var sameDir: [Gap] = []
            var inverted: [Gap] = []
            let fvgFrom = max(legStart, 2)
            if fvgFrom <= breakBar {
                for i in fvgFrom...breakBar {
                    let c0 = candles[i], c1 = candles[i - 1], c2 = candles[i - 2]
                    // Bullish 3-bar gap: [c2.high, c0.low].
                    if c0.low > c2.high, c1.close > c2.high {
                        let g = Gap(low: c2.high, high: c0.low, index: i - 1)
                        if ev.isBullish {
                            sameDir.append(g)
                        } else if (i...breakBar).contains(where: { candles[$0].close < c2.high }) {
                            // A bullish gap the bearish impulse closed under ⇒ inverted.
                            inverted.append(g)
                        }
                    }
                    // Bearish 3-bar gap: [c0.high, c2.low].
                    else if c0.high < c2.low, c1.close < c2.low {
                        let g = Gap(low: c0.high, high: c2.low, index: i - 1)
                        if !ev.isBullish {
                            sameDir.append(g)
                        } else if (i...breakBar).contains(where: { candles[$0].close > c2.low }) {
                            // A bearish gap the bullish impulse closed over ⇒ inverted.
                            inverted.append(g)
                        }
                    }
                }
            }

            // Same-direction FVG for display: prefer one overlapping the OB
            // (that's the confluence), else the most recent one.
            let overlapping = sameDir.first { $0.high >= obLow && $0.low <= obHigh }
            let fvg = overlapping ?? sameDir.last
            let ifvg = inverted.last
            let hasFVG = overlapping != nil

            // Confluence zone (for lifecycle + requireFVG gate): OB tightened
            // to the OB∩FVG overlap when they coincide, else the raw OB.
            var zoneHigh = obHigh
            var zoneLow  = obLow
            if let o = overlapping {
                let iLow = max(obLow, o.low), iHigh = min(obHigh, o.high)
                if iHigh > iLow { zoneLow = iLow; zoneHigh = iHigh }
            } else if requireFVG {
                continue    // strict mode: no confluence ⇒ drop
            }
            guard zoneHigh > zoneLow else { continue }

            // ── Lifecycle: has price returned to / closed through the zone? ──
            var status: Status = .fresh
            var testCount = 0
            if breakBar + 1 < n {
                for ci in (breakBar + 1)..<n {
                    let c = candles[ci]
                    if c.low <= zoneHigh && c.high >= zoneLow {
                        testCount += 1
                        if status == .fresh { status = .tested }
                    }
                    if ev.isBullish {
                        if c.close < zoneLow { status = .mitigated; break }
                    } else {
                        if c.close > zoneHigh { status = .mitigated; break }
                    }
                }
            }

            // Bounding box for the auto-Y-domain fold: the union of every
            // element we might draw (OB + FVG + iFVG).
            var boundLow = min(zoneLow, obLow)
            var boundHigh = max(zoneHigh, obHigh)
            for g in [fvg, ifvg].compactMap({ $0 }) {
                boundLow = min(boundLow, g.low)
                boundHigh = max(boundHigh, g.high)
            }

            zones.append(Zone(
                obIndex: obIdx,
                chochIndex: breakBar,
                brokenLevel: ev.brokenLevel,
                high: boundHigh,
                low: boundLow,
                isBullish: ev.isBullish,
                hasFVG: hasFVG,
                status: status,
                testCount: testCount,
                obLow: obLow,
                obHigh: obHigh,
                fvgLow: fvg?.low,
                fvgHigh: fvg?.high,
                fvgIndex: fvg?.index,
                ifvgLow: ifvg?.low,
                ifvgHigh: ifvg?.high,
                ifvgIndex: ifvg?.index
            ))
        }

        let filtered = showMitigated ? zones : zones.filter { $0.status != .mitigated }
        return Array(filtered.suffix(maxZones))
    }
}
