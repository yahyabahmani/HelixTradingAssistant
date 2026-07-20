import SwiftUI

/// Renders the multi-chart split-screen grid: 2 or 4 independent
/// `ChartPaneView`s arranged per `layoutStore.layout`. Swapped in by
/// `DashboardView.body` in place of the single-chart `chartCard` when
/// the layout isn't `.single` — see `DashboardView`'s `multiChart`
/// state and the layout picker in its pair header.
///
/// Layout switching is lag-free because the view tree is *always* a
/// fixed 2×2 grid. Unused slots collapse to zero frame + zero
/// opacity instead of being removed from the hierarchy — same trick
/// the fullscreen toggle already uses. This means no
/// `ChartPaneView` is ever torn down or rebuilt on a layout switch;
/// only frame/opacity values change, which SwiftUI animates smoothly.
struct ChartGridView<FullscreenToolbar: View>: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var layoutStore: MultiChartLayoutStore
    let indicatorConfig: OscillatorConfig
    /// Same store the primary single chart uses — drawings are a
    /// property of the pair, not of which view mode you're looking at
    /// it in, so a line drawn in a grid pane shows up on the primary
    /// chart for that pair too, and vice versa.
    @ObservedObject var drawingStore: DrawingStore
    /// The active drawing tool, shared with the parent (DashboardView).
    /// When a pane is fullscreen, its ChartView reads from this binding
    /// instead of its own @State, so the fullscreen toolbar's drawing
    /// picker and the pane's gesture handler use the same state.
    /// (Grid fullscreen drawing fix.)
    @Binding var activeDrawingTool: DrawingTool
    /// Toolbar shown above the grid when a pane is fullscreen.
    /// The parent (DashboardView) provides the content — it has
    /// access to all the chart-control state (AI, indicators,
    /// drawing tools, timeframe, chart type, etc.).
    @ViewBuilder let fullscreenToolbar: () -> FullscreenToolbar

    /// Which pane (if any) a user has expanded to fullscreen. Only one
    /// pane can be fullscreen at a time — going fullscreen hides every
    /// sibling pane (and, via `app.isChartFullscreen`, the sidebar and
    /// pair header too) so exactly one chart fills the window.
    /// Lifted to MultiChartLayoutStore so the parent DashboardView can
    /// observe it and sync toolbar controls to the pane's state. (Grid
    /// fullscreen toolbar binding fix.)
    private var fullscreenPaneID: UUID? {
        get { layoutStore.fullscreenPaneID }
        nonmutating set { layoutStore.fullscreenPaneID = newValue }
    }

    var body: some View {
        let panes = layoutStore.panes
        let layout = layoutStore.layout
        VStack(spacing: Theme.Spacing.sm) {
            // Lives above the grid itself (not in `DashboardView`'s
            // `pairHeader`, which hides in fullscreen) so it's the one
            // control that's always reachable — both to enter grid-wide
            // fullscreen and to get back out of it. Hidden while a
            // single pane is fullscreen since that pane's own header
            // already owns the exit control then.
            if fullscreenPaneID == nil {
                gridToolbar
            }
            // Fullscreen toolbar — slides in from the top when a pane
            // goes fullscreen, giving access to all single-chart tools
            // (AI, indicators, drawing, chart type, timeframe, etc.)
            if fullscreenPaneID != nil {
                fullscreenToolbar()
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(
                        Rectangle()
                            .fill(Theme.Color.surface.opacity(0.95))
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            // Fixed 2×2 grid — the same container hierarchy every time.
            // Unused slots collapse to zero frame + zero opacity instead
            // of being dropped from the tree, so no ChartPaneView is
            // ever torn down or rebuilt on a layout switch. Only
            // frame/opacity values change, which the .animation modifier
            // below handles smoothly.
            //
            // Pane-to-slot remapping per layout:
            //   twoColumn: pane 0→slot 0 (top-left), pane 1→slot 1 (top-right)
            //   twoRow:    pane 0→slot 0 (top-left), pane 1→slot 2 (bottom-left)
            //   grid2x2:   pane 0→slot 0, pane 1→slot 1, pane 2→slot 2, pane 3→slot 3
            //
            // Collapsing an unused slot to a `Color.clear` placeholder
            // isn't enough on its own — left at `maxWidth/maxHeight:
            // .infinity` (see the `paneSlot` "no pane" branch) it still
            // claims an equal share of the row/column, so `twoColumn`
            // (whole bottom row unused) only ever gave its panes the top
            // *half* of the height, and `twoRow` (whole right column
            // unused) only the left *half* of the width. Explicitly
            // collapsing the unused row/column to zero here hands that
            // reclaimed space back to the row/column that's actually in
            // use.
            //
            // When a pane is fullscreen, the row/column it lives in must
            // ALSO win the other row/column's space — not just hide the
            // sibling ChartPaneViews inside their own cells (that alone
            // still left the fullscreen pane confined to its 50%/50%
            // grid cell). `fullscreenSlot` below locates which of the
            // four cells is fullscreen (if any); `rowVisible`/
            // `columnVisible` then collapse every row/column that isn't
            // the fullscreen one, same mechanism as the unused-cell case.
            let fullscreenSlot: Int? = fullscreenPaneID.flatMap { fsID in
                (0..<4).first { slot in
                    guard let idx = paneIndex(forSlot: slot, layout: layout), idx < panes.count
                    else { return false }
                    return panes[idx].id == fsID
                }
            }
            let showsTopRow = rowVisible(0, layout: layout, fullscreenSlot: fullscreenSlot)
            let showsBottomRow = rowVisible(1, layout: layout, fullscreenSlot: fullscreenSlot)
            let showsLeftColumn = columnVisible(0, layout: layout, fullscreenSlot: fullscreenSlot)
            let showsRightColumn = columnVisible(1, layout: layout, fullscreenSlot: fullscreenSlot)
            let columnsSplit = showsLeftColumn && showsRightColumn
            VStack(spacing: (showsTopRow && showsBottomRow) ? Theme.Spacing.md : 0) {
                HStack(spacing: columnsSplit ? Theme.Spacing.md : 0) {
                    paneSlot(panes, slot: 0, layout: layout, fullscreenSlot: fullscreenSlot)
                        .frame(maxWidth: showsLeftColumn ? .infinity : 0)
                        .opacity(showsLeftColumn ? 1 : 0)
                    paneSlot(panes, slot: 1, layout: layout, fullscreenSlot: fullscreenSlot)
                        .frame(maxWidth: showsRightColumn ? .infinity : 0)
                        .opacity(showsRightColumn ? 1 : 0)
                }
                .frame(maxHeight: showsTopRow ? .infinity : 0)
                .opacity(showsTopRow ? 1 : 0)
                HStack(spacing: columnsSplit ? Theme.Spacing.md : 0) {
                    paneSlot(panes, slot: 2, layout: layout, fullscreenSlot: fullscreenSlot)
                        .frame(maxWidth: showsLeftColumn ? .infinity : 0)
                        .opacity(showsLeftColumn ? 1 : 0)
                    paneSlot(panes, slot: 3, layout: layout, fullscreenSlot: fullscreenSlot)
                        .frame(maxWidth: showsRightColumn ? .infinity : 0)
                        .opacity(showsRightColumn ? 1 : 0)
                }
                .frame(maxHeight: showsBottomRow ? .infinity : 0)
                .opacity(showsBottomRow ? 1 : 0)
            }
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Animates frame / opacity changes when the layout switches.
        // Because the view hierarchy never changes (fixed 2×2 grid),
        // SwiftUI smoothly resizes panes instead of cross-fading
        // between two entirely different container trees.
        .animation(.easeInOut(duration: 0.25), value: layoutStore.layout)
        // Animate the fullscreen toolbar slide-in/out.
        .animation(.easeInOut(duration: 0.25), value: fullscreenPaneID)
        // Keep the sidebar-collapse behavior in sync with pane
        // fullscreen the same way the primary chart's own maximise
        // button drives it (see `DashboardView.isChartFull` /
        // `RootView`).
        .onChange(of: fullscreenPaneID) { id in
            app.isChartFullscreen = id != nil
        }
        // When the chartCard's fullscreen button exits fullscreen,
        // clear the local pane fullscreen state so the grid restores.
        .onChange(of: app.isChartFullscreen) { isFull in
            if !isFull { fullscreenPaneID = nil }
        }
        // A layout change (e.g. 2×2 → 2 columns) can drop the
        // fullscreen pane entirely — always land back in the grid
        // rather than showing a stale, now-nonexistent pane.
        .onChange(of: layoutStore.layout) { _ in
            fullscreenPaneID = nil
        }
        // Sidebar symbol selection in grid mode. With `syncSymbol` on it
        // updates every pane; with it off it updates just the focused pane
        // (falling back to the first pane so a pick is never a silent
        // no-op — the original bug was that it required `syncSymbol` and so
        // did nothing in the common off-by-default case).
        .onChange(of: app.selectedPairID) { newPairID in
            guard let newPairID else { return }
            var updated = layoutStore.panes
            if layoutStore.syncSymbol {
                for i in updated.indices { updated[i].pairID = newPairID }
            } else {
                let targetID = layoutStore.focusedPaneID ?? updated.first?.id
                guard let idx = updated.firstIndex(where: { $0.id == targetID }) else { return }
                updated[idx].pairID = newPairID
            }
            layoutStore.panes = updated
        }
    }

    /// Whole-grid fullscreen toggle — distinct from a single pane's own
    /// fullscreen (`fullscreenPaneID`): this hides the sidebar and pair
    /// header while leaving every pane visible, so the full 2×2 (or
    /// 2-up) layout gets the extra room instead of just one chart.
    private var gridToolbar: some View {
        HStack {
            Spacer()
            Button {
                app.isChartFullscreen.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: app.isChartFullscreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                    Text(app.isChartFullscreen ? "Exit Fullscreen" : "Fullscreen Grid")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Theme.Color.surfaceHi))
                .overlay(Capsule().strokeBorder(Theme.Color.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(app.isChartFullscreen ? "Exit fullscreen" : "Fullscreen the whole grid")
        }
    }


    // MARK: - Pane slot (fixed grid cell)

    /// Whether grid row `row` (0 = top, 1 = bottom) should get any
    /// space. With no pane fullscreen this is just the layout's normal
    /// row usage; with a pane fullscreen, only the row it lives in gets
    /// space — the other row collapses to zero, same trick used for
    /// unused rows in a non-fullscreen layout (see the caller).
    private func rowVisible(_ row: Int, layout: ChartLayoutKind, fullscreenSlot: Int?) -> Bool {
        if let fs = fullscreenSlot { return fs / 2 == row }
        return row == 0 || layout == .twoRow || layout == .grid2x2
    }

    /// Column counterpart to `rowVisible` (0 = left, 1 = right).
    private func columnVisible(_ col: Int, layout: ChartLayoutKind, fullscreenSlot: Int?) -> Bool {
        if let fs = fullscreenSlot { return fs % 2 == col }
        return col == 0 || layout == .twoColumn || layout == .grid2x2
    }

    /// Maps a visual slot (0–3 in the 2×2 grid) to the pane index
    /// for the current layout. Returns nil when the slot is unused
    /// in the given layout (e.g. slot 1 in twoRow mode).
    private func paneIndex(forSlot slot: Int, layout: ChartLayoutKind) -> Int? {
        switch layout {
        case .single:
            return slot == 0 ? 0 : nil
        case .twoColumn:
            switch slot {
            case 0: return 0
            case 1: return 1
            default: return nil
            }
        case .twoRow:
            switch slot {
            case 0: return 0
            case 2: return 1   // pane 1 goes to bottom-left
            default: return nil
            }
        case .grid2x2:
            return slot < 4 ? slot : nil
        }
    }

    /// One cell of the fixed 2×2 grid. When the slot has no pane for
    /// the current layout, or the pane index is beyond the panes array,
    /// an empty `Color.clear` placeholder fills the slot. When a pane
    /// exists but is hidden (another pane is fullscreen, or slot is
    /// unused), it collapses to zero size but stays mounted.
    @ViewBuilder
    private func paneSlot(_ panes: [ChartPane], slot: Int, layout: ChartLayoutKind, fullscreenSlot: Int?) -> some View {
        if let idx = paneIndex(forSlot: slot, layout: layout), idx < panes.count {
            let p = panes[idx]
            let isFullscreenSibling = fullscreenPaneID != nil && fullscreenPaneID != p.id
            let isHidden = isFullscreenSibling
            let isThisPaneFullscreen = fullscreenSlot == slot
            // The focused pane is the sidebar's symbol-change target while
            // syncSymbol is off. Fall back to the first pane so a ring is
            // always shown (and a sidebar pick always lands somewhere).
            let effectiveFocusID = layoutStore.focusedPaneID ?? panes.first?.id
            let isFocused = effectiveFocusID == p.id
            // Only surface the focus affordance when it's meaningful:
            // multiple panes, none fullscreen, and symbols aren't synced
            // (when synced every pane changes together, so "which one" is
            // moot).
            let showsFocusRing = isFocused
                && layout != .single
                && fullscreenPaneID == nil
                && !layoutStore.syncSymbol
                && panes.count > 1
            ChartPaneView(
                pane: p,
                indicatorConfig: indicatorConfig,
                drawingStore: drawingStore,
                isFullscreen: Binding(
                    get: { fullscreenPaneID == p.id },
                    set: { fullscreenPaneID = $0 ? p.id : nil }
                ),
                // .twoRow / .grid2x2 stack two full pane rows, needing
                // roughly double the vertical budget of a single row —
                // trim each pane's minimums so both rows actually fit
                // the window (see `ChartPaneView.isCompact`). Doesn't
                // apply once this pane is fullscreen — it then owns the
                // whole grid area, same room a `.single`-layout pane has.
                isCompact: !isThisPaneFullscreen && (layout == .twoRow || layout == .grid2x2),
                // Pauses this pane's tick-driven candle refresh while
                // it's collapsed behind a fullscreen sibling — see
                // `ChartPaneView.isVisible`.
                isVisible: !isHidden,
                fullscreenDrawingTool: $activeDrawingTool,
                // Clicking anywhere in the pane makes it the sidebar's
                // symbol-change target. Also sync the sidebar highlight to
                // this pane's current pair so the selection reads as
                // "editing this chart".
                onFocus: {
                    layoutStore.focusedPaneID = p.id
                    if app.selectedPairID != p.pairID { app.selectedPairID = p.pairID }
                }
            ) { updated in
                layoutStore.updatePane(updated)
            }
            .frame(maxWidth: isHidden ? 0 : .infinity, maxHeight: isHidden ? 0 : .infinity)
            .opacity(isHidden ? 0 : 1)
            .allowsHitTesting(!isHidden)
            .clipped()
            // Focus ring — marks which pane a sidebar symbol pick will
            // change while symbols aren't synced.
            .overlay {
                if showsFocusRing {
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .strokeBorder(Theme.accentGradient, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
