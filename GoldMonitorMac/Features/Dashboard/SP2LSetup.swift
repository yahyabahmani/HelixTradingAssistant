import Foundation

/// SP2L (Spike-2Leg) setup detector.
///
/// A valid setup starts from balance, breaks out with pressure (P-Gap),
/// then waits for the first pullback level to be tested. Entry is confirmed
/// only when a directional rejection candle closes back beyond that level.
enum SP2LSetup {
    enum Direction: String, Hashable {
        case long
        case short
    }

    enum Stage: String, Hashable {
        case limitPending
        case entered
        case hitTP
        case hitSL
        case invalidated
        case expired
    }

    struct Result: Identifiable, Hashable {
        let spikeStartIndex: Int
        let spikeEndIndex: Int
        let breakoutIndex: Int
        let followThroughIndex: Int
        let spikeHigh: Double
        let spikeLow: Double
        let brokenLevel: Double
        let levelStartIndex: Int
        let gapStartIndex: Int
        let gapEndIndex: Int
        let gapLow: Double
        let gapHigh: Double
        let direction: Direction

        var pullbackIndex: Int?
        var entryIndex: Int?
        var resolveIndex: Int?
        var stage: Stage

        let entry: Double
        let stopLoss: Double
        let takeProfit: Double
        let emaValue: Double?

        var id: String {
            "\(spikeStartIndex)-\(spikeEndIndex)-\(direction.rawValue)"
        }

        var hasPlan: Bool { true }

        func takeProfits(count rawCount: Int) -> [Double] {
            let count = min(3, max(1, rawCount))
            let firstTargetDistance = abs(takeProfit - entry)
            guard firstTargetDistance > 0 else { return [takeProfit] }
            return (1...count).map { targetNumber in
                let distance = firstTargetDistance * Double(targetNumber)
                return direction == .long ? entry + distance : entry - distance
            }
        }
    }

    static func compute(
        _ candles: [Candle],
        minSpikeBars rawMinSpikeBars: Int = 2,
        maxSpikeBars rawMaxSpikeBars: Int = 6,
        rangeBars rawRangeBars: Int = 4,
        atrPeriod rawATRPeriod: Int = 14,
        minSpikeATR: Double = 1.0,
        maxSpikeATR: Double = 10.0,
        maxRangeATR: Double = 1.5,
        minGapPct: Double = 0,
        maxPressureGapBar rawMaxPressureGapBar: Int = 6,
        emaPeriod rawEMAPeriod: Int = 60,
        useEMAContext: Bool = true,
        maxEMADistanceATR: Double = 1.0,
        maxPullbackBars rawMaxPullbackBars: Int = 6,
        maxContinuationBars rawMaxContinuationBars: Int = 10,
        riskReward: Double = 1.0,
        targetCount rawTargetCount: Int = 1,
        maxResults: Int = 12
    ) -> [Result] {
        let minSpikeBars = max(2, rawMinSpikeBars)
        let maxSpikeBars = max(minSpikeBars, rawMaxSpikeBars)
        let rangeBars = max(2, rawRangeBars)
        let atrPeriod = max(1, rawATRPeriod)
        let emaPeriod = max(2, rawEMAPeriod)
        let maxPullbackBars = max(1, rawMaxPullbackBars)
        let maxContinuationBars = max(1, rawMaxContinuationBars)
        let targetCount = min(3, max(1, rawTargetCount))
        let contextPeriod = useEMAContext ? max(atrPeriod, emaPeriod) : atrPeriod
        let minimumCount = max(rangeBars + minSpikeBars, contextPeriod + 2)
        guard candles.count >= minimumCount else { return [] }
        let atr = atrSeries(candles, period: atrPeriod)
        let ema = emaSeries(candles, period: emaPeriod)
        var out: [Result] = []
        var start = rangeBars

        while start + minSpikeBars - 1 < candles.count {
            var accepted: Result?
            let largestEnd = min(candles.count - 1, start + maxSpikeBars - 1)

            // Use the last clean candle before the first pullback so the
            // limit sits at the actual final spike low/high. The P-Gap is
            // still required near the start, preventing an E-Gap match.
            for end in stride(from: largestEnd, through: start + minSpikeBars - 1, by: -1) {
                if let result = detectSpikeWindow(
                    candles,
                    atr: atr,
                    ema: ema,
                    start: start,
                    end: end,
                    rangeBars: rangeBars,
                    minSpikeATR: max(0, minSpikeATR),
                    maxSpikeATR: max(maxSpikeATR, minSpikeATR),
                    maxRangeATR: max(0.1, maxRangeATR),
                    minGapPct: max(0, minGapPct),
                    maxPressureGapBar: max(2, rawMaxPressureGapBar),
                    useEMAContext: useEMAContext,
                    maxEMADistanceATR: max(0, maxEMADistanceATR),
                    maxPullbackBars: maxPullbackBars,
                    maxContinuationBars: maxContinuationBars,
                    riskReward: max(0.1, riskReward),
                    targetCount: targetCount
                ) {
                    accepted = result
                    break
                }
            }

            if let result = accepted {
                out.append(result)
                let consumed = result.resolveIndex
                    ?? result.entryIndex
                    ?? result.spikeEndIndex
                start = max(consumed + 1, result.spikeEndIndex + 1)
            } else {
                start += 1
            }
        }

        return Array(out.suffix(maxResults))
    }

