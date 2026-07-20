import SwiftUI

/// Floating inspector for a single selected drawing. Sits as a chart
/// overlay (top-trailing in DashboardView) and lets the user retune
/// the drawing's colour, alpha, and line width — or delete it.
///
/// All edits go through `onChange` with the same `id`, so the store's
/// `update(_:for:)` replaces in place. The dashboard owns the
/// selection / store; this view is stateless beyond the drawing it's
/// handed.
struct DrawingInspector: View {
    /// The drawing being edited. Re-renders on each tweak so SwiftUI's
    /// `ColorPicker` binding round-trips through the store rather than
    /// keeping local state out of sync.
    let drawing: ChartDrawing

    /// Called with the modified drawing (same id, mutated fields).
    let onChange: (ChartDrawing) -> Void

    /// Called when the user clicks the trash. Dashboard removes the
    /// drawing and clears its selection state.
    let onDelete: () -> Void

    /// Closes the inspector without deleting the drawing. Same effect
    /// as clicking empty chart space.
    let onDismiss: () -> Void

    // Local edit buffers for the numeric fields. Binding the TextFields
    // straight at the model would round-trip every keystroke through
    // the store, and a rejected intermediate value (an empty field
    // mid-retype) would immediately snap the text back — making the
    // field impossible to clear. Drafts decouple what's on screen from
    // what's committed.
    @State private var balanceDraft: String = ""
    @State private var riskDraft: String = ""

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            kindBadge

            colorWell

            // Line width — only meaningful for line-style drawings;
            // the rectangle's border width follows the same field so
            // the inspector stays uniform.
            HStack(spacing: 6) {
                Image(systemName: "lineweight")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Color.textMuted)
                Slider(value: lineWidthBinding, in: 1...5, step: 0.5)
                    .frame(width: 90)
                Text(String(format: "%.1f", drawing.lineWidth))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 24, alignment: .trailing)
            }

            // Risk inputs — only positions size against an account, so
            // these stay hidden for every other shape rather than
            // showing dead fields.
            if drawing.kind.isPosition {
                Divider()
                    .frame(height: 18)
                riskFields
            }

            Divider()
                .frame(height: 18)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Color.danger)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.Color.danger.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .help("Delete drawing")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Color.surfaceMax.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(Theme.Color.border, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }

    // MARK: - Bits

    /// Tag chip showing what kind of drawing this is. Provides
    /// minimal context so the inspector doesn't read as a floating
    /// orphan UI.
    private var kindBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: kindIcon)
                .font(.system(size: 10, weight: .semibold))
            Text(kindLabel)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(Theme.Color.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Theme.Color.surface)
        )
    }

    private var kindIcon: String {
        switch drawing.kind {
        case .horizontalLine: return "minus"
        case .trendLine:      return "line.diagonal"
        case .rectangle:      return "rectangle"
        case .volumeProfile:  return "chart.bar.xaxis.ascending"
        case .longPosition:   return "arrow.up.right.square"
        case .shortPosition:  return "arrow.down.right.square"
        }
    }

    private var kindLabel: String {
        switch drawing.kind {
        case .horizontalLine: return "Horizontal"
        case .trendLine:      return "Trend line"
        case .rectangle:      return "Rectangle"
        case .volumeProfile:  return "Vol Profile"
        case .longPosition:   return "Long"
        case .shortPosition:  return "Short"
        }
    }

    /// SwiftUI ColorPicker bound to the drawing's stored colour. We
    /// allow opacity (the "alpha" half of requirement #4) so a single
    /// picker covers both colour and alpha. Round-tripped through
    /// `ColorRGBA(_:)` which extracts components via NSColor's sRGB
    /// space.
    private var colorWell: some View {
        ColorPicker(
            "Color",
            selection: Binding<Color>(
                get: { drawing.color.color },
                set: { newColor in
                    var copy = drawing
                    copy.color = ColorRGBA(newColor)
                    onChange(copy)
                }
            ),
            supportsOpacity: true
        )
        .labelsHidden()
        .help("Stroke color · also drives fill opacity")
    }

    /// Account balance + risk % for a position drawing. Each position
    /// carries its own pair so several scenarios can share a chart
    /// without one edit rewriting them all.
    @ViewBuilder
    private var riskFields: some View {
        HStack(spacing: 6) {
            Image(systemName: "dollarsign.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Color.textMuted)
            TextField("Balance", text: $balanceDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.Color.textPrimary)
                .frame(width: 62)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(Theme.Color.surface)
                )
                .help("Account balance this position sizes against")

            TextField("Risk", text: $riskDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.Color.textPrimary)
                .frame(width: 34)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(Theme.Color.surface)
                )
                .help("Percent of balance risked if the stop fills")
            Text("%")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.Color.textMuted)
        }
        .onAppear { syncDrafts() }
        // Only re-seed when the inspector switches drawings. Syncing on
        // every drawing change would fight the user's typing, since each
        // committed keystroke hands back a new drawing value.
        .onChange(of: drawing.id) { _ in syncDrafts() }
        .onChange(of: balanceDraft) { commitBalance($0) }
        .onChange(of: riskDraft) { commitRisk($0) }
    }

    /// Reset the drafts from the drawing. Called when the inspector
    /// first appears and whenever it switches to a different drawing —
    /// but never while the user is mid-edit on the same one, which is
    /// what lets the field sit empty between clearing and retyping.
    private func syncDrafts() {
        balanceDraft = drawing.accountBalance.map { String(format: "%.0f", $0) } ?? ""
        riskDraft    = drawing.riskPercent.map { Self.trim($0) } ?? ""
    }

    /// Commit a draft only when it parses to a positive number. An
    /// empty field or a lone "-" is a legitimate intermediate state
    /// while typing, so it leaves the stored setting untouched rather
    /// than writing a zero that would blank the metrics.
    private func commitBalance(_ raw: String) {
        guard let v = Double(raw.replacingOccurrences(of: ",", with: ".")), v > 0,
              v != drawing.accountBalance
        else { return }
        var copy = drawing
        copy.accountBalance = v
        onChange(copy)
    }

    private func commitRisk(_ raw: String) {
        guard let v = Double(raw.replacingOccurrences(of: ",", with: ".")), v > 0,
              v != drawing.riskPercent
        else { return }
        var copy = drawing
        copy.riskPercent = v
        onChange(copy)
    }

    /// "1" not "1.0", "1.5" stays "1.5" — `%g` without the exponent
    /// surprises `%.2g` produces for values like 0.25.
    private static func trim(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(v)
    }

    /// Slider binding for the line width. Goes through the same
    /// `onChange` callback so the chart re-renders immediately.
    private var lineWidthBinding: Binding<Double> {
        Binding<Double>(
            get: { drawing.lineWidth },
            set: { newWidth in
                var copy = drawing
                copy.lineWidth = newWidth
                onChange(copy)
            }
        )
    }
}
