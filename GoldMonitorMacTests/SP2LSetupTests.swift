import Foundation
import XCTest
@testable import HelixTradingApp

final class SP2LSetupTests: XCTestCase {
    func testLongTakeProfitsUseMultiplesOfFirstTargetDistance() {
        let result = makeResult(direction: .long, entry: 100, stopLoss: 99, takeProfit: 101)

        XCTAssertEqual(result.takeProfits(count: 3), [101, 102, 103])
    }

    func testShortTakeProfitsUseMultiplesOfFirstTargetDistance() {
        let result = makeResult(direction: .short, entry: 100, stopLoss: 101, takeProfit: 99)

        XCTAssertEqual(result.takeProfits(count: 3), [99, 98, 97])
    }

    func testTakeProfitCountIsClampedToSupportedRange() {
        let result = makeResult(direction: .long, entry: 100, stopLoss: 99, takeProfit: 101)

        XCTAssertEqual(result.takeProfits(count: 0), [101])
        XCTAssertEqual(result.takeProfits(count: 4), [101, 102, 103])
    }

    func testDetectsBullishSpikeBreakingRecentStructuralHigh() {
        var candles = balancedWarmup()
        candles += bullishSpike()

        let result = detect(candles).last

        XCTAssertEqual(result?.direction, .long)
        XCTAssertEqual(result?.brokenLevel ?? 0, 100.25, accuracy: 0.0001)
        XCTAssertEqual(result?.breakoutIndex, 16)
        XCTAssertEqual(result?.followThroughIndex, 17)
    }

    func testDetectsLocalBalanceBreakWithoutRequiringDistantStructuralHigh() {
        var candles = balancedWarmup()
        candles[7] = candle(100.0, 103.0, 99.75, 100.0)
        candles += bullishSpike()

        let result = detect(candles).last

        XCTAssertEqual(result?.direction, .long)
        XCTAssertEqual(result?.brokenLevel ?? 0, 100.25, accuracy: 0.0001)
    }

    func testDetectsExtendedBullishSpikeWithLatePressureGapAndRedPullback() {
        var candles = balancedWarmup()
        candles += [
            candle(100.0, 100.5, 99.9, 100.4),
            candle(100.4, 100.9, 100.2, 100.8),
            candle(100.8, 101.5, 100.45, 101.4),
            candle(101.4, 102.4, 101.3, 102.2),
            candle(102.2, 103.3, 102.1, 103.1),
            candle(103.1, 103.2, 101.8, 102.1),
            candle(102.0, 102.8, 101.9, 102.6),
        ]

        let results = SP2LSetup.compute(
            candles,
            minSpikeBars: 2,
            maxSpikeBars: 6,
            rangeBars: 4,
            atrPeriod: 4,
            minSpikeATR: 1.0,
            maxSpikeATR: 10.0,
            maxRangeATR: 1.5,
            minGapPct: 0,
            maxPressureGapBar: 6,
            useEMAContext: false,
            maxPullbackBars: 3,
            maxContinuationBars: 5
        )
        let result = results.last

        XCTAssertEqual(result?.direction, .long)
        XCTAssertEqual(result?.spikeStartIndex, 16)
        XCTAssertEqual(result?.spikeEndIndex, 20)
        XCTAssertEqual(result?.gapEndIndex, 19)
        XCTAssertEqual(result?.pullbackIndex, 21)
        XCTAssertEqual(result?.entryIndex, 22)
        XCTAssertEqual(result?.entry ?? 0, 102.6, accuracy: 0.0001)
        XCTAssertEqual(result?.stage, .entered)
    }

    func testDetectsJuly13OunceSpikeAndNearTouchPullback() {
        let candles = [
            candle(4066.800, 4067.490, 4066.605, 4066.820),
            candle(4066.875, 4066.960, 4065.845, 4066.265),
            candle(4066.395, 4067.595, 4066.395, 4067.090),
            candle(4067.080, 4067.285, 4066.590, 4067.050),
            candle(4067.075, 4067.805, 4066.090, 4067.805),
            candle(4067.755, 4068.340, 4066.805, 4067.055),
            candle(4067.025, 4067.460, 4066.395, 4066.760),
            candle(4066.750, 4066.985, 4064.720, 4065.390),
            candle(4065.355, 4065.725, 4052.770, 4052.770),
            candle(4052.735, 4055.080, 4046.430, 4054.675),
            candle(4054.300, 4055.830, 4053.400, 4054.070),
            candle(4054.050, 4054.265, 4051.230, 4052.220),
            candle(4051.975, 4053.875, 4051.585, 4053.170),
            candle(4053.145, 4053.175, 4050.630, 4050.820),
            candle(4050.835, 4051.600, 4048.070, 4051.540),
            candle(4051.430, 4052.820, 4049.885, 4052.125),
            candle(4052.080, 4054.545, 4051.745, 4054.435),
            candle(4054.290, 4055.235, 4051.745, 4055.145),
            candle(4055.230, 4057.040, 4054.790, 4056.970),
            candle(4057.055, 4057.335, 4055.030, 4056.650),
            candle(4056.705, 4057.765, 4056.515, 4057.055),
        ]

        let result = SP2LSetup.compute(
            candles,
            minSpikeBars: 2,
            maxSpikeBars: 6,
            rangeBars: 4,
            atrPeriod: 14,
            minSpikeATR: 1.0,
            maxSpikeATR: 10.0,
            maxRangeATR: 1.4,
            minGapPct: 0,
            maxPressureGapBar: 6,
            useEMAContext: false,
            maxPullbackBars: 6,
            maxContinuationBars: 10
        ).last

        XCTAssertEqual(result?.direction, .long)
        XCTAssertEqual(result?.spikeStartIndex, 16)
        XCTAssertEqual(result?.spikeEndIndex, 18)
        XCTAssertEqual(result?.gapEndIndex, 18)
        XCTAssertEqual(result?.pullbackIndex, 19)
        XCTAssertEqual(result?.entryIndex, 20)
        XCTAssertEqual(result?.entry ?? 0, 4057.055, accuracy: 0.0001)
        XCTAssertEqual(result?.stage, .entered)
    }

