import Foundation
import Combine

/// Owns the rolling ForexFactory weekly cache and the user's filter
/// state for the News tab. Refreshes automatically every 5 minutes
/// while the tab is on screen, plus on explicit pull-to-refresh.
///
/// One source of truth for the entire News surface — the view binds
/// `@EnvironmentObject` and reads `filteredEvents` for the visible
/// list, no separate state holders.
@MainActor
final class NewsStore: ObservableObject {

    // ── Raw feed ──────────────────────────────────────────────────

    /// The full weekly event list as fetched. Date-filtered + currency-
    /// filtered downstream via `filteredEvents`.
    @Published private(set) var events: [ForexFactoryEvent] = []

    @Published private(set) var lastFetchAt: Date?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    // ── User filters ──────────────────────────────────────────────

    /// Selected day. Defaults to "today" in the user's local zone —
    /// the date selector chip drives this. Compared against the
    /// event's `date` string (ISO "YYYY-MM-DD"), so timezone math
    /// happens once at parse time and not on every render.
    @Published var selectedDate: Date = Calendar.current.startOfDay(for: Date())

    /// Whitelisted currencies. Empty == show everything. Matches the
    /// web app's default of USD-only on first load — gold traders
    /// usually care about USD events most.
    @Published var currencyFilter: Set<String> = ["USD"]

    /// Whether each impact bucket is included in the filtered view.
    /// All on by default — the user pares down rather than building
    /// up.
    @Published var showHigh: Bool = true
    @Published var showMedium: Bool = true
    @Published var showLow: Bool = true

    // ── Timezone preference ───────────────────────────────────────

    /// IANA timezone identifier (e.g. `America/New_York`,
    /// `Europe/London`) or the sentinel `""` meaning "follow the OS"
    /// — which is the default. Persisted to UserDefaults so the
    /// picker remembers the choice across launches. Set this and
    /// every formatter that reads `effectiveTimeZone` updates on
    /// the next render.
    @Published var timeZonePreference: String = NewsStore.loadTimeZonePref() {
        didSet {
            UserDefaults.standard.set(timeZonePreference, forKey: Self.timeZoneDefaultsKey)
        }
    }

    /// Resolved zone for display. Falls back to the OS if the saved
    /// identifier is empty *or* doesn't resolve (e.g. a deprecated
    /// IANA id). UI binds to this — never to the raw preference —
    /// so the fallback is centralised.
    var effectiveTimeZone: TimeZone {
        if timeZonePreference.isEmpty { return TimeZone.current }
        return TimeZone(identifier: timeZonePreference) ?? TimeZone.current
    }

    /// Short label for the picker chip ("Local", "NY", "UTC", …).
    /// Falls back to the abbreviation (`EST`, `JST`) so unfamiliar
    /// zones still get a readable handle.
    var timeZoneShortLabel: String {
        if timeZonePreference.isEmpty { return "Local" }
        if let pretty = Self.curatedZones.first(where: { $0.id == timeZonePreference })?.shortLabel {
            return pretty
        }
        return effectiveTimeZone.abbreviation() ?? effectiveTimeZone.identifier
    }

    /// Curated quick-pick list shown at the top of the timezone
    /// menu. The full IANA list lives in the "All zones" submenu
    /// for the long tail.
    static let curatedZones: [TimeZoneOption] = [
        .init(id: "UTC",                 shortLabel: "UTC",      title: "UTC"),
        .init(id: "America/New_York",    shortLabel: "NY",       title: "New York · EST/EDT"),
        .init(id: "America/Chicago",     shortLabel: "CHI",      title: "Chicago · CST/CDT"),
        .init(id: "America/Los_Angeles", shortLabel: "LA",       title: "Los Angeles · PST/PDT"),
        .init(id: "Europe/London",       shortLabel: "LDN",      title: "London · GMT/BST"),
        .init(id: "Europe/Frankfurt",    shortLabel: "FRA",      title: "Frankfurt · CET/CEST"),
        .init(id: "Asia/Dubai",          shortLabel: "DXB",      title: "Dubai · GST"),
        .init(id: "Asia/Tehran",         shortLabel: "TEH",      title: "Tehran · IRST"),
        .init(id: "Asia/Hong_Kong",      shortLabel: "HK",       title: "Hong Kong · HKT"),
        .init(id: "Asia/Tokyo",          shortLabel: "TYO",      title: "Tokyo · JST"),
        .init(id: "Australia/Sydney",    shortLabel: "SYD",      title: "Sydney · AEST/AEDT"),
    ]

    /// A bookmark on a zone — id is the IANA identifier we persist,
    /// `shortLabel` is the chip text, `title` is the menu row.
    struct TimeZoneOption: Hashable, Identifiable {
        let id: String
        let shortLabel: String
        let title: String
    }

    private static let timeZoneDefaultsKey = "news.timezone.v1"

