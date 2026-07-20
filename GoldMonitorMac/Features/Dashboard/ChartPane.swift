import Foundation

/// One pane in the multi-chart split-screen grid: an independent pair
/// + timeframe + chart type + indicator/oscillator selection.
/// Deliberately lighter than the primary dashboard chart — no
/// drawings, AI overlays, trade markers, replay, or journal pins;
/// those stay exclusive to the single-chart view (`DashboardView`'s
/// `chartCard`). See `ChartPaneView` for the pane renderer and
/// `MultiChartLayoutStore` for how panes are grouped into a layout and
/// persisted.
struct ChartPane: Identifiable, Codable, Equatable {
    let id: UUID
    var pairID: String
    var timeframe: Timeframe
    var chartType: ChartType
    var indicatorInstances: [IndicatorInstance]
    var oscillatorInstances: [OscillatorInstance]
    var showVolume: Bool

    init(
        id: UUID = UUID(),
        pairID: String,
        timeframe: Timeframe = .h1,
        chartType: ChartType = .candle,
        indicatorInstances: [IndicatorInstance] = [],
        oscillatorInstances: [OscillatorInstance] = [],
        showVolume: Bool = true
    ) {
        self.id = id
        self.pairID = pairID
        self.timeframe = timeframe
        self.chartType = chartType
        self.indicatorInstances = indicatorInstances
        self.oscillatorInstances = oscillatorInstances
        self.showVolume = showVolume
    }
}

/// Split-screen arrangement for the multi-chart grid. `.single` means
/// "don't show the grid" — the dashboard falls back to its
/// full-featured primary chart.
enum ChartLayoutKind: String, CaseIterable, Identifiable, Codable {
    case single
    case twoColumn
    case twoRow
    case grid2x2

    var id: String { rawValue }

    var paneCount: Int {
        switch self {
        case .single:             return 1
        case .twoColumn, .twoRow: return 2
        case .grid2x2:            return 4
        }
    }

    var label: String {
        switch self {
        case .single:    return "Single chart"
        case .twoColumn: return "2 columns"
        case .twoRow:    return "2 rows"
        case .grid2x2:   return "2 × 2 grid"
        }
    }

    /// SF Symbol for the layout picker.
    var icon: String {
        switch self {
        case .single:    return "rectangle"
        case .twoColumn: return "rectangle.split.2x1"
        case .twoRow:    return "rectangle.split.1x2"
        case .grid2x2:   return "rectangle.split.2x2"
        }
    }
}

/// Persists the multi-chart grid's layout + pane settings.
/// Independent of the primary dashboard's `@AppStorage` state, so
/// switching into grid mode and back never disturbs the single-chart
/// selections.
///
/// All layouts share a single `panes` array (up to 4 entries). When
/// the layout changes, only the pane *count* is adjusted — existing
/// panes keep their UUIDs so their `ChartPaneView`s stay mounted and
/// don't need to re-read candle history from GRDB or recompute
/// indicators. This eliminates the lag that the old per-layout
/// `panesByLayout` dictionary caused (swapping UUIDs → tearing down
/// every view on each layout switch).
@MainActor
final class MultiChartLayoutStore: ObservableObject {
    @Published var layout: ChartLayoutKind { didSet { save() } }
    @Published var panes: [ChartPane] { didSet { save() } }
    /// When on, changing a pane's pair pushes that pair to every other
    /// pane (each keeps its own timeframe). Off by default — most
    /// people splitting a chart want *different* symbols side by side,
    /// not the same symbol at different zoom levels.
    @Published var syncSymbol: Bool { didSet { save() } }
    /// Which pane (if any) the user has expanded to fullscreen in the
    /// grid. Nil ⇒ no pane is fullscreen. Lifted from ChartGridView's
    /// @State so the parent DashboardView can observe it and sync
    /// toolbar controls to the pane's state. (Grid fullscreen toolbar
    /// binding fix.)
    @Published var fullscreenPaneID: UUID?
    /// Which pane is the "active" target for the sidebar's symbol
    /// selection while `syncSymbol` is off. Clicking a pane focuses it;
    /// picking a symbol in the sidebar then changes that pane. Nil ⇒ fall
    /// back to the first pane, so a sidebar pick always changes *something*
    /// (the pre-focus bug was that a sidebar pick silently did nothing in
    /// grid mode). In-memory only — focus is a transient UI concern, not
    /// worth persisting.
    @Published var focusedPaneID: UUID?

