import XCTest
@testable import HelixTradingApp

/// Position sizing is the one place in the app where a quiet unit
/// mistake costs real money — the original Risk Calculator bug sized
/// gold 10× too large by pairing a dollar-denominated stop distance
/// with a per-$0.10 "point" value. These tests pin the invariant that
/// makes that class of bug impossible: whatever size comes back, losing
/// the stop distance on it must equal the requested risk.
final class PositionSizingTests: XCTestCase {

    /// The reported bug, verbatim: $1,000 account, 1% risk, gold entry
    /// 4035 with a stop at 4045. The correct answer is 0.01 lots, not
    /// the 0.1 the old code produced.
    func testGoldTenDollarStopSizesToOneHundredthLot() {
        let m = PositionMetrics.compute(
            entry: 4035, stop: 4045, target: nil,
            balance: 1000, riskPercent: 1,
            spec: .forPair(id: "ounce")
        )
        XCTAssertNotNil(m)
        XCTAssertEqual(m!.lots, 0.01, accuracy: 1e-9)
        XCTAssertEqual(m!.riskAmount, 10, accuracy: 1e-9)
    }

    /// The core invariant, across every instrument: lots × stop distance
    /// × value-per-price must reproduce the risk budget exactly.
    func testRiskBudgetIsExactForEveryPair() {
        let cases: [(pair: String, entry: Double, stop: Double)] = [
            ("ounce", 4035, 4045),
            ("wti",     78,   76.5),
            ("btc",  95000, 92000),
            ("eth",   3200,  3120),
            ("sol",    180,   171),
            ("dji",  43000, 42600),
            ("dxy",  104.2, 103.8),
        ]
        for c in cases {
            let spec = ContractSpec.forPair(id: c.pair)
            let m = PositionMetrics.compute(
                entry: c.entry, stop: c.stop, target: nil,
                balance: 25_000, riskPercent: 2,
                spec: spec
            )
            XCTAssertNotNil(m, "\(c.pair) produced no metrics")
            guard let m else { continue }
            let realisedLoss = m.lots * abs(c.entry - c.stop) * spec.valuePerPricePerLot
            XCTAssertEqual(
                realisedLoss, 500, accuracy: 1e-6,
                "\(c.pair): stop-out loses \(realisedLoss), expected the 500 risk budget"
            )
        }
    }

    /// Gold's spec is the one the bug report pinned down, so lock the
    /// number itself rather than only the invariant.
    func testGoldContractIsHundredOunces() {
        let spec = ContractSpec.forPair(id: "ounce")
        XCTAssertEqual(spec.contractSize, 100)
        XCTAssertEqual(spec.valuePerPricePerLot, 100)
    }

    func testRewardAndRRUseTargetDistance() {
        // 10 down to the stop, 30 up to the target ⇒ 3R, and the reward
        // must be three times the risk.
        let m = PositionMetrics.compute(
            entry: 4035, stop: 4025, target: 4065,
            balance: 10_000, riskPercent: 1,
            spec: .forPair(id: "ounce")
        )
        XCTAssertNotNil(m)
        XCTAssertEqual(m!.rr!, 3, accuracy: 1e-9)
        XCTAssertEqual(m!.riskAmount, 100, accuracy: 1e-9)
        XCTAssertEqual(m!.reward!, 300, accuracy: 1e-6)
    }

    /// Direction must not change the arithmetic — a short sized off the
    /// same distance risks the same money.
    func testShortSetupSizesIdenticallyToLong() {
        let spec = ContractSpec.forPair(id: "ounce")
        let long = PositionMetrics.compute(
            entry: 4035, stop: 4025, target: 4055,
            balance: 10_000, riskPercent: 1, spec: spec
        )
        let short = PositionMetrics.compute(
            entry: 4035, stop: 4045, target: 4015,
            balance: 10_000, riskPercent: 1, spec: spec
        )
        XCTAssertEqual(long!.lots, short!.lots, accuracy: 1e-12)
        XCTAssertEqual(long!.reward!, short!.reward!, accuracy: 1e-9)
    }

    /// Degenerate inputs return nil rather than an infinite or NaN size
    /// that would render as garbage on the chart.
    func testDegenerateInputsProduceNoMetrics() {
        let spec = ContractSpec.forPair(id: "ounce")
        // Stop sitting exactly on entry — the divide-by-zero case.
        XCTAssertNil(PositionMetrics.compute(
            entry: 4035, stop: 4035, target: nil,
            balance: 1000, riskPercent: 1, spec: spec
        ))
        XCTAssertNil(PositionMetrics.compute(
            entry: 4035, stop: 4045, target: nil,
            balance: 0, riskPercent: 1, spec: spec
        ))
        XCTAssertNil(PositionMetrics.compute(
            entry: 4035, stop: 4045, target: nil,
            balance: 1000, riskPercent: 0, spec: spec
        ))
    }