    private static func loadTimeZonePref() -> String {
        UserDefaults.standard.string(forKey: timeZoneDefaultsKey) ?? ""
    }

    // ── Internals ─────────────────────────────────────────────────

    private var refreshTask: Task<Void, Never>?
    /// 5-minute auto-refresh of the **XML feed**. ForexFactory's
    /// weekly feed only updates when a new event fires (a few times
    /// per hour during US sessions), so a 5-min cadence is plenty
    /// for the schedule/titles/forecasts payload.
    private let refreshInterval: TimeInterval = 300

    /// Separate auto-refresh task for the Investing.com **actuals**
    /// scrape. Runs on a faster cadence because actuals can land
    /// within seconds of a release and the user is watching them in
    /// real time. We cache aggressively so the 60s cadence translates
    /// to one Investing.com request per minute, max, regardless of
    /// how many times the user toggles dates.
    private var actualsRefreshTask: Task<Void, Never>?
    private let actualsRefreshInterval: TimeInterval = 60

    /// Per-week actuals cache. Keyed by ISO week — `"YYYY-Www"` — so
    /// late-Sunday navigation to next-week events doesn't share a key
    /// with this-week. Value is `(fetchedAt, [normalisedKey: actual])`.
    /// TTL is `actualsCacheTTL`.
    private var actualsCache: [String: (at: Date, map: [String: String])] = [:]
    private let actualsCacheTTL: TimeInterval = 90

    /// How many surfaces currently want live news (the News tab while
    /// visible, plus the chart's news layer while enabled). Auto-refresh
    /// runs while this is > 0 so the News tab disappearing doesn't
    /// starve the chart's flags — and the chart never spins the feed up
    /// when nothing is watching. See `retainAutoRefresh`.
    private var autoRefreshRetainCount = 0

    // MARK: - Public API

    /// Kick off a one-shot fetch immediately. Idempotent — repeated
    /// calls coalesce into a single in-flight request.
    func refresh() {
        guard !isLoading else { return }
        Task { await fetchOnce() }
    }

    /// Register interest in live news. First retainer starts the
    /// auto-refresh loops; balanced by `releaseAutoRefresh`. Use this
    /// (not `startAutoRefresh` directly) from any surface that shares
    /// the feed with others.
    func retainAutoRefresh() {
        autoRefreshRetainCount += 1
        if autoRefreshRetainCount == 1 { startAutoRefresh() }
    }

    /// Drop interest in live news. Stops the loops once the last
    /// retainer releases. Never drives the count below zero.
    func releaseAutoRefresh() {
        autoRefreshRetainCount = max(0, autoRefreshRetainCount - 1)
        if autoRefreshRetainCount == 0 { stopAutoRefresh() }
    }

