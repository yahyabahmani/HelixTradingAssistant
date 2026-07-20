import Foundation

/// Per-instrument contract specification, used for position sizing by
/// the Risk Calculator and the on-chart position tool.
///
/// **These are broker-dependent defaults.** Contract sizes for CFDs are
/// not standardised — especially for indices and the dollar index, where
/// brokers differ by a factor of 10 or more. The table in `forPair(id:)`
/// is the single place to correct them; everything else derives from it,
/// so a wrong spec is a one-line fix rather than a hunt.
///
/// All catalog instruments are USD-quoted, which is what lets
/// `valuePerPricePerLot` collapse to the contract size: one standard lot
/// of N units gains/loses $N for every $1.00 the price moves. A non-USD
/// quote currency would need a conversion factor here.
struct ContractSpec: Equatable, Hashable {

    /// Units of the underlying in one standard lot (oz, barrels, coins,
    /// index units).
    let contractSize: Double

    /// Singular unit name, for labels like "100 oz".
    let unitLabel: String

    /// Smallest lot most brokers accept. Sizing below this is reported
    /// so the UI can warn rather than silently suggest an untradeable
    /// position.
    let minLot: Double

    /// Money gained/lost per $1.00 of price movement, per standard lot.
    /// USD-quoted instruments only (see type doc).
    var valuePerPricePerLot: Double { contractSize }

    /// Spec for a pair from `TradingPair.catalog`, by `id`.
    ///
    /// Unknown ids fall back to a 1-unit contract, which is the least
    /// surprising default for a spot-priced instrument and never
    /// silently inflates a position size.
    static func forPair(id: String) -> ContractSpec {
        switch id {
        // Gold: the standard XAUUSD lot is 100 oz, so $1.00 of price
        // is $100/lot. Brokers quote this as "$10 per point" where a
        // point is $0.10 — do not confuse the two.
        case "ounce":
            return ContractSpec(contractSize: 100, unitLabel: "oz", minLot: 0.01)
        // WTI: one lot is 1,000 barrels.
        case "wti":
            return ContractSpec(contractSize: 1000, unitLabel: "bbl", minLot: 0.01)
        // Crypto CFDs are conventionally 1 coin per lot.
        case "btc", "eth", "sol":
            return ContractSpec(contractSize: 1, unitLabel: "coin", minLot: 0.01)
        // US30: $1 per index point per lot is the common retail spec,
        // but some brokers use $10 — verify against yours.
        case "dji":
            return ContractSpec(contractSize: 1, unitLabel: "index", minLot: 0.01)
        // DXY: matches the ICE futures multiplier ($1,000/point). CFD
        // brokers vary widely here.
        case "dxy":
            return ContractSpec(contractSize: 1000, unitLabel: "index", minLot: 0.01)
        default:
            return ContractSpec(contractSize: 1, unitLabel: "unit", minLot: 0.01)
        }
    }
}

// MARK: - PositionMetrics

/// Sizing and P/L for a planned trade: what lot size risks exactly
/// `riskPercent` of the account given the entry→stop distance, and what
/// that position makes or loses at the target and stop.
///
/// Pure value type with no view or model dependencies so both the Risk
/// Calculator and the chart's position tool compute identically.
struct PositionMetrics: Equatable {

    /// Standard lots that put exactly `riskAmount` at risk. Not rounded
    /// to the broker's lot step — the point of the tool is to show the
    /// size that hits the risk target; rounding is the trader's call.
    let lots: Double

    /// Account currency at risk if the stop fills (the account
    /// balance × risk %).
    let riskAmount: Double

    /// Currency gained if the target fills. `nil` when no target is set.
    let reward: Double?

    /// Reward-to-risk multiple. `nil` without a target.
    let rr: Double?

    /// `lots` is below the instrument's minimum tradeable size.
    let belowMinLot: Bool

    /// Compute sizing for a trade. Returns `nil` when the inputs can't
    /// produce a position — a zero stop distance would divide by zero,
    /// and a non-positive balance or risk has no meaningful size.
    ///
    /// `stop` on the wrong side of `entry` for the given direction is
    /// still sized (the distance is absolute); it's the caller's job to
    /// decide whether to present that as an invalid setup.
    static func compute(
        entry: Double,
        stop: Double,
        target: Double?,
        balance: Double,
        riskPercent: Double,
        spec: ContractSpec
    ) -> PositionMetrics? {
        let stopDistance = abs(entry - stop)
        guard stopDistance > 0, balance > 0, riskPercent > 0 else { return nil }

        let riskAmount = balance * riskPercent / 100
        let perLot = stopDistance * spec.valuePerPricePerLot
        guard perLot > 0 else { return nil }
        let lots = riskAmount / perLot

        var reward: Double?
        var rr: Double?
        if let target {
            let targetDistance = abs(target - entry)
            reward = lots * targetDistance * spec.valuePerPricePerLot
            rr = targetDistance / stopDistance
        }

        return PositionMetrics(
            lots: lots,
            riskAmount: riskAmount,
            reward: reward,
            rr: rr,
            belowMinLot: lots < spec.minLot
        )
    }
}