    func testSizeBelowBrokerMinimumIsFlagged() {
        // $100 account at 0.5% risking a wide stop can't reach 0.01 lots.
        let m = PositionMetrics.compute(
            entry: 4035, stop: 4085, target: nil,
            balance: 100, riskPercent: 0.5,
            spec: .forPair(id: "ounce")
        )
        XCTAssertNotNil(m)
        XCTAssertTrue(m!.belowMinLot)
    }

    // MARK: - Drawing integration

    /// A position built by the tool must round-trip through the model
    /// and produce the same numbers the label renders.
    func testPositionDrawingProducesMetrics() {
        let entry = DrawingPoint(date: Date(), price: 4035)
        let end   = DrawingPoint(date: Date().addingTimeInterval(3600), price: 4035)
        let d = ChartDrawing.position(
            long: true, entry: entry, end: end,
            stopDistance: 10, balance: 1000, riskPercent: 1
        )
        XCTAssertEqual(d.kind, .longPosition)
        XCTAssertEqual(d.stopPrice!, 4025, accuracy: 1e-9)
        // Target defaults to 2R.
        XCTAssertEqual(d.targetPrice!, 4055, accuracy: 1e-9)

        let m = d.positionMetrics(spec: .forPair(id: "ounce"))
        XCTAssertNotNil(m)
        XCTAssertEqual(m!.lots, 0.01, accuracy: 1e-9)
        XCTAssertEqual(m!.rr!, 2, accuracy: 1e-9)
    }

    /// A short's stop sits above entry and its target below.
    func testShortPositionDrawingOrientation() {
        let entry = DrawingPoint(date: Date(), price: 4035)
        let d = ChartDrawing.position(
            long: false, entry: entry, end: entry,
            stopDistance: 10, balance: 1000, riskPercent: 1
        )
        XCTAssertEqual(d.kind, .shortPosition)
        XCTAssertGreaterThan(d.stopPrice!, d.start.price)
        XCTAssertLessThan(d.targetPrice!, d.start.price)
    }

    /// Dragging the stop handle must move only the stop — entry, target
    /// and the time extent stay put.
    func testResizeStopHandleMovesOnlyTheStop() {
        let entry = DrawingPoint(date: Date(), price: 4035)
        let d = ChartDrawing.position(
            long: true, entry: entry, end: entry,
            stopDistance: 10, balance: 1000, riskPercent: 1
        )
        let moved = d.resized(
            anchor: .stop,
            to: DrawingPoint(date: entry.date.addingTimeInterval(9999), price: 4020)
        )
        XCTAssertEqual(moved.stopPrice!, 4020, accuracy: 1e-9)
        XCTAssertEqual(moved.start.price, d.start.price)
        XCTAssertEqual(moved.targetPrice!, d.targetPrice!)
        // The stop handle is price-only: the date must not follow.
        XCTAssertEqual(moved.start.date, d.start.date)
    }

    /// The time handle stretches the box without disturbing any level.
    func testResizeTimeHandleKeepsLevels() {
        let entry = DrawingPoint(date: Date(), price: 4035)
        let d = ChartDrawing.position(
            long: true, entry: entry, end: entry,
            stopDistance: 10, balance: 1000, riskPercent: 1
        )
        let later = entry.date.addingTimeInterval(7200)
        let moved = d.resized(anchor: .timeEnd, to: DrawingPoint(date: later, price: 9999))
        XCTAssertEqual(moved.end!.date, later)
        XCTAssertEqual(moved.end!.price, d.start.price)   // stays level
        XCTAssertEqual(moved.stopPrice!, d.stopPrice!)
        XCTAssertEqual(moved.targetPrice!, d.targetPrice!)
    }

    /// Positions persist with their risk settings — a saved chart must
    /// reload with the same sizing.
    func testPositionSurvivesCodableRoundTrip() throws {
        let entry = DrawingPoint(date: Date(), price: 4035)
        let d = ChartDrawing.position(
            long: true, entry: entry, end: entry,
            stopDistance: 10, balance: 2500, riskPercent: 1.5
        )
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(ChartDrawing.self, from: data)
        XCTAssertEqual(back.kind, d.kind)
        XCTAssertEqual(back.stopPrice, d.stopPrice)
        XCTAssertEqual(back.targetPrice, d.targetPrice)
        XCTAssertEqual(back.accountBalance, 2500)
        XCTAssertEqual(back.riskPercent, 1.5)
    }

    /// Drawings saved before the position tool existed must still decode
    /// — the position fields are simply absent from that JSON.
    func testLegacyDrawingJSONStillDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","kind":"trendLine",
         "start":{"date":0,"price":100},"visible":true}
        """.data(using: .utf8)!
        let d = try JSONDecoder().decode(ChartDrawing.self, from: json)
        XCTAssertEqual(d.kind, .trendLine)
        XCTAssertNil(d.stopPrice)
        XCTAssertNil(d.accountBalance)
        XCTAssertFalse(d.kind.isPosition)
    }
}