    private static func detectSpikeWindow(
        _ candles: [Candle],
        atr: [Double?],
        ema: [Double?],
        start: Int,
        end: Int,
        rangeBars: Int,
        minSpikeATR: Double,
        maxSpikeATR: Double,
        maxRangeATR _: Double,
        minGapPct: Double,
        maxPressureGapBar: Int,
        useEMAContext: Bool,
        maxEMADistanceATR: Double,
        maxPullbackBars: Int,
        maxContinuationBars: Int,
        riskReward: Double,
        targetCount: Int
    ) -> Result? {
        guard start >= rangeBars,
              end < candles.count,
              let currentATR = atr[end],
              currentATR > 0
        else { return nil }

        let balance = candles[(start - rangeBars)..<start]
        let balanceHigh = balance.map(\.high).max() ?? candles[start - 1].high
        let balanceLow = balance.map(\.low).min() ?? candles[start - 1].low
        let referenceATR = atr[start - 1] ?? currentATR
        guard referenceATR > 0 else { return nil }
        let levelLookback = max(rangeBars, min(24, max(8, rangeBars * 3)))
        let levelStartIndex = max(0, start - levelLookback)

        let direction = directionalStructure(
            candles,
            start: start,
            end: end,
            tolerance: referenceATR * 0.10
        )
        guard let direction else { return nil }

        let brokenLevel = direction == .long ? balanceHigh : balanceLow

        guard let breakout = pressureAndFollowThrough(
            candles,
            start: start,
            end: end,
            direction: direction,
            minimumBody: referenceATR * 0.50
        ) else { return nil }

        // A rolling scan can begin one quiet candle before the displacement,
        // but must not absorb several balance candles into the spike. Anchor
        // the setup to the actual pressure breakout and require the selected
        // end candle to still point with the move; the first opposite candle
        // is the pullback, not part of the spike.
        guard breakout.breakout - start <= 1 else { return nil }
        let spikeStart = breakout.breakout
        switch direction {
        case .long where candles[end].close <= candles[end].open: return nil
        case .short where candles[end].close >= candles[end].open: return nil
        default: break
        }

        // Once the pressure leg starts, its first opposite candle is the
        // pullback. Never absorb a later confirmation candle into the spike
        // across that pullback.
        let hasOppositeCandle = candles[spikeStart...end].contains { candle in
            switch direction {
            case .long: return candle.close < candle.open
            case .short: return candle.close > candle.open
            }
        }
        guard !hasOppositeCandle else { return nil }

        let spikeSlice = candles[spikeStart...end]
        let spikeHigh = spikeSlice.map(\.high).max() ?? candles[end].high
        let spikeLow = spikeSlice.map(\.low).min() ?? candles[end].low
        let spikeMove = direction == .long
            ? candles[end].close - candles[spikeStart].open
            : candles[spikeStart].open - candles[end].close
        guard spikeMove >= minSpikeATR * referenceATR,
              spikeMove <= maxSpikeATR * referenceATR
        else { return nil }

        guard let gap = firstPressureGap(
            candles,
            range: (spikeStart - 1)...end,
            direction: direction,
            minGapPct: minGapPct,
            maxPressureGapBar: maxPressureGapBar,
            minimumGap: referenceATR * 0.04
        ) else { return nil }

        let contextEMA = ema[spikeStart]
        if useEMAContext {
            guard let contextEMA else { return nil }
            let distance = abs(candles[spikeStart].open - contextEMA)
            guard distance <= maxEMADistanceATR * currentATR else { return nil }
            switch direction {
            case .long where candles[end].close <= contextEMA: return nil
            case .short where candles[end].close >= contextEMA: return nil
            default: break
            }
        }

        // A touch of the first-pullback level is only a setup. Entry needs a
        // directional rejection close before the spike origin/SL is lost.
        let pullbackLevel = direction == .long ? candles[end].low : candles[end].high
        let stop = direction == .long ? spikeLow : spikeHigh
        let pullbackOutcome = firstConfirmedPullback(
            candles,
            after: end,
            maxBars: maxPullbackBars,
            level: pullbackLevel,
            stop: stop,
            direction: direction,
            tolerance: referenceATR * 0.10
        )
        let entry: Double
        switch pullbackOutcome {
        case .confirmed(_, let confirmationIndex):
            entry = candles[confirmationIndex].close
        case .waiting, .invalidated, .expired:
            entry = pullbackLevel
        }
        let risk = abs(entry - stop)
        guard risk > 0 else { return nil }

        let takeProfit = direction == .long
            ? entry + risk * riskReward
            : entry - risk * riskReward
        var result = Result(
            spikeStartIndex: spikeStart,
            spikeEndIndex: end,
            breakoutIndex: breakout.breakout,
            followThroughIndex: breakout.followThrough,
            spikeHigh: spikeHigh,
            spikeLow: spikeLow,
            brokenLevel: brokenLevel,
            levelStartIndex: levelStartIndex,
            gapStartIndex: gap.start,
            gapEndIndex: gap.end,
            gapLow: gap.low,
            gapHigh: gap.high,
            direction: direction,
            stage: .limitPending,
            entry: entry,
            stopLoss: stop,
            takeProfit: takeProfit,
            emaValue: contextEMA
        )

        switch pullbackOutcome {
        case .waiting:
            break
        case .expired(let index):
            result.resolveIndex = index
            result.stage = .expired
        case .invalidated(let index):
            result.resolveIndex = index
            result.stage = .invalidated
        case .confirmed(let touchIndex, let confirmationIndex):
            result.pullbackIndex = touchIndex
            result.entryIndex = confirmationIndex
            result.stage = .entered
            resolve(
                &result,
                candles: candles,
                // Entry happens at the confirmation close; its earlier wick
                // cannot stop a trade that was not open at that time.
                from: confirmationIndex + 1,
                maxContinuationBars: maxContinuationBars,
                targetCount: targetCount
            )
        }
        return result
    }

