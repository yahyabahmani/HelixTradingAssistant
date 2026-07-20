import Foundation
import SwiftUI
import Combine

/// Models for user-drawn shapes (horizontal lines, trend lines,
/// rectangles) the chart toolbar lets the user place on the chart.
///
/// Anchored to *dates* (not bar indices) so a drawing made on the 1h
/// chart still positions correctly when the user flips to 4h — the
/// chart's `barIndex(forDate:)` helper resolves to the nearest bucket
/// at render time. Persisted per-pair in UserDefaults via DrawingStore.

// MARK: - DrawingPoint

/// A single (date, price) anchor for a drawing endpoint. Date is used
/// instead of bar index so the same drawing survives a timeframe
/// switch — the chart maps the date onto whatever index is closest in
/// the new candle series.
struct DrawingPoint: Codable, Hashable {
    let date: Date
    let price: Double
}

// MARK: - DrawingStyle

/// sRGB color + alpha persisted with a drawing. SwiftUI.Color isn't
/// directly Codable on macOS and lossy to recover via NSColor at every
/// render, so we store the four components ourselves and reconstruct
/// the `Color` value on demand.
struct ColorRGBA: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    /// Default for newly-drawn shapes — matches `DrawingPalette.stroke`
    /// so old saved drawings that decode with this default look the
    /// same as ones from before the colour field existed.
    static let defaultStroke = ColorRGBA(
        red: 1.00, green: 0.78, blue: 0.20, alpha: 1.0
    )
}

// MARK: - ChartDrawing

/// One user-drawn shape on the chart. `end` is optional because the
/// horizontal-line tool only needs a single point (everything to the
/// left and right of the click).
///
/// Endpoints, color, and line-width are all mutable so the inspector
/// popover can edit them in place via `DrawingStore.update`. The
/// fields added after v1.0 (`color`, `lineWidth`) decode with
/// back-compat defaults so old persisted JSON keeps loading.
struct ChartDrawing: Identifiable, Codable, Equatable {
    let id: UUID
    let kind: Kind
    var start: DrawingPoint
    var end: DrawingPoint?
    var visible: Bool

    /// Stroke colour with alpha. Drives the line/border for every
    /// shape; rectangles additionally derive a translucent fill from
    /// it (see `ChartView.drawingMarks`).
    var color: ColorRGBA

    /// Stroke width in points. Honoured for horizontal / trend lines
    /// and for the rectangle's border. Range clamped by the inspector
    /// UI; values stored as-is to keep the data model simple.
    var lineWidth: Double

    /// Distinct shape variants. Anything that draws differently — or
    /// surfaces with a distinct label in the Layers popover — gets its
    /// own case.
    enum Kind: String, Codable, CaseIterable {
        case horizontalLine
        case trendLine
        case rectangle
        case volumeProfile
        case longPosition
        case shortPosition

        /// Position tools carry stop/target levels and risk settings the
        /// other shapes don't, and are rendered and hit-tested as a
        /// three-level box rather than a plain shape.
        var isPosition: Bool { self == .longPosition || self == .shortPosition }

        /// A long profits above entry; a short profits below.
        var isLong: Bool { self == .longPosition }
    }

    // ── Position-tool fields ────────────────────────────────────────
    //
    // Only meaningful when `kind.isPosition`. For a position, `start`
    // is (left edge, entry price) and `end` is (right edge, entry
    // price) — the box's vertical extent comes from `stopPrice` and
    // `targetPrice` instead of `end.price`, because a position needs
    // three levels rather than two corners.

    /// Stop-loss price. The risk leg of the box.
    var stopPrice: Double?

    /// Take-profit price. The reward leg. Optional — a position can be
    /// planned with a stop only.
    var targetPrice: Double?

    /// Account balance this position sizes against. Seeded from the
    /// Risk Calculator's stored balance at creation, then editable per
    /// position so different scenarios can sit on one chart.
    var accountBalance: Double?

    /// Percent of `accountBalance` risked if the stop fills.
    var riskPercent: Double?

    init(
        id: UUID = UUID(),
        kind: Kind,
        start: DrawingPoint,
        end: DrawingPoint?,
        visible: Bool = true,
        color: ColorRGBA = .defaultStroke,
        lineWidth: Double = 1.5,
        stopPrice: Double? = nil,
        targetPrice: Double? = nil,
        accountBalance: Double? = nil,
        riskPercent: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.visible = visible
        self.color = color
        self.lineWidth = lineWidth
        self.stopPrice = stopPrice
        self.targetPrice = targetPrice
        self.accountBalance = accountBalance
        self.riskPercent = riskPercent
    }