    /// Start auto-refreshing. Call when the News tab appears; the
    /// scheduler also fires an immediate fetch so the user doesn't
    /// stare at an empty list for 5 minutes.
    ///
    /// Two parallel loops:
    ///   • XML feed (schedule + forecasts + previous) every 5 min.
    ///   • Investing.com actuals overlay every 60s.
    /// The faster loop is what makes a freshly-released NFP / CPI
    /// print show up in the UI within a minute instead of within five.
    func startAutoRefresh() {
        if refreshTask == nil {
            refreshTask = Task { [weak self] in
                await self?.fetchOnce()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(self?.refreshInterval ?? 300) * 1_000_000_000)
                    if Task.isCancelled { break }
                    await self?.fetchOnce()
                }
            }
        }
        if actualsRefreshTask == nil {
            actualsRefreshTask = Task { [weak self] in
                // Slight delay before the first actuals fetch so the
                // initial XML load has a chance to populate `events`
                // — otherwise the first overlay has nothing to attach to.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                while !Task.isCancelled {
                    await self?.enrichWithActuals()
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: UInt64(self?.actualsRefreshInterval ?? 60) * 1_000_000_000)
                }
            }
        }
    }

    /// Stop both auto-refresh loops. Called when the News tab is no
    /// longer visible so we don't burn network on a hidden surface.
    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        actualsRefreshTask?.cancel()
        actualsRefreshTask = nil
    }

    // MARK: - Derived views

    /// Date string for the currently-selected day, in the same ISO
    /// format ForexFactory events use after parsing. Used by the
    /// list filter without recomputing on every event.
    var selectedDateISO: String {
        Self.isoFormatter.string(from: selectedDate)
    }

    /// Events for the selected day + currency/impact filter, sorted
    /// chronologically. All-day / tentative events sort to the top.
    var filteredEvents: [ForexFactoryEvent] {
        let dateKey = selectedDateISO
        let wantedCurrencies = currencyFilter
        return events
            .filter { $0.date == dateKey }
            .filter { wantedCurrencies.isEmpty || wantedCurrencies.contains($0.currency) }
            .filter { impactPasses($0.impactLevel) }
            .sorted { lhs, rhs in
                switch (lhs.eventAt, rhs.eventAt) {
                case (nil, nil): return lhs.title < rhs.title
                case (nil, _):   return true
                case (_, nil):   return false
                case (let a?, let b?): return a < b
                }
            }
    }

    /// Events for the on-chart news layer. Applies the same currency +
    /// impact filters as the News tab (so the chart mirrors what the
    /// user pared the calendar down to) but deliberately **skips the
    /// single-day date filter** — the chart's visible window can span
    /// several days, and it does its own bar-range clipping. Only
    /// timed events (`eventAt != nil`) can be placed on the axis, so
    /// "All Day" / "Tentative" rows are dropped here.
    var chartEvents: [ForexFactoryEvent] {
        let wantedCurrencies = currencyFilter
        return events.filter { ev in
            ev.eventAt != nil
                && (wantedCurrencies.isEmpty || wantedCurrencies.contains(ev.currency))
                && impactPasses(ev.impactLevel)
        }
    }

    /// Currencies present in the current feed — drives the filter
    /// chip row. Deterministic order so chips don't shuffle between
    /// refreshes.
    var availableCurrencies: [String] {
        Array(Set(events.map(\.currency))).sorted()
    }

    /// High/medium/low counts for the selected day — used to badge
    /// the impact toggles so the user sees "5 high events today".
    func impactCount(_ level: ForexFactoryEvent.ImpactLevel) -> Int {
        let dateKey = selectedDateISO
        return events.filter { $0.date == dateKey && $0.impactLevel == level }.count
    }

    // MARK: - Helpers

    private func impactPasses(_ level: ForexFactoryEvent.ImpactLevel) -> Bool {
        switch level {
        case .high:    return showHigh
        case .medium:  return showMedium
        case .low:     return showLow
        case .unknown: return showHigh || showMedium || showLow
        }
    }

    private func fetchOnce() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await ForexFactorySource.fetchThisWeek()
            self.events = fetched
            self.lastFetchAt = Date()
            self.lastError = nil
            // Immediately enrich with whatever actuals we can grab —
            // a manual ⟳ press refreshes BOTH sources in one motion.
            await enrichWithActuals(forceRefresh: false)
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    /// Overlay Investing.com-sourced actuals onto the current
    /// `events` list. Best-effort: network failures, parse errors,
    /// or upstream layout changes simply leave the existing data
    /// alone — the News tab never throws a banner over a failed
    /// enrichment. Called from:
    ///   • `fetchOnce()` — right after each XML refresh
    ///   • the 60s `actualsRefreshTask` — for fresh prints between
    ///     XML cycles
    ///   • `refresh()` indirectly via `fetchOnce`
    ///
    /// `forceRefresh: true` skips the in-memory cache (used by the
    /// auto-refresh loop so the 60s cadence actually translates into
    /// re-fetches once the cache TTL is past).
    private func enrichWithActuals(forceRefresh: Bool = false) async {
        guard !events.isEmpty else { return }

        // Cache key: the ISO week derived from the FIRST event we
        // have. The Investing endpoint we hit is "this week", and
        // FF's feed is also a rolling week, so a single key per
        // weekly batch is correct. If we ever support multi-week
        // navigation, change this to compute keys per visible date.
        let cacheKey = isoWeekKey(for: events.first?.eventAt ?? Date())

        let map: [String: String]
        if !forceRefresh,
           let cached = actualsCache[cacheKey],
           Date().timeIntervalSince(cached.at) <= actualsCacheTTL {
            map = cached.map
        } else {
            do {
                let fetched = try await InvestingActualsSource.fetchActualsForWeek()
                actualsCache[cacheKey] = (at: Date(), map: fetched)
                map = fetched
            } catch {
                // Silent fallback — leave events as-is.
                return
            }
        }
        guard !map.isEmpty else { return }

        // Overlay. SwiftUI's ForEach diff will only re-render rows
        // whose hashes changed — i.e. exactly the ones whose `actual`
        // field flipped from "" to a value.
        var changed = false
        let updated: [ForexFactoryEvent] = events.map { event in
            // Don't overwrite an actual we already have — could come
            // from a future "FF actuals re-enabled" path, and Investing
            // sometimes lags a few minutes behind FF.
            guard event.actual.isEmpty else { return event }
            let key = ForexFactoryEvent.normalisedTitleKey(currency: event.currency, title: event.title)
            guard let actual = map[key], !actual.isEmpty else { return event }
            changed = true
            return event.withActual(actual)
        }
        if changed {
            self.events = updated
        }
    }

    /// ISO 8601 week-of-year key (e.g. `2026-W22`) — used to bucket
    /// the Investing.com actuals cache. POSIX locale so the format
    /// is stable across user locales.
    private func isoWeekKey(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "YYYY-'W'ww"
        return f.string(from: date)
    }

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
