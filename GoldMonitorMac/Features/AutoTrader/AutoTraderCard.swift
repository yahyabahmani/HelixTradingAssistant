import SwiftUI

/// Settings card — per-pair auto-trader configuration. Sits under
/// Settings → Auto-trader. Each pair gets a collapsible row:
/// header summarises status + key knobs; expanding reveals the
/// full inspector (risk %, trailing ATR, news pause, etc).
struct AutoTraderCard: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var configStore: AutoTraderConfigStore
    @EnvironmentObject private var engine: AutoTraderEngine
    @EnvironmentObject private var paperBalance: PaperBalance
    @EnvironmentObject private var tradeStore: TradeStore

    @State private var expandedPairID: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            paperBalanceCard
            v1Banner
            ForEach(app.pairs) { pair in
                pairCard(pair)
            }
        }
        .onAppear {
            // Consume any deep-link request stashed by the
            // dashboard's gear button. Clearing it after consume
            // means re-opening the card later restores whichever
            // row was last expanded, not the deep-link target.
            if let target = app.autoTraderInspectorPairID {
                expandedPairID = target
                app.autoTraderInspectorPairID = nil
            }
        }
        .onChange(of: app.autoTraderInspectorPairID) { target in
            // Also catch the case where the user is already on
            // the Auto-trader tab when the deep-link fires (no
            // .onAppear).
            if let target = target {
                expandedPairID = target
                app.autoTraderInspectorPairID = nil
            }
        }
    }

    // ── Paper balance card ────────────────────────────────────────
    private var paperBalanceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    Image(systemName: "dollarsign.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.accentGradient)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Paper account")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.Color.textPrimary)
                        Text("Tracks closed paper trades across every pair. Risk-% sizing uses this balance so losses compound.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                    Spacer()
                }
                HStack(spacing: Theme.Spacing.xxl) {
                    balanceStat(
                        label: "BALANCE",
                        value: String(format: "$%.2f", paperBalance.currentBalance),
                        tint: paperBalance.currentBalance >= paperBalance.startingBalance
                              ? Theme.Color.success : Theme.Color.danger
                    )
                    balanceStat(
                        label: "REALISED P/L",
                        value: String(format: "%+.2f", paperBalance.realisedPL),
                        tint: paperBalance.realisedPL >= 0 ? Theme.Color.success : Theme.Color.danger
                    )
                    balanceStat(
                        label: "TRADES",
                        value: "\(paperBalance.totalTrades)",
                        tint: Theme.Color.textPrimary
                    )
                    balanceStat(
                        label: "W/L",
                        value: "\(paperBalance.wins) / \(paperBalance.losses)",
                        tint: Theme.Color.textPrimary
                    )
                }
                Divider().background(Theme.Color.border)
                HStack(spacing: Theme.Spacing.md) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("STARTING BALANCE")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Theme.Color.textMuted)
                        HStack(spacing: 2) {
                            Text("$")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Color.textMuted)
                            TextField("10000", value: Binding(
                                get: { paperBalance.startingBalance },
                                set: { paperBalance.startingBalance = $0 }
                            ), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                                .font(.system(size: 11).monospacedDigit())
                        }
                    }
                    Spacer()
                    Button("Reset paper account") {
                        paperBalance.resetToFresh(
                            amount: paperBalance.startingBalance,
                            in: tradeStore
                        )
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Color.danger)
                    .help("Drops every closed paper trade across all pairs and re-bases the balance to the starting amount above. Live trades are untouched.")
                }
            }
        }
    }

    private func balanceStat(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(Theme.Color.textMuted)
            Text(value)
                .font(.system(size: 18, weight: .bold).monospacedDigit())
                .foregroundStyle(tint)
        }
    }

    // ── v1 limitations banner ─────────────────────────────────────
    private var v1Banner: some View {
        Card {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.Color.info)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Paper trading only.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                    Text("The auto-trader stages simulated trades and tracks their P&L — no order ever reaches a real broker.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
    }

    // ── Per-pair card ────────────────────────────────────────────
    private func pairCard(_ pair: TradingPair) -> some View {
        let cfg = configStore.config(for: pair.id)
        let state = engine.displayState(for: pair.id)
        let isExpanded = expandedPairID == pair.id
        return Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                header(pair: pair, cfg: cfg, state: state, isExpanded: isExpanded)
                if isExpanded {
                    Divider().background(Theme.Color.border)
                    inspector(pair: pair)
                }
            }
        }
    }

    private func header(
        pair: TradingPair,
        cfg: AutoTraderConfig,
        state: (label: String, color: Color),
        isExpanded: Bool
    ) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            ZStack {
                Circle().fill(pair.color.opacity(0.18))
                Circle().strokeBorder(pair.color.opacity(0.55), lineWidth: 1)
                Text(String(pair.symbol.prefix(2)))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(pair.color)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(pair.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(summaryLine(cfg))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            Spacer()

            // State badge.
            Text(state.label)
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.5)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(state.color))

            // Master toggle — flipping ON kicks off the first Beta
            // TSA run so the engine has something to stage. Without
            // this the bot does nothing until the user manually
            // runs an analysis.
            Toggle("", isOn: Binding(
                get: { configStore.config(for: pair.id).enabled },
                set: { newOn in
                    var c = configStore.config(for: pair.id)
                    c.enabled = newOn
                    configStore.update(c, for: pair.id)
                    if newOn { engine.kickstart(for: pair.id) }
                }
            ))
                .toggleStyle(.switch)
                .tint(Theme.Color.accentStart)
                .labelsHidden()

            Button {
                expandedPairID = expandedPairID == pair.id ? nil : pair.id
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Color.textMuted)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface))
            }
            .buttonStyle(.plain)
        }
    }

    private func summaryLine(_ cfg: AutoTraderConfig) -> String {
        var parts: [String] = []
        parts.append("Paper")
        parts.append("risk \(String(format: "%.1f", cfg.riskPercent))%")
        if let trail = cfg.trailingATRMultiple {
            parts.append("trail \(String(format: "%.1f", trail))×ATR")
        }
        return parts.joined(separator: " · ")
    }

    // ── Inspector ────────────────────────────────────────────────
    private func inspector(pair: TradingPair) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Strategy profile picker — Position / Swing / Scalp.
            // Snaps the continuous-mode + risk knobs to the
            // profile's recommended defaults so users don't have
            // to think about every tunable.
            strategyProfilePicker(pair: pair)

            // Mode switch — paper vs live, with big red treatment
            // when live is selected.
            modeSwitch(pair: pair)

            // Risk %.
            stepperRow(
                label: "RISK PER POSITION",
                value: configStore.binding(for: pair.id, \.riskPercent),
                range: 0.1...10.0,
                step: 0.1,
                format: "%.1f%%"
            )

            // Trailing ATR multiple. nil = off.
            trailingRow(pair: pair)

            // Max concurrent positions.
            stepperRowInt(
                label: "MAX CONCURRENT POSITIONS",
                value: configStore.binding(for: pair.id, \.maxConcurrentPositions),
                range: 1...5,
                format: "%d"
            )

            // Daily loss kill switch.
            stepperRow(
                label: "MAX DAILY LOSS",
                value: configStore.binding(for: pair.id, \.maxDailyLossPercent),
                range: 0.5...20.0,
                step: 0.5,
                format: "%.1f%%"
            )

            // Cooldown after consecutive losses.
            stepperRowInt(
                label: "COOLDOWN AFTER N LOSSES",
                value: configStore.binding(for: pair.id, \.cooldownAfterConsecutiveLosses),
                range: 1...10,
                format: "%d"
            )

            // News pause toggle.
            Toggle(isOn: configStore.binding(for: pair.id, \.pauseDuringHighImpactNews)) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pause during high-impact USD news")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Color.textPrimary)
                    Text("Skips staging within ±15 min of FOMC, CPI, NFP, etc.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Color.textMuted)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.Color.accentStart)
        }
    }

    private func strategyProfilePicker(pair: TradingPair) -> some View {
        let cfg = configStore.config(for: pair.id)
        return VStack(alignment: .leading, spacing: 6) {
            Text("STRATEGY PROFILE")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            HStack(spacing: 6) {
                ForEach(StrategyProfile.allCases) { profile in
                    profileChip(profile: profile, isOn: cfg.strategyProfile == profile) {
                        var c = cfg
                        c.applyProfile(profile)
                        configStore.update(c, for: pair.id)
                    }
                }
                Spacer()
            }
            // Description line for the currently-picked profile.
            Text(cfg.strategyProfile.meta.description)
                .font(.system(size: 10))
                .foregroundStyle(Theme.Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            // Soft warning for Scalp without a live tick source.
            // Yahoo's 10s polling is too coarse for 1m/5m setups.
            if cfg.strategyProfile.meta.requiresLiveTickStream {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.slash.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Color.warn)
                    Text("Scalp needs sub-second ticks — the bundled feeds poll every few seconds, so expect stops to lag on 1m/5m setups.")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.Color.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.Color.warn.opacity(0.15))
                )
            }
        }
    }

    private func profileChip(
        profile: StrategyProfile,
        isOn: Bool,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: profile.meta.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(profile.meta.label)
                    .font(.system(size: 11, weight: isOn ? .bold : .semibold))
            }
            .foregroundStyle(isOn ? .white : Theme.Color.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isOn
                          ? AnyShapeStyle(Theme.accentGradient)
                          : AnyShapeStyle(Theme.Color.surface))
            )
        }
        .buttonStyle(.plain)
        .help(profile.meta.description)
    }

    private func modeSwitch(pair: TradingPair) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MODE")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            HStack(spacing: 6) {
                modeChip(label: "Paper", isOn: true, tint: Theme.Color.warn) {}
                    .help("This build is paper-only — no broker connection.")
                Spacer()
            }
        }
    }

    private func modeChip(label: String, isOn: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isOn ? .bold : .medium))
                .foregroundStyle(isOn ? .white : Theme.Color.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(Theme.Color.surface))
                )
        }
        .buttonStyle(.plain)
    }

    private func stepperRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: String
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 9, weight: .bold)).tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.Color.textPrimary)
            }
            Spacer()
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    private func stepperRowInt(
        label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        format: String
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 9, weight: .bold)).tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.Color.textPrimary)
            }
            Spacer()
            Stepper("", value: value, in: range)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    private func trailingRow(pair: TradingPair) -> some View {
        let cfg = configStore.config(for: pair.id)
        let isOn = cfg.trailingATRMultiple != nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TRAILING STOP (ATR MULTIPLE)")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { newOn in
                        var c = cfg
                        c.trailingATRMultiple = newOn ? 1.5 : nil
                        configStore.update(c, for: pair.id)
                    }
                ))
                .toggleStyle(.switch)
                .tint(Theme.Color.accentStart)
                .labelsHidden()
            }
            if isOn {
                HStack {
                    Text(String(format: "%.1f × ATR(%d)", cfg.trailingATRMultiple ?? 1.5, cfg.atrPeriod))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.Color.textPrimary)
                    Spacer()
                    Stepper("", value: Binding(
                        get: { cfg.trailingATRMultiple ?? 1.5 },
                        set: { v in
                            var c = cfg
                            c.trailingATRMultiple = v
                            configStore.update(c, for: pair.id)
                        }
                    ), in: 0.5...5.0, step: 0.1)
                    .labelsHidden()
                    .controlSize(.small)
                }
            }
        }
    }
}
