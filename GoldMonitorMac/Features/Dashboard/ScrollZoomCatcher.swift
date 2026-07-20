import SwiftUI
import AppKit

/// Modifier that converts vertical scroll-wheel events into chart zoom.
///
/// SwiftUI's gesture system on macOS doesn't deliver `scrollWheel:`
/// events to a `.gesture()` modifier — those go through AppKit's
/// responder chain, which sidesteps SwiftUI entirely. Embedding an
/// NSView in the SwiftUI tree as a hit-test target works for plain
/// scroll-wheel capture but breaks SwiftUI's own gesture passthrough.
///
/// The workaround: install a **window-level local event monitor** for
/// `.scrollWheel`. While the chart is on screen we watch every scroll
/// event delivered to this window, filter by whether the cursor is
/// over the chart's frame, and translate the event into an `xDomain`
/// update. Mouse-down / drag / pinch flow through SwiftUI as usual.
///
/// Zoom anchors around the cursor's X fraction so the bar under the
/// pointer stays put — same convention TradingView uses.
struct ScrollZoomModifier: ViewModifier {
    @Binding var xDomain: ClosedRange<Double>?
    let totalCandles: Int

    @State private var globalFrame: CGRect = .zero
    @State private var monitor: Any?

    /// Sensitivity per scroll-line. Trackpad delivers many small
    /// ticks, mouse-wheel a few large ones — this constant feels
    /// natural for both. Capped per-event in `applyZoom` so a fast
    /// flick can't ratchet through the whole history in one shot.
    private let zoomPerLine: Double = 0.06

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            globalFrame = geo.frame(in: .global)
                            installMonitor()
                        }
                        .onChange(of: geo.frame(in: .global)) { newFrame in
                            globalFrame = newFrame
                        }
                        .onDisappear { removeMonitor() }
                }
            )
    }

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard handleScroll(event) else { return event }
            return nil   // consumed — don't propagate to surrounding scrollers
        }
    }

    private func removeMonitor() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    /// Returns true iff the event was over the chart's frame and we
    /// applied a zoom. Anything else is left alone so other scroll
    /// views (sidebar, dashboard ScrollView) behave normally.
    private func handleScroll(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }

        // Cursor in window's bottom-left-origin coords → SwiftUI's
        // top-left-origin coords via the window's content view.
        let posInWindow = event.locationInWindow
        guard let contentView = window.contentView else { return false }
        let posInContent = contentView.convert(posInWindow, from: nil)
        // contentView uses AppKit coords (origin bottom-left); SwiftUI
        // `.global` frames use top-left origin. Flip Y manually.
        let flippedY = contentView.bounds.height - posInContent.y
        let cursor = CGPoint(x: posInContent.x, y: flippedY)

        guard globalFrame.contains(cursor) else { return false }

        var dy = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.deltaY * 10   // line-mode events report ~1 per click; scale up
        // Some mice / scroll drivers emit line-mode events with a zero
        // `deltaY` but a populated `scrollingDeltaY` — fall back so a
        // physical wheel click always zooms.
        if dy == 0 { dy = event.scrollingDeltaY }
        guard dy != 0 else { return false }

        applyZoom(dy: dy, cursor: cursor)
        return true
    }

    private func applyZoom(dy: CGFloat, cursor: CGPoint) {
        guard totalCandles > 0, globalFrame.width > 0 else { return }

        // Scroll up (dy > 0) zooms in, scroll down zooms out. Per-event
        // magnitude clamped so a single flick can't blow the chart up
        // or collapse it to a sliver.
        let magnitude = min(1.0, abs(Double(dy)) * zoomPerLine)
        let scale = dy >= 0 ? (1.0 - magnitude) : (1.0 + magnitude)
        let clampedScale = max(0.5, min(2.0, scale))

        let currentDomain = xDomain ?? defaultDomain()
        let span = currentDomain.upperBound - currentDomain.lowerBound
        let newSpan = max(2.0, min(Double(totalCandles) * 4, span * clampedScale))

        // Anchor: the bar index under the cursor stays at the same
        // pixel after the zoom. Compute the cursor's X fraction inside
        // the chart frame, then place the new window so that fraction
        // still maps to the same bar.
        let xFraction = max(0, min(1, Double((cursor.x - globalFrame.minX) / globalFrame.width)))
        let cursorBar = currentDomain.lowerBound + xFraction * span
        let newLower = cursorBar - xFraction * newSpan
        let newUpper = newLower + newSpan

        xDomain = newLower...newUpper
    }

    /// Fallback span when no pinned domain exists. Matches ChartView's
    /// auto-fit so the first scroll feels continuous, not a jump.
    private func defaultDomain() -> ClosedRange<Double> {
        let n = totalCandles
        if n <= 1 { return -0.5 ... 0.5 }
        return -0.5 ... Double(n - 1) + 0.5
    }
}

extension View {
    /// Attach scroll-wheel-to-zoom behavior to whatever this is
    /// applied to. Bind it to the same `xDomain` the chart uses.
    func scrollZoom(xDomain: Binding<ClosedRange<Double>?>, totalCandles: Int) -> some View {
        modifier(ScrollZoomModifier(xDomain: xDomain, totalCandles: totalCandles))
    }
}