    private static let storageKey = "dashboard.multichart.v3"
    private static let sp2lDefaultsVersionKey = "dashboard.multichart.sp2lDefaults.version"

    private struct Payload: Codable {
        var layout: ChartLayoutKind
        var panes: [ChartPane]
        var syncSymbol: Bool
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           var payload = try? JSONDecoder().decode(Payload.self, from: data) {
            let defaults = UserDefaults.standard
            if defaults.integer(forKey: Self.sp2lDefaultsVersionKey) < 2 {
                var changed = false
                for paneIndex in payload.panes.indices {
                    for indicatorIndex in payload.panes[paneIndex].indicatorInstances.indices {
                        changed = payload.panes[paneIndex].indicatorInstances[indicatorIndex]
                            .migrateLegacySP2LDefaults() || changed
                    }
                }
                defaults.set(2, forKey: Self.sp2lDefaultsVersionKey)
                if changed, let migrated = try? JSONEncoder().encode(payload) {
                    defaults.set(migrated, forKey: Self.storageKey)
                }
            }
            layout = payload.layout
            panes = payload.panes
            syncSymbol = payload.syncSymbol
        } else {
            layout = .single
            panes = []
            syncSymbol = false
        }
    }

    /// Grows `panes` to match `layout.paneCount`. Never truncates —
    /// switching from a larger layout (2x2) to a smaller one (single)
    /// keeps every pane in the array so switching back restores the
    /// user's exact configuration (pair, timeframe, indicators, etc.).
    /// Only appends new panes when the current array is shorter than
    /// the layout needs. Existing panes are never touched, so their
    /// UUIDs (and mounted `ChartPaneView`s) survive layout switches.
    func ensurePaneCount(defaultPairID: String) {
        let target = layout.paneCount
        guard panes.count < target else { return }
        // Inherit the primary chart's indicator / oscillator / volume
        // selections so grid panes open with the same sub-charts the
        // user already sees in single-chart mode — instead of empty
        // panes that require re-enabling everything from scratch.
        let indicatorsRaw = UserDefaults.standard.string(forKey: "dashboard.indicators") ?? ""
        let indicators = Set(indicatorsRaw.split(separator: ",").compactMap { IndicatorKind(rawValue: String($0)) })
        let oscillatorsRaw = UserDefaults.standard.string(forKey: "dashboard.oscillators") ?? ""
        let oscillators = Set(oscillatorsRaw.split(separator: ",").compactMap { OscillatorKind(rawValue: String($0)) })
        let showVolume: Bool = (UserDefaults.standard.object(forKey: "dashboard.showVolume") as? Bool) ?? true

        let seedTFs: [Timeframe] = [.m1, .m5, .m15, .h1]
        while panes.count < target {
            let tf = seedTFs[panes.count % seedTFs.count]
            panes.append(ChartPane(
                pairID: panes.last?.pairID ?? defaultPairID,
                timeframe: tf,
                indicatorInstances: indicators.map { IndicatorInstance(kind: $0) },
                oscillatorInstances: oscillators.map { OscillatorInstance(kind: $0) },
                showVolume: showVolume
            ))
        }
    }

    func setLayout(_ new: ChartLayoutKind, defaultPairID: String) {
        guard new != layout else { return }
        layout = new
        ensurePaneCount(defaultPairID: defaultPairID)
    }

    /// Replace one pane's settings (pair/timeframe/type/indicators). If
    /// `syncSymbol` is on and the pair just changed, propagate it to
    /// every other pane.
    func updatePane(_ pane: ChartPane) {
        guard let idx = panes.firstIndex(where: { $0.id == pane.id }) else { return }
        let pairChanged = panes[idx].pairID != pane.pairID
        panes[idx] = pane
        if syncSymbol, pairChanged {
            for i in panes.indices where i != idx { panes[i].pairID = pane.pairID }
        }
    }

    private func save() {
        let payload = Payload(layout: layout, panes: panes, syncSymbol: syncSymbol)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