    private static func directionalStructure(
        _ candles: [Candle],
        start: Int,
        end: Int,
        tolerance: Double
    ) -> Direction? {
        guard end > start else { return nil }
        var higherLows = 0
        var lowerHighs = 0
        var bullishCloses = 0
        var bearishCloses = 0

        for i in start...end {
            if candles[i].close > candles[i].open { bullishCloses += 1 }
            if candles[i].close < candles[i].open { bearishCloses += 1 }
            guard i > start else { continue }
            if candles[i].low >= candles[i - 1].low - tolerance { higherLows += 1 }
            if candles[i].high <= candles[i - 1].high + tolerance { lowerHighs += 1 }
        }

        let transitions = end - start
        let requiredTransitions = max(1, Int(ceil(Double(transitions) * 0.67)))
        let requiredDirectionalCloses = max(1, Int(ceil(Double(end - start + 1) * 0.60)))
        if higherLows >= requiredTransitions,
           bullishCloses >= requiredDirectionalCloses,
           bullishCloses >= bearishCloses,
           candles[end].close > candles[start].open {
            return .long
        }
        if lowerHighs >= requiredTransitions,
           bearishCloses >= requiredDirectionalCloses,
           bearishCloses >= bullishCloses,
           candles[end].close < candles[start].open {
            return .short
        }
        return nil
    }

