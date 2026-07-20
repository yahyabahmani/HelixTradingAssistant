import SwiftUI

/// Shared building blocks for the on-chart economic-calendar layer —
/// the small impact-coloured flags pinned to the bottom time axis
/// (TradingView-style) plus the detail popover shown when one is
/// clicked/tapped. Compiled into **both** the macOS and iPad targets
/// (they share the `GoldMonitorMac/` tree), so `ChartView` and
/// `ChartViewiPad` render an identical news layer.
///
/// Rendering lives in the chart's `chartOverlay` (not as ChartContent
/// marks): each visible event's bar index is mapped to a screen X via
/// the `ChartProxy`, so flags, hit-testing, and popup placement all
/// share one coordinate system and never fight the plot clip.

// MARK: - Impact → colour

extension ForexFactoryEvent.ImpactLevel {
    /// Flag colour on the chart. ForexFactory's own folder convention:
    /// high = red, medium = orange, low = yellow, unknown = grey.
    /// Distinct from `NewsView.impactColor` (which paints "low" green
    /// for the list dots) so the chart matches TradingView's calendar
    /// exactly, per the feature's agreed colour map.
    var chartColor: Color {
        switch self {
        case .high:    return Theme.Color.danger
        case .medium:  return Theme.Color.warn
        case .low:     return Color(red: 0.95, green: 0.82, blue: 0.25)   // yellow
        case .unknown: return Theme.Color.textMuted
        }
    }
}

// MARK: - Marker model

/// One news event resolved to a bar index on the current chart. Built
/// by the chart from its visible candle range; `Identifiable` so the
/// flag `ForEach` diffs cleanly across pan/zoom.
struct NewsChartMarker: Identifiable {
    let id: String          // == event.id
    let barIndex: Double
    let event: ForexFactoryEvent
    var color: Color { event.impactLevel.chartColor }
}

// MARK: - Flag

/// The little pennant drawn at the bottom axis. A filled rounded
/// pole-less triangle sitting on a 1px stem — reads as a flag at
/// 9×11pt without needing an SF Symbol.
struct NewsFlagView: View {
    let color: Color
    var body: some View {
        VStack(spacing: 0) {
            Triangle()
                .fill(color)
                .frame(width: 9, height: 8)
                .overlay(Triangle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
            Rectangle()
                .fill(color.opacity(0.85))
                .frame(width: 1.5, height: 5)
        }
        .shadow(color: color.opacity(0.5), radius: 2)
    }

    /// Downward-pointing triangle (apex at the bottom, toward the axis).
    private struct Triangle: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.closeSubpath()
            return p
        }
    }
}

// MARK: - Detail popover

/// Compact detail card shown when a flag is clicked/tapped. Mirrors the
/// News-tab row's information (impact, currency, time, actual/forecast/
/// previous) in a small floating panel anchored above the flag.
struct NewsMarkerPopover: View {
    let event: ForexFactoryEvent
    /// Display zone — `NewsStore.effectiveTimeZone`, threaded in so the
    /// popup shows the same time the News tab does.
    let timeZone: TimeZone
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(event.impactLevel.chartColor)
                    .frame(width: 9, height: 9)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(event.currency)
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(Theme.Color.textMuted)
                        Text(NewsView.impactLabel(event.impactLevel).uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.4)
                            .foregroundStyle(event.impactLevel.chartColor)
                        Text(timeLabel)
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                    Text(event.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.Color.textMuted)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 14) {
                valueCell("Actual",   event.actual,   tint: actualTint)
                valueCell("Forecast", event.forecast, tint: Theme.Color.textSecondary)
                valueCell("Previous", event.previous, tint: Theme.Color.textMuted)
            }
        }
        .padding(10)
        .frame(width: 240, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.Color.surfaceMax)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.Color.border, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.45), radius: 10, y: 4)
        )
    }

    private func valueCell(_ label: String, _ text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.Color.textMuted)
            Text(text.isEmpty ? "—" : text)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(text.isEmpty ? Theme.Color.textMuted : tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeLabel: String {
        guard let at = event.eventAt else { return event.time }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "MMM d · HH:mm"
        return f.string(from: at)
    }

    /// "Actual beats forecast" → green, "misses" → red — same cheap
    /// leading-number heuristic the News list uses.
    private var actualTint: Color {
        guard let a = Self.leadingNumber(event.actual),
              let f = Self.leadingNumber(event.forecast)
        else { return Theme.Color.textPrimary }
        if a > f { return Theme.Color.success }
        if a < f { return Theme.Color.danger }
        return Theme.Color.textPrimary
    }

    private static func leadingNumber(_ s: String) -> Double? {
        var chars = ""
        var seenDigit = false
        for ch in s {
            if ch.isNumber { seenDigit = true; chars.append(ch) }
            else if ch == "." || ch == "-" || ch == "+" { chars.append(ch) }
            else if seenDigit { break }
            else if ch == " " { continue }
            else { break }
        }
        return Double(chars)
    }
}
