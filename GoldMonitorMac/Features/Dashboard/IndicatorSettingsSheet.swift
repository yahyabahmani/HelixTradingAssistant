import SwiftUI

/// Settings sheet for the panel oscillators (RSI / MACD / Stochastic).
/// Lives over the dashboard as a popover / sheet so the user can tune
/// periods without leaving the chart context. Edits write directly to
/// the bound config; the parent persists on dismiss.
struct IndicatorSettingsSheet: View {
    @Binding var config: OscillatorConfig
    /// When set, the sheet scrolls to this section on appear so the
    /// user lands directly on the tunables for the indicator they tapped.
    var focusSection: String? = nil
    @Environment(\.dismiss) private var dismiss

    /// Locally captured snapshot — if the user hits "Cancel" we restore
    /// this so accidental drags on a Stepper don't stick.
    @State private var original: OscillatorConfig?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack {
                Text(focusSection.map { "\($0) settings" } ?? "Indicator settings")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Spacer()
                Button {
                    if let orig = original { config = orig }
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface)
                        )
                }
                .buttonStyle(.plain)
                .help("Cancel")
            }

            // Scrollable so the sheet stays usable on a short display as
            // the indicator list grows — the header above and the Save /
            // Restore row below stay pinned outside this region.
            ScrollViewReader { proxy in
                ScrollView {
                    settingsSections
                }
                .frame(maxHeight: 520)
                .onAppear {
                    if let section = focusSection {
                        // Slight delay so the scroll view has laid out.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation { proxy.scrollTo(section, anchor: .top) }
                        }
                    }
                }
            }

            HStack {
                Button("Restore defaults") {
                    config = OscillatorConfig()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Color.textSecondary)
                Spacer()
                Button {
                    config.save()
                    dismiss()
                } label: {
                    Text("Save")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(Theme.Color.info)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(minWidth: 380, idealWidth: 420)
        .background(Theme.Color.surfaceHi)
        .onAppear { original = config }
        // MACD fast must stay below slow — clamp on the fly so the user
        // can never set fast >= slow and end up with a broken series.
        .onChange(of: config.macdFast) { _ in
            if config.macdFast >= config.macdSlow {
                config.macdSlow = config.macdFast + 1
            }
        }
        .onChange(of: config.macdSlow) { _ in
            if config.macdSlow <= config.macdFast {
                config.macdFast = max(2, config.macdSlow - 1)
            }
        }
    }

    /// The scrollable body of the sheet — every indicator's tunables.
    /// Pulled out of `body` so the header and the Save / Restore row can
    /// stay pinned outside the `ScrollView`.
    @ViewBuilder
    private var settingsSections: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            section(title: "RSI") {
                periodStepper(label: "Period", value: $config.rsiPeriod, range: 2...100)
            }

            Divider().background(Theme.Color.border)

            section(title: "MACD") {
                periodStepper(label: "Fast EMA",   value: $config.macdFast,   range: 2...50)
                periodStepper(label: "Slow EMA",   value: $config.macdSlow,   range: 3...100)
                periodStepper(label: "Signal EMA", value: $config.macdSignal, range: 2...50)
            }

            Divider().background(Theme.Color.border)

            section(title: "Stochastic") {
                periodStepper(label: "%K period", value: $config.stochK, range: 2...50)
                periodStepper(label: "%D period", value: $config.stochD, range: 1...20)
            }

            Divider().background(Theme.Color.border)

            section(title: "UT Bot Alerts") {
                doubleStepper(
                    label: "Key value (sensitivity)",
                    value: $config.utKeyValue,
                    range: 0.1...10.0,
                    step: 0.1
                )
                periodStepper(label: "ATR period", value: $config.utATRPeriod, range: 1...100)
                Toggle(isOn: $config.utShowTrailingStop) {
                    checkboxLabel("Show ATR trailing-stop line")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.utUseHeikinAshi) {
                    checkboxLabel("Use Heikin Ashi for signals")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
            }

            Divider().background(Theme.Color.border)

            section(title: "Order Blocks") {
                periodStepper(label: "Run length (periods)", value: $config.obPeriods, range: 1...20)
                doubleStepper(
                    label: "Min. % move",
                    value: $config.obThreshold,
                    range: 0.0...10.0,
                    step: 0.1
                )
                Toggle(isOn: $config.obUseWicks) {
                    checkboxLabel("Use whole high/low range")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.obShowExhausted) {
                    checkboxLabel("Show exhausted blocks")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.obDetectSteroids) {
                    checkboxLabel("Filter by volume (Steroids)")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.obNotifyEvents) {
                    checkboxLabel("Notify on appear / retest / exhaust")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
            }

            Divider().background(Theme.Color.border)

            section(title: "Steroid Order Blocks") {
                periodStepper(label: "Run length (periods)", value: $config.sobPeriods, range: 1...20)
                doubleStepper(
                    label: "Min. % move",
                    value: $config.sobThreshold,
                    range: 0.0...10.0,
                    step: 0.1
                )
                Toggle(isOn: $config.sobUseWicks) {
                    checkboxLabel("Use whole high/low range")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                doubleStepper(
                    label: "Volume multiplier",
                    value: $config.sobVolumeMultiplier,
                    range: 0.5...3.0,
                    step: 0.1
                )
                Toggle(isOn: $config.sobShowExhausted) {
                    checkboxLabel("Show exhausted blocks")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.sobDetectSteroids) {
                    checkboxLabel("Filter by volume (Steroids)")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.sobNotifyEvents) {
                    checkboxLabel("Notify on appear / retest / exhaust")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
            }

            Divider().background(Theme.Color.border)

            section(title: "Fair Value Gap") {
                doubleStepper(
                    label: "Min. gap size %",
                    value: $config.fvgThreshold,
                    range: 0.0...5.0,
                    step: 0.1
                )
                Toggle(isOn: $config.fvgShowMitigated) {
                    checkboxLabel("Show mitigated gaps")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
            }

            Divider().background(Theme.Color.border)

            section(title: "Sonarlab Order Blocks") {
                doubleStepper(
                    label: "Sensitivity (ROC threshold)",
                    value: $config.sonarlabSensitivity,
                    range: 1.0...100.0,
                    step: 1.0
                )
                Text("Lower = more blocks, higher = fewer blocks. Pine default: 26.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Mitigation type", selection: $config.sonarlabMitigationType) {
                    Text("Close").tag("Close")
                    Text("Wick").tag("Wick")
                }
                .pickerStyle(.segmented)
                Text("Close: block removed when prior close crosses boundary. Wick: uses current bar's high/low.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().background(Theme.Color.border)

            section(title: "Ranked Order Blocks") {
                periodStepper(label: "Swing length", value: $config.robSwingLength, range: 3...50)
                doubleStepper(
                    label: "Max zone size (× ATR)",
                    value: $config.robMaxATRMult,
                    range: 0.5...20.0,
                    step: 0.5
                )
                periodStepper(label: "ATR length", value: $config.robATRLength, range: 1...100)
                periodStepper(label: "Zones per side", value: $config.robZonesPerSide, range: 1...10)
                Picker("Zone built from", selection: $config.robZoneFrom) {
                    Text("Wicks").tag("Wicks")
                    Text("Body").tag("Body")
                }
                .pickerStyle(.segmented)
                Picker("Zone invalidation", selection: $config.robInvalidation) {
                    Text("Wick").tag("Wick")
                    Text("Close").tag("Close")
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $config.robShowBreakers) {
                    checkboxLabel("Show breaker zones")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.robCombineZones) {
                    checkboxLabel("Combine overlapping zones")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.robShowLabels) {
                    checkboxLabel("Show grade labels")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.robUseVP) {
                    checkboxLabel("Rank by Volume Profile (0–2)")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.robUseIchimoku) {
                    checkboxLabel("Rank by Ichimoku (0–3)")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Text("Zones score A / B / C on confluence. Turning a leg off shrinks the divisor on the badge (5 → 3 or 2); with both off zones render unranked.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().background(Theme.Color.border)

            // Times shown match the baked presets in `TradingSessions.catalog`
            // (regular cash hours, each in its venue's own time zone).
            section(title: "Trading Sessions") {
                Toggle(isOn: $config.sessShowTokyo) {
                    checkboxLabel("Tokyo · 09:00–15:00 JST")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.sessShowLondon) {
                    checkboxLabel("London · 08:30–16:30 UK")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.sessShowNewYork) {
                    checkboxLabel("New York · 09:30–16:00 ET")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif

                Divider().background(Theme.Color.border.opacity(0.4))

                Toggle(isOn: $config.sessShowNames) {
                    checkboxLabel("Show session names")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.sessShowOpenClose) {
                    checkboxLabel("Draw open & close lines")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.sessShowRange) {
                    checkboxLabel("Show session range")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.sessShowAverage) {
                    checkboxLabel("Show average price line")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
            }

            Divider().background(Theme.Color.border)

            // Entry (FVG 50%), stop (beyond the OR) and target (2R) are
            // fixed by design — only the breakout-strength gate and the
            // hunting window are tunable here.
            section(title: "NY Open Setup") {
                doubleStepper(
                    label: "Breakout strength (× ATR)",
                    value: $config.nyAtrMult,
                    range: 0.0...5.0,
                    step: 0.1
                )
                Toggle(isOn: $config.nyAMOnly) {
                    checkboxLabel("AM kill-zone only (09:35–11:00 ET)")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Text("Entry at FVG 50%, stop beyond the opening range, target 2R. 1m and 5m charts.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().background(Theme.Color.border)

            section(title: "SP2L Strategy") {
                periodStepper(label: "Min spike candles", value: $config.sp2lMinSpikeBars, range: 2...8)
                periodStepper(label: "Max spike candles", value: $config.sp2lMaxSpikeBars, range: 2...10)
                periodStepper(label: "Balance candles", value: $config.sp2lRangeBars, range: 2...12)
                periodStepper(label: "ATR period", value: $config.sp2lATRPeriod, range: 2...100)
                doubleStepper(
                    label: "Min spike width (× ATR)",
                    value: $config.sp2lMinSpikeATR,
                    range: 0.1...5.0,
                    step: 0.1
                )
                doubleStepper(
                    label: "Max spike width (× ATR)",
                    value: $config.sp2lMaxSpikeATR,
                    range: 0.5...10.0,
                    step: 0.25
                )
                doubleStepper(
                    label: "Max balance width (× ATR)",
                    value: $config.sp2lMaxRangeATR,
                    range: 0.25...5.0,
                    step: 0.1
                )
                doubleStepper(
                    label: "Min. gap size %",
                    value: $config.sp2lMinGapPct,
                    range: 0.0...5.0,
                    step: 0.1
                )
                periodStepper(label: "Latest P-Gap candle", value: $config.sp2lMaxPressureGapBar, range: 3...6)
                periodStepper(label: "Equilibrium EMA", value: $config.sp2lEMAPeriod, range: 10...200)
                Toggle(isOn: $config.sp2lUseEMAContext) {
                    checkboxLabel("Require EMA equilibrium context")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                doubleStepper(
                    label: "Max start distance from EMA (× ATR)",
                    value: $config.sp2lMaxEMADistanceATR,
                    range: 0.0...5.0,
                    step: 0.1
                )
                periodStepper(label: "Limit order expiry", value: $config.sp2lMaxPullbackBars, range: 1...30)
                periodStepper(label: "Continuation timeout", value: $config.sp2lMaxContinuationBars, range: 1...50)
                doubleStepper(
                    label: "Risk reward",
                    value: $config.sp2lRiskReward,
                    range: 0.25...5.0,
                    step: 0.25
                )
                periodStepper(label: "Take-profit targets", value: $config.sp2lTargetCount, range: 1...3)
                Text("Detects balance, breakout, follow-through and an early pressure gap. Entry is a resting limit at the first pullback level.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().background(Theme.Color.border)

            section(title: "Pin Bar · SP2L + BTB") {
                Toggle(isOn: $config.pinBarEnableSP2L) {
                    checkboxLabel("Confirm SP2L pullbacks")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.pinBarEnableBTB) {
                    checkboxLabel("Detect BTB broken-level retests")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                periodStepper(label: "ATR period", value: $config.pinBarATRPeriod, range: 2...100)
                doubleStepper(
                    label: "Min rejection wick / body",
                    value: $config.pinBarMinWickBodyRatio,
                    range: 1...8,
                    step: 0.25
                )
                doubleStepper(
                    label: "Min rejection wick / range",
                    value: $config.pinBarMinWickRangeRatio,
                    range: 0.3...0.9,
                    step: 0.05
                )
                doubleStepper(
                    label: "Max body / range",
                    value: $config.pinBarMaxBodyRangeRatio,
                    range: 0.05...0.6,
                    step: 0.05
                )
                doubleStepper(
                    label: "Min close near rejection side",
                    value: $config.pinBarMinCloseLocation,
                    range: 0.5...0.95,
                    step: 0.05
                )
                doubleStepper(
                    label: "Level tolerance (× ATR)",
                    value: $config.pinBarTouchToleranceATR,
                    range: 0...1,
                    step: 0.05
                )
                doubleStepper(
                    label: "Stop buffer (× ATR)",
                    value: $config.pinBarStopBufferATR,
                    range: 0...1,
                    step: 0.05
                )
                periodStepper(label: "Retest expiry", value: $config.pinBarMaxConfirmationBars, range: 1...30)
                periodStepper(label: "BTB level lookback", value: $config.pinBarBTBLookbackBars, range: 3...50)
                doubleStepper(
                    label: "Min BTB breakout body (× ATR)",
                    value: $config.pinBarMinBreakoutBodyATR,
                    range: 0...3,
                    step: 0.1
                )
                doubleStepper(
                    label: "Risk reward",
                    value: $config.pinBarRiskReward,
                    range: 0.25...10,
                    step: 0.25
                )
                periodStepper(label: "Trade timeout", value: $config.pinBarMaxContinuationBars, range: 1...100)
                Text("Waits for a rejection pin bar at the SP2L pullback or a broken BTB level. Entry is the pin-bar close; stop sits beyond its wick.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().background(Theme.Color.border)

            section(title: "Ichimoku Cloud") {
                periodStepper(label: "Tenkan (conversion)", value: $config.ichiTenkan, range: 2...60)
                periodStepper(label: "Kijun (base)", value: $config.ichiKijun, range: 2...120)
                periodStepper(label: "Senkou B", value: $config.ichiSenkouB, range: 2...240)
                periodStepper(label: "Displacement", value: $config.ichiDisplacement, range: 1...120)
                Toggle(isOn: $config.ichiShowChikou) {
                    checkboxLabel("Show Chikou (lagging) span")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Toggle(isOn: $config.ichiShowCloud) {
                    checkboxLabel("Show Kumo cloud fill")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Text("Tenkan/Kijun/Senkou B midlines with the ±displacement cloud and lagging span. Standard settings: 9 / 26 / 52 / 26.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().background(Theme.Color.border)

            section(title: "Ichimoku OB") {
                periodStepper(label: "Run length (periods)", value: $config.iobPeriods, range: 1...20)
                doubleStepper(
                    label: "Min. % move",
                    value: $config.iobThreshold,
                    range: 0.0...10.0,
                    step: 0.1
                )
                Toggle(isOn: $config.iobUseWicks) {
                    checkboxLabel("Use whole high/low range")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                periodStepper(label: "Tenkan (conversion)", value: $config.iobTenkan, range: 2...60)
                periodStepper(label: "Kijun (base)", value: $config.iobKijun, range: 2...120)
                periodStepper(label: "Senkou B", value: $config.iobSenkouB, range: 2...240)
                periodStepper(label: "Displacement", value: $config.iobDisplacement, range: 1...120)
                periodStepper(label: "Min confluence score", value: $config.iobMinScore, range: 0...4)
                Toggle(isOn: $config.iobRequireTrend) {
                    checkboxLabel("Require cloud-trend agreement")
                }
                #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                Text("Order blocks kept only where they line up with the Ichimoku picture. Score is +1 each for Kijun / Tenkan / Kumo overlap and cloud-trend agreement.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().background(Theme.Color.border)

            section(title: "Volume Profile") {
                Picker("Profile mode", selection: $config.vpMode) {
                    Text("Sessions (trading day)").tag("session")
                    Text("ZigZag trend").tag("zigzag")
                    Text("Visible range + levels").tag("visible")
                }
                .pickerStyle(.menu)
                if config.vpMode == "zigzag" {
                    Toggle(isOn: $config.vpShowZigzag) {
                        checkboxLabel("Show ZigZag lines on chart")
                    }
                    #if os(iOS)
.toggleStyle(.switch)
#else
.toggleStyle(.checkbox)
#endif
                    periodStepper(label: "ZigZag depth", value: $config.vpZZDepth, range: 2...50)
                    doubleStepper(
                        label: "ZigZag min change %",
                        value: $config.vpZZMinChange,
                        range: 0.1...10,
                        step: 0.5
                    )
                }
                if config.vpMode == "visible" {
                    periodStepper(label: "Volume levels", value: $config.vpLevelCount, range: 1...10)
                }
                periodStepper(label: "Buckets per profile", value: $config.vpBucketCount, range: 10...100)
                doubleStepper(
                    label: "Value Area %",
                    value: $config.vpValueAreaPct,
                    range: 50...95,
                    step: 5.0
                )
                Text(vpModeDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().background(Theme.Color.border)

            section(title: "Volume-Filtered OB") {
                robCheckbox("Show Historic Zones", $config.vfobShowHistoric)
                robCheckbox("Volumetric Info", $config.vfobVolumetricInfo)
                Picker("Zone Invalidation", selection: $config.vfobInvalidation) {
                    Text("Wick").tag("Wick")
                    Text("Close").tag("Close")
                }
                .pickerStyle(.menu)
                periodStepper(label: "Swing Length", value: $config.vfobSwingLength, range: 3...50)
                Picker("Zone Count", selection: $config.vfobZoneCount) {
                    Text("High").tag("High")
                    Text("Medium").tag("Medium")
                    Text("Low").tag("Low")
                    Text("One").tag("One")
                }
                .pickerStyle(.menu)
                Text("Swing-anchored order blocks with a volumetric up/down split and balance %. Zones invalidate (turn historic) when price breaks through, and overlapping same-side zones merge.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Platform-styled checkbox row for the Ranked-OB section (checkbox on
    /// macOS, switch when this shared file compiles into the iOS target).
    private func robCheckbox(_ text: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { checkboxLabel(text) }
        #if os(iOS)
        .toggleStyle(.switch)
        #else
        .toggleStyle(.checkbox)
        #endif
    }

    /// One-line explainer under the Volume Profile settings, matching
    /// the selected mode.
    private var vpModeDescription: String {
        switch config.vpMode {
        case "session":
            return "One profile per trading day (18:00 ET boundary) with POC and value area. Levels are scoped to their session; the latest day's project forward."
        case "visible":
            return "Profiles the bars on screen and draws the strongest high-volume levels across the range. Recomputes as you pan and zoom."
        default:
            return "Shows a volume profile for the current ZigZag trend segment only, placed in the right margin."
        }
    }

    /// Standard styling for a checkbox toggle's text label — shared by the
    /// UT Bot / Order Block / Trading Session boolean rows.
    private func checkboxLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.Color.textSecondary)
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.Color.textMuted)
                .id(title)  // anchor for ScrollViewReader scroll-to
            body()
        }
    }

    /// Compact label-and-Stepper row. The value text is rendered in the
    /// HStack itself (not inside the Stepper's own label closure) because
    /// `.labelsHidden()` would otherwise drop it along with the implicit
    /// label, leaving just the +/- buttons.
    private func periodStepper(label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
            Text("\(value.wrappedValue)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.Color.textPrimary)
                .frame(minWidth: 30, alignment: .trailing)
            Stepper("", value: value, in: range)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    /// Same shape as `periodStepper` but for Doubles (e.g. UT Bot key
    /// value, which is a multiplier in the 0.5–3.0 range typically).
    private func doubleStepper(label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
            Text(String(format: "%.1f", value.wrappedValue))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.Color.textPrimary)
                .frame(minWidth: 36, alignment: .trailing)
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
        }
    }
}