    private struct Breakout {
        let breakout: Int
        let followThrough: Int
    }

    private static func pressureAndFollowThrough(
        _ candles: [Candle],
        start: Int,
        end: Int,
        direction: Direction,
        minimumBody: Double
    ) -> Breakout? {
        guard end > start else { return nil }
        for i in start..<end {
            let next = i + 1
            let candle = candles[i]
            let candleRange = candle.high - candle.low
            let body = abs(candle.close - candle.open)
            guard candleRange > 0,
                  body >= minimumBody,
                  body / candleRange >= 0.55
            else { continue }
            switch direction {
            case .long:
                if candle.close > candle.open,
                   candles[next].close > candles[i].close,
                   candles[next].close > candles[next].open {
                    return Breakout(breakout: i, followThrough: next)
                }
            case .short:
                if candle.close < candle.open,
                   candles[next].close < candles[i].close,
                   candles[next].close < candles[next].open {
                    return Breakout(breakout: i, followThrough: next)
                }
            }
        }
        return nil
    }

    private struct Gap {
        let start: Int
        let end: Int
        let low: Double
        let high: Double
    }

    private static func firstPressureGap(
        _ candles: [Candle],
        range: ClosedRange<Int>,
        direction: Direction,
        minGapPct: Double,
        maxPressureGapBar: Int,
        minimumGap: Double
    ) -> Gap? {
        guard range.count >= 3 else { return nil }
        // `range.lowerBound` is the last balance candle. A value of 3
        // therefore allows the P-Gap to finish on spike candle 1, 2 or 3.
        let latestGapEnd = min(range.upperBound, range.lowerBound + maxPressureGapBar)
        guard range.lowerBound + 2 <= latestGapEnd else { return nil }

        for i in (range.lowerBound + 2)...latestGapEnd {
            let current = candles[i]
            let middle = candles[i - 1]
            let first = candles[i - 2]
            switch direction {
            case .long:
                if current.low > first.high, middle.close > first.high {
                    let gapSize = current.low - first.high
                    let pct = first.high > 0 ? gapSize / first.high * 100 : 0
                    if gapSize >= minimumGap, pct >= minGapPct {
                        return Gap(start: i - 2, end: i, low: first.high, high: current.low)
                    }
                }
            case .short:
                if current.high < first.low, middle.close < first.low {
                    let gapSize = first.low - current.high
                    let pct = current.high > 0 ? gapSize / current.high * 100 : 0
                    if gapSize >= minimumGap, pct >= minGapPct {
                        return Gap(start: i - 2, end: i, low: current.high, high: first.low)
                    }
                }
            }
        }
        return nil
    }

    private enum PullbackOutcome {
        case waiting
        case confirmed(touch: Int, confirmation: Int)
        case invalidated(Int)
        case expired(Int)
    }

