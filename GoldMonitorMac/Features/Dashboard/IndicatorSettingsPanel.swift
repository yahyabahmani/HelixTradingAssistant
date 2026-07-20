import SwiftUI

/// Floating, draggable settings panel for a single indicator instance.
/// Applies changes in real-time so the user can see the effect on the
/// chart while dragging the panel out of the way.
struct IndicatorSettingsPanel: View {
    @Binding var instance: IndicatorInstance
    let onUpdate: (IndicatorInstance) -> Void
    let onClose: () -> Void

    @State private var floatOffset: CGSize = .zero
    @State private var floatOrigin: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            header
            Divider().background(Theme.Color.border)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    paramsContent
                }
            }
            .frame(maxHeight: 320)
            resetFooter
        }
        .padding(Theme.Spacing.md)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.Color.surfaceHi)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.Color.border, lineWidth: 1)
        )
        .offset(floatOffset)
    }

    /// "Reset to defaults" affordance, shown only when the indicator has
    /// tunable parameters to reset. Resets every param to its spec default
    /// and pushes the change live like any other edit.
    @ViewBuilder
    private var resetFooter: some View {
        if !instance.kind.paramSpecs.isEmpty {
            Divider().background(Theme.Color.border)
            HStack {
                Button("Reset to defaults") { resetToDefaults() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Color.textSecondary)
                Spacer()
            }
        }
    }

    private func resetToDefaults() {
        var copy = instance
        for spec in instance.kind.paramSpecs {
            copy.params[spec.key] = spec.defaultValue
        }
        instance = copy
        onUpdate(copy)
    }

    private var panelDragGesture: some Gesture {
        DragGesture()
            .onChanged { floatOffset = CGSize(
                width: floatOrigin.width + $0.translation.width,
                height: floatOrigin.height + $0.translation.height
            )}
            .onEnded { _ in floatOrigin = floatOffset }
    }

    private var header: some View {
        HStack {
            Circle().fill(instance.kind.color).frame(width: 8, height: 8)
            Text(instance.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
            Spacer()
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.Color.surface))
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .gesture(panelDragGesture)
    }

    @ViewBuilder
    private var paramsContent: some View {
        let specs = instance.kind.paramSpecs
        if specs.isEmpty {
            Text("No tunable parameters")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
        }
        ForEach(specs, id: \.key) { spec in
            switch spec {
            case .double(let key, let label, let def, let step, let range):
                doubleRow(key: key, label: label, def: def, step: step, range: range)
            case .bool(let key, let label, let def):
                boolRow(key: key, label: label, def: def)
            case .enum(let key, let label, let def, let options):
                enumRow(key: key, label: label, def: def, options: options)
            }
        }
    }

    private func doubleRow(key: String, label: String, def: Double, step: Double, range: ClosedRange<Double>) -> some View {
        let binding = Binding<Double>(
            get: { instance.params[key]?.doubleValue ?? def },
            set: {
                var copy = instance
                copy.params[key] = .double($0)
                instance = copy
                onUpdate(copy)
            }
        )
        return HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
            Text(String(format: step >= 1 ? "%.0f" : "%.1f", binding.wrappedValue))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.Color.textPrimary)
                .frame(minWidth: 30, alignment: .trailing)
            Stepper("", value: binding, in: range, step: step)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    private func boolRow(key: String, label: String, def: Bool) -> some View {
        let binding = Binding<Bool>(
            get: { instance.params[key]?.boolValue ?? def },
            set: {
                var copy = instance
                copy.params[key] = .bool($0)
                instance = copy
                onUpdate(copy)
            }
        )
        return Toggle(isOn: binding) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textSecondary)
        }
        #if os(iOS)
        .toggleStyle(.switch)
        #else
        .toggleStyle(.checkbox)
        #endif
    }

    private func enumRow(key: String, label: String, def: String, options: [ParamOption]) -> some View {
        let binding = Binding<String>(
            get: { instance.params[key]?.stringValue ?? def },
            set: {
                var copy = instance
                copy.params[key] = .string($0)
                instance = copy
                onUpdate(copy)
            }
        )
        return HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
            Picker("", selection: binding) {
                ForEach(options, id: \.value) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// Same panel for oscillator instances.
struct OscillatorSettingsPanel: View {
    @Binding var instance: OscillatorInstance
    let onUpdate: (OscillatorInstance) -> Void
    let onClose: () -> Void

    @State private var floatOffset: CGSize = .zero
    @State private var floatOrigin: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text(instance.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.Color.surface))
                }
                .buttonStyle(.plain)
            }
            Divider().background(Theme.Color.border)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    paramsContent
                }
            }
            .frame(maxHeight: 320)
            resetFooter
        }
        .padding(Theme.Spacing.md)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.Color.surfaceHi)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.Color.border, lineWidth: 1)
        )
        .offset(floatOffset)
        .gesture(
            DragGesture()
                .onChanged { floatOffset = CGSize(
                    width: floatOrigin.width + $0.translation.width,
                    height: floatOrigin.height + $0.translation.height
                )}
                .onEnded { _ in floatOrigin = floatOffset }
        )
    }

    /// "Reset to defaults" affordance, shown only when the oscillator has
    /// tunable parameters to reset. Resets every param to its spec default
    /// and pushes the change live like any other edit.
    @ViewBuilder
    private var resetFooter: some View {
        if !instance.kind.paramSpecs.isEmpty {
            Divider().background(Theme.Color.border)
            HStack {
                Button("Reset to defaults") { resetToDefaults() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Color.textSecondary)
                Spacer()
            }
        }
    }

    private func resetToDefaults() {
        var copy = instance
        for spec in instance.kind.paramSpecs {
            copy.params[spec.key] = spec.defaultValue
        }
        instance = copy
        onUpdate(copy)
    }

    @ViewBuilder
    private var paramsContent: some View {
        let specs = instance.kind.paramSpecs
        if specs.isEmpty {
            Text("No tunable parameters")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
        }
        ForEach(specs, id: \.key) { spec in
            switch spec {
            case .double(let key, let label, let def, let step, let range):
                doubleRow(key: key, label: label, def: def, step: step, range: range)
            case .bool(let key, let label, let def):
                boolRow(key: key, label: label, def: def)
            case .enum(let key, let label, let def, let options):
                enumRow(key: key, label: label, def: def, options: options)
            }
        }
    }

    private func doubleRow(key: String, label: String, def: Double, step: Double, range: ClosedRange<Double>) -> some View {
        let binding = Binding<Double>(
            get: { instance.params[key]?.doubleValue ?? def },
            set: {
                var copy = instance
                copy.params[key] = .double($0)
                instance = copy
                onUpdate(copy)
            }
        )
        return HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
            Text(String(format: step >= 1 ? "%.0f" : "%.1f", binding.wrappedValue))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.Color.textPrimary)
                .frame(minWidth: 30, alignment: .trailing)
            Stepper("", value: binding, in: range, step: step)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    private func boolRow(key: String, label: String, def: Bool) -> some View {
        let binding = Binding<Bool>(
            get: { instance.params[key]?.boolValue ?? def },
            set: {
                var copy = instance
                copy.params[key] = .bool($0)
                instance = copy
                onUpdate(copy)
            }
        )
        return Toggle(isOn: binding) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textSecondary)
        }
        #if os(iOS)
        .toggleStyle(.switch)
        #else
        .toggleStyle(.checkbox)
        #endif
    }

    private func enumRow(key: String, label: String, def: String, options: [ParamOption]) -> some View {
        let binding = Binding<String>(
            get: { instance.params[key]?.stringValue ?? def },
            set: {
                var copy = instance
                copy.params[key] = .string($0)
                instance = copy
                onUpdate(copy)
            }
        )
        return HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
            Picker("", selection: binding) {
                ForEach(options, id: \.value) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }
}