    // ── Back-compat decoding ────────────────────────────────────────
    //
    // Drawings persisted before `color` / `lineWidth` existed lack
    // those keys; `decodeIfPresent` lets them decode with the same
    // visual defaults as a fresh draw.

    enum CodingKeys: String, CodingKey {
        case id, kind, start, end, visible, color, lineWidth
        case stopPrice, targetPrice, accountBalance, riskPercent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(UUID.self, forKey: .id)
        kind      = try c.decode(Kind.self, forKey: .kind)
        start     = try c.decode(DrawingPoint.self, forKey: .start)
        end       = try c.decodeIfPresent(DrawingPoint.self, forKey: .end)
        visible   = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        color     = try c.decodeIfPresent(ColorRGBA.self, forKey: .color) ?? .defaultStroke
        lineWidth = try c.decodeIfPresent(Double.self, forKey: .lineWidth) ?? 1.5
        // Position fields are absent on every drawing persisted before
        // the position tool existed, and on non-position shapes.
        stopPrice      = try c.decodeIfPresent(Double.self, forKey: .stopPrice)
        targetPrice    = try c.decodeIfPresent(Double.self, forKey: .targetPrice)
        accountBalance = try c.decodeIfPresent(Double.self, forKey: .accountBalance)
        riskPercent    = try c.decodeIfPresent(Double.self, forKey: .riskPercent)
    }

    /// Identifies which endpoint of a drawing a handle represents.
    /// Lives on the data model so `resized(anchor:to:)` can mutate the
    /// drawing without depending on the view layer.
    enum Handle: Equatable, Hashable {
        case start              // trend line / horizontal: anchor point
        case end                // trend line: second endpoint
        case topLeft, topRight, bottomLeft, bottomRight  // rectangle corners
        // Position tool. `entry` moves both price and time (it owns the
        // box's left edge); `stop`/`target` are price-only; `timeEnd`
        // is time-only, so the box can be stretched horizontally
        // without disturbing any level.
        case entry, stop, target, timeEnd
    }

    /// Produce a copy of this drawing with one endpoint moved to
    /// `cursor`. Handle semantics depend on the shape:
    ///   • horizontal line: the only handle moves the line's price
    ///     (date is preserved — horizontal extends across the chart)
    ///   • trend line: the named endpoint moves to the cursor
    ///   • rectangle: the corner moves; the opposite corner stays
    ///     pinned. `start` always reads as the top-left in resolved
    ///     bar-order, so we normalise the resulting box.
    func resized(anchor: Handle, to cursor: DrawingPoint) -> ChartDrawing {
        var copy = self
        switch kind {
        case .longPosition, .shortPosition:
            switch anchor {
            case .entry, .start:
                // Entry drags in both axes: the price moves with the
                // cursor and the box's left edge follows. Stop and
                // target hold their absolute prices so dragging entry
                // re-shapes risk/reward rather than sliding the whole
                // setup (that's what a body drag is for).
                copy.start = cursor
            case .stop:
                copy.stopPrice = cursor.price
            case .target:
                copy.targetPrice = cursor.price
            case .timeEnd, .end:
                // Horizontal stretch only — the right edge keeps the
                // entry price so the box stays level.
                copy.end = DrawingPoint(date: cursor.date, price: copy.start.price)
            default:
                break
            }
            return copy
        case .volumeProfile:
            // VP uses same two-corner semantics as rectangle
            guard let oldEnd = copy.end else { return copy }
            switch anchor {
            case .topLeft, .start:
                copy.start = cursor
            case .bottomRight, .end:
                copy.end = cursor
            case .topRight:
                copy.start = DrawingPoint(date: copy.start.date, price: cursor.price)
                copy.end   = DrawingPoint(date: cursor.date, price: oldEnd.price)
            case .bottomLeft:
                copy.start = DrawingPoint(date: cursor.date, price: copy.start.price)
                copy.end   = DrawingPoint(date: copy.end?.date ?? oldEnd.date, price: cursor.price)
            default:
                break   // position anchors don't apply to volume profiles
            }
            return copy
        case .horizontalLine:
            // Horizontal lines extend across the chart, so only the
            // price actually changes. The date stays whatever it was
            // so the persisted anchor doesn't drift.
            copy.start = DrawingPoint(date: copy.start.date, price: cursor.price)
        case .trendLine:
            switch anchor {
            case .start:
                copy.start = cursor
            case .end:
                copy.end = cursor
            default:
                break   // rectangle anchors don't apply to trend lines
            }
        case .rectangle:
            guard let oldEnd = copy.end else { return copy }
            // Determine which two of (start.date/end.date,
            // start.price/end.price) the cursor replaces. `start` is
            // one diagonal; `end` is the other. Each handle owns one
            // (date, price) pair, with the other pair fixed.
            switch anchor {
            case .topLeft, .start:
                copy.start = cursor
            case .bottomRight, .end:
                copy.end = cursor
            case .topRight:
                copy.start = DrawingPoint(date: copy.start.date, price: cursor.price)
                copy.end   = DrawingPoint(date: cursor.date,       price: oldEnd.price)
            case .bottomLeft:
                copy.start = DrawingPoint(date: cursor.date,       price: copy.start.price)
                copy.end   = DrawingPoint(date: copy.end?.date ?? oldEnd.date, price: cursor.price)
            default:
                break   // position anchors don't apply to rectangles
            }
        }
        return copy
    }

