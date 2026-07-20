import SwiftUI

/// Counts down to the next candle close for the active timeframe.
/// Sits next to the chart's subtitle so the user can tell at a glance
/// when a fresh bar will print — useful for entries that key off close.
///
/// Bucket math matches `CandleAggregator.aggregate`: every bar boundary
/// is at a `seconds-since-epoch` value divisible by `timeframe.seconds`.
/// The next close = floor(now / bucketSize) * bucketSize + bucketSize.
///
/// Uses `TimelineView(.periodic)` instead of `Timer.publish` + `@State`
/// to avoid "Modifying state during view update" warnings — the timer
/// fires during scroll/drag and compounds with chart updates.
struct TimeframeCountdown: View {
    let timeframe: Timeframe

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 4) {
                Image(systemName: "hourglass")
                    .font(.system(size: 9, weight: .semibold))
                Text("\(timeframe.label) closes in \(remainingText(now: context.date))")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
            }
        }
        .foregroundStyle(Theme.Color.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(Theme.Color.surface)
        )
    }

    // ── Math ──────────────────────────────────────────────────────────

    /// Seconds until the next candle boundary. Clamped to ≥ 0 so a
    /// tick that lands a hair past the boundary doesn't briefly show a
    /// negative number before the new bucket starts.
    private func remainingSeconds(now: Date) -> Int {
        let bucketSize = timeframe.seconds
        guard bucketSize > 0 else { return 0 }
        let nowSecs = now.timeIntervalSince1970
        let bucketStart = floor(nowSecs / bucketSize) * bucketSize
        let nextClose = bucketStart + bucketSize
        return max(0, Int(nextClose - nowSecs))
    }

    /// "23m 14s" / "1h 04m 12s" / "12s" — compact, drops empty leading
    /// units so short-TF countdowns don't show useless `0h 0m 23s`.
    private func remainingText(now: Date) -> String {
        let total = remainingSeconds(now: now)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%dh %02dm %02ds", h, m, s)
        } else if m > 0 {
            return String(format: "%dm %02ds", m, s)
        } else {
            return String(format: "%ds", s)
        }
    }
}
