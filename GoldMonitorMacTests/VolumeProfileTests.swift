import Foundation
import XCTest
@testable import HelixTradingApp

final class VolumeProfileTests: XCTestCase {

    // MARK: - Helpers

    private let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// UTC timestamp. July dates land in EDT (UTC-4), so 12:00 UTC is
    /// 08:00 ET — mid-session for the trading-day tests.
    private func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int, _ min: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(year: y, month: m, day: day, hour: h, minute: min))!
    }

    private func candle(_ date: Date, o: Double, h: Double, l: Double, c: Double, v: Double? = nil) -> Candle {
        Candle(id: date, open: o, high: h, low: l, close: c, volume: v)
    }

    /// `count` flat 1-minute candles (99…101, close 100) starting at
    /// `start`, plus optional overrides applied by index.
    private func flatCandles(
        _ count: Int,
        start: Date,
        overrides: [Int: (h: Double, l: Double, c: Double, v: Double?)] = [:]
    ) -> [Candle] {
        (0..<count).map { i in
            let date = start.addingTimeInterval(TimeInterval(i * 60))
            if let o = overrides[i] {
                return Candle(id: date, open: o.c, high: o.h, low: o.l, close: o.c, volume: o.v)
            }
            return Candle(id: date, open: 100, high: 101, low: 99, close: 100, volume: 1)
        }
    }

    // MARK: - Trading-day grouping

    func testTradingDayBoundaryAt18ET() {
        // 17:00 ET (21:00 UTC) belongs to the current calendar day;
        // 19:00 ET (23:00 UTC) opens the *next* trading day; 23:00 ET
        // (03:00 UTC next day) is still that same new trading day.
        let before = VolumeProfile.tradingDayStart(for: d(2026, 7, 13, 21))
        let open   = VolumeProfile.tradingDayStart(for: d(2026, 7, 13, 23))
        let late   = VolumeProfile.tradingDayStart(for: d(2026, 7, 14, 3))
        XCTAssertNotEqual(before, open)
        XCTAssertEqual(open, late)
    }

    func testComputeGroupsByTradingDay() {
        // 5 candles at 16:00 ET Mon, then 5 more across the 18:00 ET
        // boundary (19:00 + 21:00 ET) → exactly 2 sessions.
        var candles = flatCandles(5, start: d(2026, 7, 13, 20))   // 16:00 ET
        candles += flatCandles(3, start: d(2026, 7, 13, 23))      // 19:00 ET
        candles += flatCandles(2, start: d(2026, 7, 14, 1))       // 21:00 ET
        let sessions = VolumeProfile.compute(candles, bucketCount: 10)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].startBar, 0)
        XCTAssertEqual(sessions[0].endBar, 4)
        XCTAssertEqual(sessions[1].startBar, 5)
        XCTAssertEqual(sessions[1].endBar, 9)
    }

    func testComputeCapsSessionsToMostRecent() {
        // 8 trading days, one candle each at 12:00 ET → 5 returned, and
        // the last one covers the final bar.
        var candles: [Candle] = []
        for i in 0..<8 {
            candles += flatCandles(3, start: d(2026, 7, 6 + i, 16)) // 12:00 ET daily
        }
        let sessions = VolumeProfile.compute(candles, bucketCount: 10, maxSessions: 5)
        XCTAssertEqual(sessions.count, 5)
        XCTAssertEqual(sessions.last?.endBar, candles.count - 1)
    }

    // MARK: - POC / value area

    func testPOCIsBucketCentre() {
        // 9 flat candles (typical 100) + 1 heavy candle with typical
        // price 110. Range 99…111, 24 buckets → bucketSize 0.5, heavy
        // candle lands in bucket (110-99)/0.5 = 22 → centre 110.25.
        let candles = flatCandles(10, start: d(2026, 7, 14, 14), overrides: [
            9: (h: 111, l: 109, c: 110, v: 100)
        ])
        let sessions = VolumeProfile.compute(candles, bucketCount: 24)
        XCTAssertEqual(sessions.count, 1)
        let s = sessions[0]
        XCTAssertEqual(s.poc, 110.25, accuracy: 0.0001)
        XCTAssertEqual(s.buckets[s.pocIndex].volume, 100, accuracy: 0.0001)
    }

    func testValueAreaAt100PctCoversWholeRangeWithoutCrash() {
        // pct = 100 pushes the expansion walk to the heaviest possible
        // extent — the old implementation could index past the array
        // edges here. The walk stops as soon as all *volume* is inside,
        // so zero-volume edge buckets correctly stay out.
        let candles = flatCandles(10, start: d(2026, 7, 14, 14), overrides: [
            9: (h: 111, l: 109, c: 110, v: 100)
        ])
        let sessions = VolumeProfile.compute(candles, bucketCount: 24, valueAreaPct: 100)
        XCTAssertEqual(sessions.count, 1)
        let s = sessions[0]
        XCTAssertEqual(s.vaLowIndex, 2)   // lowest bucket holding volume
        XCTAssertEqual(s.vaHighIndex, 22) // the POC bucket itself
        let vaVolume = s.buckets[s.vaLowIndex...s.vaHighIndex].reduce(0) { $0 + $1.volume }
        let total = s.buckets.reduce(0) { $0 + $1.volume }
        XCTAssertEqual(vaVolume, total, accuracy: 0.0001)
    }

    // MARK: - Up/down volume split

    func testUpDownSplitSumsToTotal() {
        // Alternate up and down closes with real volume.
        let candles = (0..<20).map { i -> Candle in
            let up = i % 2 == 0
            return Candle(
                id: d(2026, 7, 14, 14).addingTimeInterval(TimeInterval(i * 60)),
                open: 100, high: 105, low: 95, close: up ? 104 : 96, volume: 10
            )
        }
        let sessions = VolumeProfile.compute(candles, bucketCount: 20)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(sessions[0].hasRealVolume)
        for bucket in sessions[0].buckets {
            XCTAssertEqual(bucket.upVolume + bucket.downVolume, bucket.volume, accuracy: 0.0001)
        }
        let totalUp = sessions[0].buckets.reduce(0) { $0 + $1.upVolume }
        let totalDown = sessions[0].buckets.reduce(0) { $0 + $1.downVolume }
        XCTAssertEqual(totalUp, 100, accuracy: 0.0001)
        XCTAssertEqual(totalDown, 100, accuracy: 0.0001)
    }

    func testNilVolumeFallsBackToUniformTPO() {
        let candles = flatCandles(10, start: d(2026, 7, 14, 14), overrides: [
            0: (h: 101, l: 99, c: 100, v: nil),
            1: (h: 101, l: 99, c: 100, v: nil),
            2: (h: 101, l: 99, c: 100, v: nil),
            3: (h: 101, l: 99, c: 100, v: nil),
            4: (h: 101, l: 99, c: 100, v: nil),
            5: (h: 101, l: 99, c: 100, v: nil),
            6: (h: 101, l: 99, c: 100, v: nil),
            7: (h: 101, l: 99, c: 100, v: nil),
            8: (h: 101, l: 99, c: 100, v: nil),
            9: (h: 101, l: 99, c: 100, v: nil),
        ])
        let sessions = VolumeProfile.compute(candles, bucketCount: 10)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertFalse(sessions[0].hasRealVolume)
        // Every candle contributes 1 → total profile volume == bar count.
        let total = sessions[0].buckets.reduce(0) { $0 + $1.volume }
        XCTAssertEqual(total, 10, accuracy: 0.0001)
    }

    // MARK: - Visible-range levels

    func testVisibleRangeExtractsRankedLevels() {
        // Two volume nodes: heavy cluster at ~100, lighter at ~110.
        var candles: [Candle] = []
        for i in 0..<15 {
            candles.append(candle(d(2026, 7, 14, 14).addingTimeInterval(TimeInterval(i * 60)),
                                  o: 100, h: 101, l: 99, c: 100, v: 50))
        }
        for i in 15..<30 {
            candles.append(candle(d(2026, 7, 14, 14).addingTimeInterval(TimeInterval(i * 60)),
                                  o: 110, h: 111, l: 109, c: 110, v: 30))
        }
        let vp = VolumeProfile.computeVisibleRange(
            candles,
            barRange: 0...29,
            bucketCount: 24,
            levelCount: 3
        )
        XCTAssertNotNil(vp)
        guard let vp else { return }
        XCTAssertEqual(vp.startBar, 0)
        XCTAssertEqual(vp.endBar, 29)
        XCTAssertFalse(vp.levels.isEmpty)
        // Strongest level first, flagged POC, strength 1.
        XCTAssertTrue(vp.levels[0].isPOC)
        XCTAssertEqual(vp.levels[0].strength, 1.0, accuracy: 0.0001)
        XCTAssertEqual(vp.levels[0].price, 100.25, accuracy: 0.6)
        // The second node shows up near 110.
        if vp.levels.count > 1 {
            XCTAssertFalse(vp.levels[1].isPOC)
            XCTAssertEqual(vp.levels[1].price, 110.25, accuracy: 0.6)
            XCTAssertLessThan(vp.levels[1].strength, 1.0)
        }
        // Levels never sit in adjacent buckets.
        for a in vp.levels {
            for b in vp.levels where a.price != b.price {
                XCTAssertGreaterThan(abs(a.price - b.price), vp.bucketSize)
            }
        }
    }

    func testVisibleRangeClampsBarRange() {
        let candles = flatCandles(10, start: d(2026, 7, 14, 14))
        let vp = VolumeProfile.computeVisibleRange(candles, barRange: -50...500, bucketCount: 10)
        XCTAssertNotNil(vp)
        XCTAssertEqual(vp?.startBar, 0)
        XCTAssertEqual(vp?.endBar, 9)
    }

    // MARK: - Degenerate input

    func testFlatSessionProducesNoProfile() {
        // Zero price range → nothing to bucket; must not crash or emit
        // a bogus profile.
        let candles = (0..<5).map { i in
            Candle(id: d(2026, 7, 14, 14).addingTimeInterval(TimeInterval(i * 60)),
                   open: 100, high: 100, low: 100, close: 100, volume: 1)
        }
        XCTAssertTrue(VolumeProfile.compute(candles, bucketCount: 10).isEmpty)
    }
}