    private static func firstConfirmedPullback(
        _ candles: [Candle],
        after spikeEnd: Int,
        maxBars: Int,
        level: Double,
        stop: Double,
        direction: Direction,
        tolerance: Double
    ) -> PullbackOutcome {
        let lo = spikeEnd + 1
        let hi = min(candles.count - 1, spikeEnd + maxBars)
        guard lo <= hi else { return .waiting }
        var touchIndex: Int?
        for i in lo...hi {
            let candle = candles[i]
            switch direction {
            case .long:
                if candle.low <= stop { return .invalidated(i) }
                if touchIndex == nil, candle.low <= level + tolerance {
                    touchIndex = i
                }
                if let touchIndex,
                   candle.close > candle.open,
                   candle.close > level {
                    return .confirmed(touch: touchIndex, confirmation: i)
                }
            case .short:
                if candle.high >= stop { return .invalidated(i) }
                if touchIndex == nil, candle.high >= level - tolerance {
                    touchIndex = i
                }
                if let touchIndex,
                   candle.close < candle.open,
                   candle.close < level {
                    return .confirmed(touch: touchIndex, confirmation: i)
                }
            }
        }
        if candles.count - 1 >= spikeEnd + maxBars {
            return .expired(spikeEnd + maxBars)
        }
        return .waiting
    }

    private static func resolve(
        _ result: inout Result,
        candles: [Candle],
        from fill: Int,
        maxContinuationBars: Int,
        targetCount: Int
    ) {
        let finalTarget = result.takeProfits(count: targetCount).last ?? result.takeProfit
        let last = min(candles.count - 1, fill + maxContinuationBars)
        guard fill <= last else { return }
        for i in fill...last {
            switch result.direction {
            case .long:
                let hitSL = candles[i].low <= result.stopLoss
                let hitTP = candles[i].high >= finalTarget
                if hitSL || hitTP {
                    result.resolveIndex = i
                    // Conservative ordering when one candle spans both.
                    result.stage = hitSL ? .hitSL : .hitTP
                    return
                }
            case .short:
                let hitSL = candles[i].high >= result.stopLoss
                let hitTP = candles[i].low <= finalTarget
                if hitSL || hitTP {
                    result.resolveIndex = i
                    result.stage = hitSL ? .hitSL : .hitTP
                    return
                }
            }
        }

        if last < candles.count - 1 || last == fill + maxContinuationBars {
            result.resolveIndex = last
            result.stage = .expired
        }
    }

    private static func atrSeries(_ candles: [Candle], period: Int) -> [Double?] {
        guard !candles.isEmpty, period > 0 else { return [] }
        var trueRanges = [Double](repeating: 0, count: candles.count)
        for i in candles.indices {
            if i == 0 {
                trueRanges[i] = candles[i].high - candles[i].low
            } else {
                let previousClose = candles[i - 1].close
                trueRanges[i] = max(
                    candles[i].high - candles[i].low,
                    abs(candles[i].high - previousClose),
                    abs(candles[i].low - previousClose)
                )
            }
        }

        var output = [Double?](repeating: nil, count: candles.count)
        var sum = 0.0
        for i in trueRanges.indices {
            sum += trueRanges[i]
            if i >= period { sum -= trueRanges[i - period] }
            if i >= period - 1 { output[i] = sum / Double(period) }
        }
        return output
    }

    private static func emaSeries(_ candles: [Candle], period: Int) -> [Double?] {
        guard !candles.isEmpty, period > 1 else { return [] }
        var output = [Double?](repeating: nil, count: candles.count)
        guard candles.count >= period else { return output }
        let seed = candles.prefix(period).map(\.close).reduce(0, +) / Double(period)
        output[period - 1] = seed
        let multiplier = 2.0 / Double(period + 1)
        var previous = seed
        if period < candles.count {
            for i in period..<candles.count {
                previous = (candles[i].close - previous) * multiplier + previous
                output[i] = previous
            }
        }
        return output
    }
}