    // MARK: - Position helpers

    /// Entry price for a position drawing (`start.price` by
    /// construction). `nil` for every other shape.
    var entryPrice: Double? {
        kind.isPosition ? start.price : nil
    }

    /// Sizing + P/L for a position, given the instrument's contract
    /// spec. `nil` when this isn't a position, when the stop is missing
    /// or sits exactly at entry, or when the risk settings are unset —
    /// all cases where there is no honest number to display.
    func positionMetrics(spec: ContractSpec) -> PositionMetrics? {
        guard kind.isPosition,
              let stop = stopPrice,
              let balance = accountBalance,
              let risk = riskPercent
        else { return nil }
        return PositionMetrics.compute(
            entry: start.price,
            stop: stop,
            target: targetPrice,
            balance: balance,
            riskPercent: risk,
            spec: spec
        )
    }

    /// Build a position with stop/target placed a sensible distance from
    /// entry, used when the tool commits a fresh drawing. The drag
    /// height sets the stop distance so the box matches the gesture;
    /// the target defaults to 2R above/below entry.
    static func position(
        long: Bool,
        entry: DrawingPoint,
        end: DrawingPoint,
        stopDistance: Double,
        balance: Double,
        riskPercent: Double
    ) -> ChartDrawing {
        let dist = abs(stopDistance)
        let stop   = long ? entry.price - dist : entry.price + dist
        let target = long ? entry.price + dist * 2 : entry.price - dist * 2
        return ChartDrawing(
            kind: long ? .longPosition : .shortPosition,
            start: entry,
            end: DrawingPoint(date: end.date, price: entry.price),
            stopPrice: stop,
            targetPrice: target,
            accountBalance: balance,
            riskPercent: riskPercent
        )
    }
}

// MARK: - DrawingTool

/// What the user has armed in the chart toolbar. `.none` is the
/// pointer (drag = pan); the rest swap drag → draw-this-shape.
///
/// Conforms to `CaseIterable` so the toolbar can iterate over every
/// tool with a single `ForEach` and to `Identifiable` so it has a
/// stable id for that loop.
enum DrawingTool: String, CaseIterable, Identifiable, Equatable {
    case none
    case horizontalLine
    case trendLine
    case rectangle
    case volumeProfile
    case longPosition
    case shortPosition

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:           return "Cursor"
        case .horizontalLine: return "Horizontal line"
        case .trendLine:      return "Trend line"
        case .rectangle:      return "Rectangle"
        case .volumeProfile:  return "Volume Profile"
        case .longPosition:   return "Long position"
        case .shortPosition:  return "Short position"
        }
    }

    var systemImage: String {
        switch self {
        case .none:           return "cursorarrow"
        case .horizontalLine: return "minus"
        case .trendLine:      return "line.diagonal"
        case .rectangle:      return "rectangle"
        case .volumeProfile:  return "chart.bar.xaxis.ascending"
        case .longPosition:   return "arrow.up.right.square"
        case .shortPosition:  return "arrow.down.right.square"
        }
    }

    /// The drawing kind this tool commits, if it maps to one.
    var positionKind: ChartDrawing.Kind? {
        switch self {
        case .longPosition:  return .longPosition
        case .shortPosition: return .shortPosition
        default:             return nil
        }
    }
}

// MARK: - DrawingPalette

/// Colours used to render drawings. Kept in a namespace so the chart
/// rendering and the Layers popover swatch can share the exact same
/// values without re-declaring them at each call site.
///
/// Amber/gold matches the app's accent palette and reads clearly
/// against both dark and light candle bodies — green/red would
/// collide with the bullish/bearish candle colours.
enum DrawingPalette {
    static let stroke  = Color(red: 1.00, green: 0.78, blue: 0.20)
    static let fill    = Color(red: 1.00, green: 0.78, blue: 0.20).opacity(0.16)
    static let preview = Color(red: 1.00, green: 0.78, blue: 0.20).opacity(0.55)

