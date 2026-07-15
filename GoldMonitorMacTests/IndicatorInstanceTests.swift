import XCTest
@testable import HelixTradingApp

final class IndicatorInstanceTests: XCTestCase {
    func testMigratesOnlyLegacySP2LDefaults() {
        var instance = IndicatorInstance(
            kind: .sp2lStrategy,
            params: [
                "maxSpikeBars": .double(4),
                "maxSpikeATR": .double(3),
                "maxPressureGapBar": .double(3),
                "riskReward": .double(2),
            ]
        )

        XCTAssertTrue(instance.migrateLegacySP2LDefaults())
        XCTAssertEqual(instance.params["maxSpikeBars"]?.doubleValue, 6)
        XCTAssertEqual(instance.params["maxSpikeATR"]?.doubleValue, 10)
        XCTAssertEqual(instance.params["maxPressureGapBar"]?.doubleValue, 6)
        XCTAssertEqual(instance.params["riskReward"]?.doubleValue, 2)
    }

    func testPreservesCustomSP2LValues() {
        var instance = IndicatorInstance(
            kind: .sp2lStrategy,
            params: [
                "maxSpikeBars": .double(8),
                "maxSpikeATR": .double(7),
                "maxPressureGapBar": .double(5),
            ]
        )

        XCTAssertFalse(instance.migrateLegacySP2LDefaults())
        XCTAssertEqual(instance.params["maxSpikeBars"]?.doubleValue, 8)
        XCTAssertEqual(instance.params["maxSpikeATR"]?.doubleValue, 7)
        XCTAssertEqual(instance.params["maxPressureGapBar"]?.doubleValue, 5)
    }
}
