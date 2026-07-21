import SwiftUI

/// Modal that asks the user which strategy profile a run should
/// use. Fires from two entry points — the chart's Analyze button
/// (before an ad-hoc CTS run) and the AUTO toggle (when enabling
/// the auto-trader for a pair). Lets the user pick a horizon +
/// snap all the related knobs in one click instead of digging
/// through the Settings inspector.
struct StrategyProfileSheet: View {
    let title: String
    let subtitle: String
    let currentProfile: StrategyProfile
    let confirmLabel: String
    let onPick: (StrategyProfile) -> Void
    let onCancel: () -> Void

    @State private var selected: StrategyProfile

    init(
        title: String,
        subtitle: String,
        currentProfile: StrategyProfile,
        confirmLabel: String,
        onPick: @escaping (StrategyProfile) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.currentProfile = currentProfile
        self.confirmLabel = confirmLabel
        self.onPick = onPick
        self.onCancel = onCancel
        _selected = State(initialValue: currentProfile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: Theme.Spacing.sm) {
                ForEach(StrategyProfile.allCases) { profile in
                    profileRow(profile)
                }
            }

            // Soft warning under Scalp — Yahoo polling is too
            // coarse for 1m setups, the user should know.
            if selected.meta.requiresLiveTickStream {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.slash.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Color.warn)
                    Text("Scalp needs sub-second ticks — the bundled feeds poll every few seconds, so expect lag on stops.")
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

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface)
                    )
                Spacer()
                Button(confirmLabel) { onPick(selected) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(Theme.accentGradient)
                    )
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 460)
        .background(Theme.Color.canvas)
    }

    private func profileRow(_ profile: StrategyProfile) -> some View {
        let isOn = selected == profile
        let meta = profile.meta
        return Button { selected = profile } label: {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Image(systemName: meta.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isOn ? .white : Theme.Color.accentStart)
                    .frame(width: 28, alignment: .center)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(meta.label)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(isOn ? .white : Theme.Color.textPrimary)
                        Text(timeframesLabel(meta.timeframes))
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(isOn ? .white.opacity(0.85) : Theme.Color.textMuted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(isOn ? Color.white.opacity(0.18) : Theme.Color.surface)
                            )
                    }
                    Text(meta.description)
                        .font(.system(size: 11))
                        .foregroundStyle(isOn ? .white.opacity(0.9) : Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        statChip("risk", String(format: "%.1f%%", meta.recommendedRiskPercent), isOn: isOn)
                        statChip("runs/hr", "\(meta.recommendedRunsPerHour)", isOn: isOn)
                        statChip("trail", String(format: "%.1f×ATR", meta.recommendedTrailingATR), isOn: isOn)
                    }
                }
                Spacer()
                if isOn {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(Theme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(isOn
                          ? AnyShapeStyle(Theme.accentGradient)
                          : AnyShapeStyle(Theme.Color.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(isOn ? Color.clear : Theme.Color.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func timeframesLabel(_ tfs: [Timeframe]) -> String {
        tfs.map { $0.label }.joined(separator: " · ")
    }

    private func statChip(_ name: String, _ value: String, isOn: Bool) -> some View {
        HStack(spacing: 3) {
            Text(name.uppercased())
                .font(.system(size: 8, weight: .heavy))
                .tracking(0.4)
                .foregroundStyle(isOn ? .white.opacity(0.7) : Theme.Color.textMuted)
            Text(value)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(isOn ? .white : Theme.Color.textSecondary)
        }
    }
}