    // ── Position tool ───────────────────────────────────────────────
    //
    // The position box is the one place green/red *should* be used:
    // profit and loss zones are the whole point of the tool, and
    // TradingView's convention is strong enough that any other palette
    // would read as wrong. Kept desaturated so candles stay legible
    // through the translucent fills.
    static let profit     = Color(red: 0.13, green: 0.72, blue: 0.47)
    static let loss       = Color(red: 0.90, green: 0.30, blue: 0.34)
    static let entryLine  = Color(red: 0.60, green: 0.65, blue: 0.72)
    static let zoneAlpha  = 0.18
}

// MARK: - SwiftUI.Color ↔ ColorRGBA bridge

extension ColorRGBA {
    /// Construct from a SwiftUI `Color` by going through NSColor's
    /// sRGB representation. Used by the settings popover's
    /// ColorPicker, which only speaks `Color`. Falls back to the
    /// default stroke when the color can't be resolved (e.g. dynamic
    /// system colors that don't expose components).
    init(_ color: Color) {
        #if os(iOS)
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: Double(r), green: Double(g), blue: Double(b), alpha: Double(a))
        #else
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: Double(r), green: Double(g), blue: Double(b), alpha: Double(a))
        #endif
    }
}

// MARK: - DrawingStore

/// Persistent per-pair store of user-drawn shapes. Mutating any pair's
/// list triggers `@Published` so DashboardView re-renders and saves
/// to UserDefaults under `dashboard.drawings.v1`.
///
/// Keyed by `pairID` (not by TradingPair value) so a stale snapshot of
/// a pair value won't fragment a user's drawings across two
/// "different" keys.
@MainActor
final class DrawingStore: ObservableObject {
    /// All drawings across all pairs, indexed by `pairID`. Exposed as
    /// `@Published` so the view layer can observe the whole map and
    /// re-render when any pair's slice changes.
    @Published private(set) var byPair: [String: [ChartDrawing]] = [:]

    /// Per-pair safety cap. Users won't realistically need more than
    /// this; the bound keeps UserDefaults from ballooning and protects
    /// the chart from accidentally rendering thousands of marks.
    private static let perPairCap = 100
    private static let storageKey = "dashboard.drawings.v1"

    init() {
        load()
    }

    // ── Reads ───────────────────────────────────────────────────────

    /// Drawings for one pair. Returns the empty array when the pair
    /// has nothing drawn — keeps every call site null-safe.
    func drawings(for pairID: String) -> [ChartDrawing] {
        byPair[pairID] ?? []
    }

    // ── Mutations ───────────────────────────────────────────────────

    /// Append a drawing to a pair's list. Respects the per-pair cap by
    /// trimming the oldest entries off the front when needed.
    func add(_ drawing: ChartDrawing, for pairID: String) {
        var list = byPair[pairID] ?? []
        list.append(drawing)
        if list.count > Self.perPairCap {
            list = Array(list.suffix(Self.perPairCap))
        }
        byPair[pairID] = list
        save()
    }

    /// Replace a drawing in place by `id`. Used by drag-to-move so the
    /// user's edits land back on the same slot instead of creating a
    /// duplicate. No-op when the id isn't present for `pairID` (e.g.
    /// after a clear race).
    func update(_ drawing: ChartDrawing, for pairID: String) {
        guard var list = byPair[pairID],
              let idx = list.firstIndex(where: { $0.id == drawing.id })
        else { return }
        list[idx] = drawing
        byPair[pairID] = list
        save()
    }

    /// Toggle visibility on a single drawing without dropping it. Used
    /// by the Layers popover's eye button.
    func setVisible(_ visible: Bool, id: UUID, for pairID: String) {
        guard var list = byPair[pairID],
              let idx = list.firstIndex(where: { $0.id == id })
        else { return }
        list[idx].visible = visible
        byPair[pairID] = list
        save()
    }

    /// Remove a drawing entirely.
    func remove(id: UUID, for pairID: String) {
        guard var list = byPair[pairID] else { return }
        list.removeAll { $0.id == id }
        // Don't leave an empty array sitting in the dict — saves a few
        // bytes and keeps `keys` accurate for any future "pairs with
        // drawings" callers.
        if list.isEmpty {
            byPair.removeValue(forKey: pairID)
        } else {
            byPair[pairID] = list
        }
        save()
    }

    /// Wipe every drawing for one pair. Not currently exposed in the
    /// UI but cheap to keep around for future "Clear all" entries.
    func clear(for pairID: String) {
        byPair.removeValue(forKey: pairID)
        save()
    }

    // ── Persistence ─────────────────────────────────────────────────

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: [ChartDrawing]].self, from: data)
        else { return }
        byPair = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(byPair) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
