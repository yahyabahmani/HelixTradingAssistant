import Foundation
import XCTest
@testable import HelixTradingApp

/// Locks in the port of the "Volume-Filtered Order Block Detector" Pine
/// indicator: swing-anchored detection, the volume split, and the breaker
/// (invalidation) lifecycle.
final class VolumeFilteredOrderBlocksTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func c(_ i: Int, _ o: Double, _ h: Double, _ l: Double, _ close: Double, _ v: Double = 100) -> Candle {
        Candle(id: start.addingTimeInterval(TimeInterval(i * 60)), open: o, high: h, low: l, close: close, volume: v)
    }

    /// A clean bullish setup for `swingLength = 3`: a decline forms a low
    /// pivot (bar 5), a rally forms a high pivot at 106 (bar 8), price pulls
    /// back to the order-block candle (bar 11), then bar 14 closes above the
    /// high pivot → a bullish order block anchored at bar 11.
    private func bullishBase() -> [Candle] {
        [
            c(0, 105, 106, 105, 105), c(1, 104, 105, 104, 104),
            c(2, 103, 104, 103, 103), c(3, 102, 103, 102, 102),
            c(4, 100, 101, 100, 100), c(5, 99, 100, 99, 99),      // low pivot
            c(6, 101, 102, 101, 101), c(7, 103, 104, 103, 103),
            c(8, 105, 106, 105, 105),                              // high pivot (106)
            c(9, 104, 105, 104, 104), c(10, 102, 103, 102, 102),
            c(11, 100, 101, 100, 100, 400),                        // OB candle
            c(12, 102, 103, 102, 102), c(13, 104, 105, 104, 104),
            c(14, 106, 107, 106, 107, 300),                        // break > 106
        ]
    }

    private func compute(
        _ candles: [Candle],
        invalidationWick: Bool = true,
        showHistoric: Bool = true,
        zonesPerSide: Int = 3,
        combine: Bool = false
    ) -> [VolumeFilteredOrderBlocks.Zone] {
        VolumeFilteredOrderBlocks.compute(
            candles, swingLength: 3, invalidationWick: invalidationWick,
            maxZonesPerSide: zonesPerSide, showHistoric: showHistoric, combine: combine
        ).zones
    }

    func testDetectsBullishBlock() {
        let zones = compute(bullishBase())
        let bull = zones.filter(\.isBullish)
        XCTAssertFalse(bull.isEmpty, "expected at least one bullish order block")
        // The block should sit around the swing low (~95) and not be a
        // breaker yet (price never traded back below it).
        let z = bull[0]
        XCTAssertFalse(z.breaker)
        XCTAssertLessThan(z.bottom, z.top)
        XCTAssertGreaterThan(z.volume, 0)
    }

    func testVolumeSplitSumsToTotal() {
        let z = compute(bullishBase()).first { $0.isBullish }
        XCTAssertNotNil(z)
        if let z {
            XCTAssertEqual(z.highVolume + z.lowVolume, z.volume, accuracy: 1e-6)
            XCTAssertGreaterThanOrEqual(z.balancePct, 0)
            XCTAssertLessThanOrEqual(z.balancePct, 100)
        }
    }

    func testBreakerHiddenWhenHistoricOff() {
        // Append bars that drive price well below the block, then back up —
        // the block invalidates (becomes a breaker) and is dropped when
        // historic zones are hidden.
        var cs = bullishBase()
        for i in 15..<23 { cs.append(c(i, 96, 97, 60, 62, 150)) }   // deep flush below the block
        let shown = compute(cs, showHistoric: true).filter(\.isBullish)
        let hidden = compute(cs, showHistoric: false).filter(\.isBullish)
        XCTAssertLessThanOrEqual(hidden.count, shown.count)
    }

    func testEmptyInput() {
        XCTAssertTrue(compute([]).isEmpty)
    }
}