    func testInvalidatesDeepPullbackBeforeLaterBullishRecovery() {
        var candles = balancedWarmup()
        candles += [
            candle(100.0, 100.5, 99.9, 100.4),
            candle(100.4, 100.9, 100.2, 100.8),
            candle(100.8, 101.5, 100.45, 101.4),
            candle(101.4, 102.4, 101.3, 102.2),
            candle(102.2, 103.3, 102.1, 103.1),
            candle(103.1, 103.2, 99.8, 100.1),
            candle(100.1, 102.8, 100.0, 102.6),
        ]

        let result = SP2LSetup.compute(
            candles,
            minSpikeBars: 2,
            maxSpikeBars: 6,
            rangeBars: 4,
            atrPeriod: 4,
            minSpikeATR: 1.0,
            maxSpikeATR: 10.0,
            maxRangeATR: 1.5,
            minGapPct: 0,
            maxPressureGapBar: 6,
            useEMAContext: false,
            maxPullbackBars: 6,
            maxContinuationBars: 5
        ).first { $0.spikeStartIndex == 16 }

        XCTAssertNil(result?.entryIndex)
        XCTAssertEqual(result?.resolveIndex, 21)
        XCTAssertEqual(result?.stage, .invalidated)
    }

    func testRejectsWickOnlyBreakWithoutStrongClose() {
        var candles = balancedWarmup()
        candles += [
            candle(100.0, 101.4, 99.9, 100.2),
            candle(100.2, 102.4, 100.1, 102.2),
        ]

        XCTAssertTrue(detect(candles).isEmpty)
    }

    func testRejectsPressureGapThatIsOnlyMarketNoise() {
        var candles = balancedWarmup()
        candles += [
            candle(100.0, 101.4, 99.9, 101.2),
            candle(101.2, 102.4, 100.26, 102.2),
        ]

        XCTAssertTrue(detect(candles).isEmpty)
    }

    func testDetectsMirroredBearishStructuralBreak() {
        var candles = balancedWarmup()
        candles += [
            candle(100.0, 100.1, 98.6, 98.8),
            candle(98.8, 99.1, 97.6, 97.8),
        ]

        let result = detect(candles).last

        XCTAssertEqual(result?.direction, .short)
        XCTAssertEqual(result?.brokenLevel ?? 0, 99.75, accuracy: 0.0001)
    }

    private func makeResult(
        direction: SP2LSetup.Direction,
        entry: Double,
        stopLoss: Double,
        takeProfit: Double
    ) -> SP2LSetup.Result {
        SP2LSetup.Result(
            spikeStartIndex: 1,
            spikeEndIndex: 2,
            breakoutIndex: 1,
            followThroughIndex: 2,
            spikeHigh: 101,
            spikeLow: 99,
            brokenLevel: 100,
            levelStartIndex: 0,
            gapStartIndex: 0,
            gapEndIndex: 2,
            gapLow: 99.5,
            gapHigh: 100.5,
            direction: direction,
            stage: .limitPending,
            entry: entry,
            stopLoss: stopLoss,
            takeProfit: takeProfit,
            emaValue: nil
        )
    }

    private func detect(_ candles: [Candle]) -> [SP2LSetup.Result] {
        SP2LSetup.compute(
            candles,
            minSpikeBars: 2,
            maxSpikeBars: 2,
            rangeBars: 4,
            atrPeriod: 4,
            minSpikeATR: 1.0,
            maxSpikeATR: 6.0,
            maxRangeATR: 1.5,
            useEMAContext: false,
            maxPullbackBars: 3,
            maxContinuationBars: 5
        )
    }

    private func balancedWarmup() -> [Candle] {
        (0..<16).map { index in
            candle(100.0, 100.25, 99.75, index.isMultiple(of: 2) ? 100.05 : 99.95)
        }
    }

    private func bullishSpike() -> [Candle] {
        [
            candle(100.0, 101.4, 99.9, 101.2),
            candle(101.2, 102.4, 100.9, 102.2),
        ]
    }

    private func candle(_ open: Double, _ high: Double, _ low: Double, _ close: Double) -> Candle {
        defer { nextTimestamp += 60 }
        return Candle(
            id: Date(timeIntervalSince1970: TimeInterval(nextTimestamp)),
            open: open,
            high: high,
            low: low,
            close: close
        )
    }

    private var nextTimestamp = 1_700_000_000

    override func setUp() {
        super.setUp()
        nextTimestamp = 1_700_000_000
    }
}
