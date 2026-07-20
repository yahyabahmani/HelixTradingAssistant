import SwiftUI

/// Popover risk/position-size calculator.
struct RiskCalculatorView: View {

    @AppStorage("riskcalc.accountBalance") private var accountBalance: Double = 10000
    @AppStorage("riskcalc.riskPercent")    private var riskPercent:    Double = 1.0
    @State private var entryPrice: String = ""
    @State private var stopPrice:  String = ""

    /// This popover is the gold calculator, so it pins to the XAUUSD
    /// spec (1 lot = 100 oz ⇒ $100 per $1.00 of price). Note the stop
    /// distance below is a raw *price* difference — brokers quote gold
    /// as "$10 per point" where a point is $0.10, and mixing the two
    /// conventions is a silent 10× sizing error.
    private let spec = ContractSpec.forPair(id: "ounce")

    private var entry: Double? { Double(entryPrice.replacingOccurrences(of: ",", with: ".")) }
    private var stop:  Double? { Double(stopPrice.replacingOccurrences(of: ",", with: ".")) }
    private var stopDistance: Double? {
        guard let e = entry, let s = stop, e != s else { return nil }
        return abs(e - s)
    }
    private var dollarRisk: Double { accountBalance * riskPercent / 100 }
    private var metrics: PositionMetrics? {
        guard let e = entry, let s = stop else { return nil }
        return PositionMetrics.compute(
            entry: e, stop: s, target: nil,
            balance: accountBalance, riskPercent: riskPercent, spec: spec
        )
    }
    private var lotSize: Double? { metrics?.lots }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Title ─────────────────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: "percent")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.Color.accentStart)
                Text("Risk Calculator")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.Color.textPrimary)
            }
            .padding(.bottom, 12)

            Divider().background(Theme.Color.border)
            Spacer().frame(height: 12)

            // ── Account ───────────────────────────────────────────
            label("Account Balance ($)")
            styledField("10000", text: Binding(
                get: { String(format: "%.0f", accountBalance) },
                set: { accountBalance = Double($0) ?? accountBalance }
            ))
            .padding(.bottom, 10)

            label("Risk per trade (%)")
            HStack(spacing: 8) {
                styledField("1.0", text: Binding(
                    get: { String(format: "%.1f", riskPercent) },
                    set: { riskPercent = min(max(Double($0) ?? riskPercent, 0.1), 10) }
                ))
                .frame(width: 80)
                Spacer()
            }
            .padding(.bottom, 6)
            // Preset buttons on their own row
            HStack(spacing: 6) {
                riskPreset(0.5)
                riskPreset(1.0)
                riskPreset(2.0)
                riskPreset(3.0)
                Spacer()
            }
            .padding(.bottom, 12)

            Divider().background(Theme.Color.border)
            Spacer().frame(height: 12)

            // ── Trade levels ──────────────────────────────────────
            label("Entry Price")
            styledField("e.g. 3285.50", text: $entryPrice)
                .padding(.bottom, 10)

            label("Stop Loss")
            styledField("e.g. 3270.00", text: $stopPrice)
                .padding(.bottom, 12)

            Divider().background(Theme.Color.border)
            Spacer().frame(height: 12)

            // ── Results ───────────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                resultRow("Dollar Risk",
                          String(format: "$%.2f", dollarRisk),
                          Theme.Color.danger)

                if let dist = stopDistance {
                    resultRow("Stop Distance",
                              String(format: "$%.2f", dist),
                              Theme.Color.textSecondary)
                }

                if let lots = lotSize {
                    Divider().background(Theme.Color.border)
                    resultRow("Lot Size (XAUUSD)",
                              String(format: "%.3f lots", lots),
                              Theme.Color.accentStart,
                              large: true)
                    resultRow("Mini lots",
                              String(format: "%.2f", lots * 10),
                              Theme.Color.textMuted)
                } else if !entryPrice.isEmpty || !stopPrice.isEmpty {
                    Text("Enter both entry and stop loss to get lot size.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Color.textMuted)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Color.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Color.border, lineWidth: 1))
            .padding(.bottom, 8)

            Text("XAUUSD standard lots — 1 lot = 100 oz ($100 per $1.00 move)")
                .font(.system(size: 9))
                .foregroundStyle(Theme.Color.textMuted)
        }
        .padding(16)
        .frame(width: 300)
        .background(Theme.Color.canvas)
    }

    // ── Sub-views ─────────────────────────────────────────────────

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.Color.textMuted)
            .padding(.bottom, 4)
    }

    private func styledField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Color.border, lineWidth: 1))
    }

    private func riskPreset(_ pct: Double) -> some View {
        let sel = abs(riskPercent - pct) < 0.01
        return Button { riskPercent = pct } label: {
            Text(String(format: "%.1f%%", pct))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(sel ? .white : Theme.Color.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(sel ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.Color.surface))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(sel ? Color.clear : Theme.Color.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func resultRow(_ label: String, _ value: String, _ tint: Color, large: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: large ? 12 : 10))
                .foregroundStyle(Theme.Color.textMuted)
            Spacer()
            Text(value)
                .font(.system(size: large ? 15 : 11, weight: large ? .bold : .semibold).monospacedDigit())
                .foregroundStyle(tint)
        }
    }
}
