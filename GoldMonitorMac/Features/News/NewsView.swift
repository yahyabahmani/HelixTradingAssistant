import SwiftUI

/// News tab — ForexFactory macro calendar, fetched directly from
/// `nfs.faireconomy.media`, filtered by date + currency + impact.
/// No backend in the loop.
///
/// Layout: header card with date pager + filter chips + refresh
/// timer; below it the filtered event list. Each event row is its
/// own self-contained Card so the user can scan vertically and the
/// impact dot + currency badge stay visually anchored.
struct NewsView: View {
    @EnvironmentObject private var store: NewsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                header
                filterBar
                contentBody
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Theme.Color.canvas)
        .onAppear { store.retainAutoRefresh() }
        .onDisappear { store.releaseAutoRefresh() }
    }

    // MARK: - Header

    private var header: some View {
        Card(padding: Theme.Spacing.lg) {
            HStack(alignment: .center, spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Macro calendar")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.Color.textPrimary)
                    Text("ForexFactory · auto-refreshes every 5 min")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Color.textMuted)
                }
                Spacer()
                timeZoneMenu
                refreshButton
                datePager
            }
        }
    }

    // MARK: - Timezone picker

    /// Menu chip that lets the user pin the news feed to a different
    /// timezone (or "Local" — i.e. follow the OS). Default is OS-local
    /// since most traders watch the desk clock; the picker's there for
    /// people who track London/NY/Tokyo opens from another zone.
    private var timeZoneMenu: some View {
        Menu {
            Button {
                store.timeZonePreference = ""
            } label: {
                Label("Local (\(systemZoneTitle))", systemImage: store.timeZonePreference.isEmpty ? "checkmark" : "")
            }
            Divider()
            Section("Quick picks") {
                ForEach(NewsStore.curatedZones) { zone in
                    Button {
                        store.timeZonePreference = zone.id
                    } label: {
                        if store.timeZonePreference == zone.id {
                            Label(zone.title, systemImage: "checkmark")
                        } else {
                            Text(zone.title)
                        }
                    }
                }
            }
            Divider()
            Menu("All zones…") {
                ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { id in
                    Button {
                        store.timeZonePreference = id
                    } label: {
                        if store.timeZonePreference == id {
                            Label(id, systemImage: "checkmark")
                        } else {
                            Text(id)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                    .font(.system(size: 11, weight: .semibold))
                Text(store.timeZoneShortLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.6)
            }
            .foregroundStyle(Theme.Color.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Color.surface)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Display timezone for event times and countdowns")
    }

    /// Pretty name for the OS zone, used inside the "Local (…)" menu
    /// row so the user can see what they'd be falling back to.
    private var systemZoneTitle: String {
        let id = TimeZone.current.identifier
        if let abbr = TimeZone.current.abbreviation() { return "\(id) · \(abbr)" }
        return id
    }

    private var datePager: some View {
        HStack(spacing: 4) {
            stepButton(symbol: "chevron.left", help: "Previous day") {
                store.selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: store.selectedDate) ?? store.selectedDate
            }
            Button {
                store.selectedDate = Calendar.current.startOfDay(for: Date())
            } label: {
                VStack(alignment: .center, spacing: 0) {
                    Text(weekdayLabel)
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.Color.textMuted)
                    Text(dateLabel)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.Color.textPrimary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Color.surface)
                )
            }
            .buttonStyle(.plain)
            .help("Jump to today")
            stepButton(symbol: "chevron.right", help: "Next day") {
                store.selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: store.selectedDate) ?? store.selectedDate
            }
        }
    }

    private func stepButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 28, height: 32)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Color.surface))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var refreshButton: some View {
        Button {
            store.refresh()
        } label: {
            if store.isLoading {
                ProgressView().controlSize(.small).frame(width: 32, height: 32)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 32, height: 32)
            }
        }
        .buttonStyle(.plain)
        .disabled(store.isLoading)
        .help(refreshHelp)
    }

    private var refreshHelp: String {
        guard let last = store.lastFetchAt else { return "Refresh" }
        let secs = Int(Date().timeIntervalSince(last))
        return "Refreshed \(secs)s ago"
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        Card(padding: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text("CURRENCY")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.Color.textMuted)
                        .frame(width: 80, alignment: .leading)
                    ForEach(Self.currencyOptions, id: \.self) { code in
                        currencyChip(code)
                    }
                    Spacer()
                }
                HStack(spacing: Theme.Spacing.sm) {
                    Text("IMPACT")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.Color.textMuted)
                        .frame(width: 80, alignment: .leading)
                    impactChip(.high,   isOn: $store.showHigh)
                    impactChip(.medium, isOn: $store.showMedium)
                    impactChip(.low,    isOn: $store.showLow)
                    Spacer()
                }
            }
        }
    }

    /// Curated chip list — the rest are reachable via "All" but we
    /// don't render 20 chips. Gold traders care most about these.
    private static let currencyOptions = ["USD", "EUR", "GBP", "JPY", "AUD", "CAD", "CHF", "CNY"]

    private func currencyChip(_ code: String) -> some View {
        let isOn = store.currencyFilter.contains(code)
        return Button {
            if isOn { store.currencyFilter.remove(code) } else { store.currencyFilter.insert(code) }
        } label: {
            Text(code)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(isOn ? Color.white : Theme.Color.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(isOn ? Theme.Color.info : Theme.Color.surface)
                )
        }
        .buttonStyle(.plain)
    }

    private func impactChip(_ level: ForexFactoryEvent.ImpactLevel, isOn: Binding<Bool>) -> some View {
        let color = Self.impactColor(level)
        let label = Self.impactLabel(level)
        let count = store.impactCount(level)
        return Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.Color.textMuted)
            }
            .foregroundStyle(isOn.wrappedValue ? Theme.Color.textPrimary : Theme.Color.textMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Theme.Color.surface)
                    .opacity(isOn.wrappedValue ? 1 : 0.5)
            )
            .overlay(
                Capsule().strokeBorder(
                    isOn.wrappedValue ? color.opacity(0.45) : Color.clear,
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Body

    @ViewBuilder
    private var contentBody: some View {
        if store.events.isEmpty && store.isLoading {
            loadingState
        } else if let err = store.lastError, store.events.isEmpty {
            errorState(err)
        } else if store.filteredEvents.isEmpty {
            emptyState
        } else {
            ForEach(store.filteredEvents) { event in
                NewsEventRow(event: event, timeZone: store.effectiveTimeZone)
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: Theme.Spacing.md) {
            ProgressView()
                .controlSize(.regular)
            Text("Loading this week's calendar…")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Color.textMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private func errorState(_ message: String) -> some View {
        Card(padding: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Label("Couldn't load events", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Color.warn)
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textMuted)
                Button("Retry") { store.refresh() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 36))
                .foregroundStyle(Theme.Color.textMuted)
            Text("No events match the current filters")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Color.textSecondary)
            Text("Try widening the currency filter or stepping to a different day.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Date display helpers

    private var dateLabel: String {
        let f = DateFormatter()
        f.timeZone = store.effectiveTimeZone
        f.dateFormat = "MMM d"
        return f.string(from: store.selectedDate)
    }

    private var weekdayLabel: String {
        var cal = Calendar.current
        cal.timeZone = store.effectiveTimeZone
        if cal.isDateInToday(store.selectedDate) { return "TODAY" }
        if cal.isDateInTomorrow(store.selectedDate) { return "TOMORROW" }
        if cal.isDateInYesterday(store.selectedDate) { return "YESTERDAY" }
        let f = DateFormatter()
        f.timeZone = store.effectiveTimeZone
        f.dateFormat = "EEEE"
        return f.string(from: store.selectedDate).uppercased()
    }

    // MARK: - Shared visuals

    static func impactColor(_ level: ForexFactoryEvent.ImpactLevel) -> Color {
        switch level {
        case .high:    return Theme.Color.danger
        case .medium:  return Theme.Color.warn
        case .low:     return Theme.Color.success
        case .unknown: return Theme.Color.textMuted
        }
    }

    static func impactLabel(_ level: ForexFactoryEvent.ImpactLevel) -> String {
        switch level {
        case .high:    return "High"
        case .medium:  return "Medium"
        case .low:     return "Low"
        case .unknown: return "Other"
        }
    }
}

// MARK: - Event row

private struct NewsEventRow: View {
    let event: ForexFactoryEvent
    /// Display zone for this row's time + countdown. Pulled from
    /// `NewsStore.effectiveTimeZone` upstream — passed in rather
    /// than read from the EnvironmentObject so the row stays a
    /// pure value-render and SwiftUI can diff it cheaply.
    let timeZone: TimeZone

    var body: some View {
        Card(padding: Theme.Spacing.md) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                impactDot
                timeColumn
                titleColumn
                Spacer()
                valuesColumn
            }
        }
    }

    private var impactDot: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(NewsView.impactColor(event.impactLevel))
                .frame(width: 10, height: 10)
                .padding(.top, 4)
            Rectangle()
                .fill(Theme.Color.border)
                .frame(width: 1)
                .padding(.top, 4)
        }
        .frame(width: 10)
    }

    /// Time + currency badge + live countdown chip.
    ///
    /// The countdown is wrapped in a `TimelineView(.periodic(...))`
    /// that fires every second — but only this view subtree
    /// re-renders, so the rest of the row (title, values, sentiment)
    /// stays static and SwiftUI doesn't re-diff the whole list each
    /// tick. Widened from 90→110pt to fit the countdown text.
    private var timeColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localTimeLabel)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.Color.textPrimary)
            Text(event.currency)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.Color.textMuted)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(Theme.Color.surface)
                )
            if event.eventAt != nil {
                TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                    countdownChip(now: ctx.date)
                }
            }
        }
        .frame(width: 110, alignment: .leading)
    }

    /// Live countdown / since-fired chip. Colours:
    ///   • amber when the event is within the next 30 minutes
    ///   • red while it's "live" (within ±1 min of the timestamp)
    ///   • muted grey otherwise (both future and past)
    @ViewBuilder
    private func countdownChip(now: Date) -> some View {
        if let when = event.eventAt {
            let delta = when.timeIntervalSince(now)
            let (text, tint) = countdownText(delta: delta)
            HStack(spacing: 3) {
                Image(systemName: delta >= 0 ? "timer" : "clock.arrow.circlepath")
                    .font(.system(size: 8, weight: .bold))
                Text(text)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(tint.opacity(0.12))
            )
            .accessibilityLabel(Text(text))
        }
    }

    /// Format the time-until / time-since the event. Resolution:
    ///   • |Δ| < 60s  → "now"
    ///   • |Δ| < 1h   → "in 12m" / "12m ago"
    ///   • |Δ| < 24h  → "in 3h 4m" / "3h 4m ago"
    ///   • otherwise  → "in 2d 4h" / "2d 4h ago"
    /// Hand-rolled rather than `RelativeDateTimeFormatter` because we
    /// want fixed-width "h/m/d/s" tokens that monospace-align across
    /// rows; the formatter's localised output ("a few seconds")
    /// jitters width every tick.
    private func countdownText(delta: TimeInterval) -> (String, Color) {
        let abs = Swift.abs(delta)
        // Within ±60s → "now" (red — the event is essentially live).
        if abs < 60 {
            return ("now", Theme.Color.danger)
        }
        let inFuture = delta >= 0
        let total = Int(abs)
        let mins = (total / 60) % 60
        let hours = (total / 3600) % 24
        let days = total / 86400
        let body: String
        if days > 0 {
            body = hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        } else if hours > 0 {
            body = mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
        } else {
            body = "\(mins)m"
        }
        let phrase = inFuture ? "in \(body)" : "\(body) ago"
        // Imminent (within 30 min, future) → amber for the trader's eye.
        let tint: Color = (inFuture && abs <= 1800) ? Theme.Color.warn : Theme.Color.textMuted
        return (phrase, tint)
    }

    private var titleColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                sentimentChip
                Text(NewsView.impactLabel(event.impactLevel))
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(NewsView.impactColor(event.impactLevel))
            }
            Text(event.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !event.url.isEmpty, let url = URL(string: event.url) {
                Link(destination: url) {
                    HStack(spacing: 3) {
                        Text("Details")
                            .font(.system(size: 10, weight: .medium))
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(Theme.Color.info)
                }
            }
        }
    }

    private var valuesColumn: some View {
        HStack(spacing: Theme.Spacing.md) {
            valueCell(label: "Actual",   text: event.actual,   tint: actualTint)
            valueCell(label: "Forecast", text: event.forecast, tint: Theme.Color.textSecondary)
            valueCell(label: "Previous", text: event.previous, tint: Theme.Color.textMuted)
        }
    }

    private func valueCell(label: String, text: String, tint: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.Color.textMuted)
            Text(text.isEmpty ? "—" : text)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(text.isEmpty ? Theme.Color.textMuted : tint)
        }
        .frame(minWidth: 60, alignment: .trailing)
    }

    @ViewBuilder
    private var sentimentChip: some View {
        switch event.sentiment {
        case .bullish:
            label("BULL", color: Theme.Color.success)
        case .bearish:
            label("BEAR", color: Theme.Color.danger)
        case .neutral:
            EmptyView()
        }
    }

    private func label(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color))
    }

    /// "Actual beats forecast" → green, "misses" → red, otherwise
    /// neutral. Cheap heuristic — compares the leading numeric
    /// portions of both strings. Skips if either is non-numeric
    /// (e.g. policy decisions where the field is "Hold").
    private var actualTint: Color {
        guard let actual = Self.leadingNumber(event.actual),
              let forecast = Self.leadingNumber(event.forecast)
        else { return Theme.Color.textPrimary }
        if actual > forecast { return Theme.Color.success }
        if actual < forecast { return Theme.Color.danger }
        return Theme.Color.textPrimary
    }

    private static func leadingNumber(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "$", with: "")
        // Strip a trailing K/M/B suffix; we're comparing same-unit
        // pairs (forecast vs actual always match) so the magnitude
        // multiplier cancels out anyway.
        let stripped = trimmed.replacingOccurrences(
            of: #"([KMB])$"#,
            with: "",
            options: .regularExpression
        )
        return Double(stripped)
    }

    private var localTimeLabel: String {
        guard let when = event.eventAt else {
            // Untimed events keep their feed label (e.g. "All Day",
            // "Tentative") — those carry meaning.
            return event.time.isEmpty ? "—" : event.time
        }
        let f = DateFormatter()
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: when)
    }
}
