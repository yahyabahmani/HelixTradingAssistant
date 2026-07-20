import SwiftUI
import AppKit

/// Modifier that deletes the selected drawing when the user presses
/// Backspace (keyCode 51) or Forward Delete (keyCode 117).
///
/// Follows the same `NSEvent.addLocalMonitorForEvents` pattern as
/// `ScrollZoomModifier` — a window-level key-down monitor that
/// checks whether a drawing is selected and, if so, removes it
/// from the store and clears the selection. Events are consumed
/// so the system doesn't beep.
struct DrawingDeleteKeyHandler: ViewModifier {
    @Binding var selectedDrawingID: UUID?
    let drawingStore: DrawingStore
    let pairID: String

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear { installMonitor() }
            .onDisappear { removeMonitor() }
    }

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Backspace (Delete) = 51, Forward Delete = 117
            guard event.keyCode == 51 || event.keyCode == 117 else {
                return event
            }
            // Text entry wins. The drawing inspector has editable
            // balance / risk fields, and a selected drawing would
            // otherwise be deleted the moment the user backspaces to
            // clear one — the keystroke never reaching the field.
            guard !Self.isEditingText else { return event }
            guard let id = selectedDrawingID else { return event }
            drawingStore.remove(id: id, for: pairID)
            selectedDrawingID = nil
            return nil // consumed
        }
    }

    /// Is the keyboard currently inside a text editor?
    ///
    /// A focused `NSTextField` hands first-responder status to the
    /// window's shared *field editor* (an `NSTextView`), so checking for
    /// the text field itself isn't enough — the field editor is what
    /// actually holds focus while typing. Popovers get their own window,
    /// which is why this reads `keyWindow` rather than `mainWindow`.
    private static var isEditingText: Bool {
        guard let responder = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder
        else { return false }
        if let textView = responder as? NSTextView {
            return textView.isFieldEditor || textView.isEditable
        }
        return responder is NSTextField
    }

    private func removeMonitor() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}

extension View {
    /// Delete the selected drawing on Backspace/Forward-Delete key press.
    func drawingDeleteKey(
        selectedDrawingID: Binding<UUID?>,
        drawingStore: DrawingStore,
        pairID: String
    ) -> some View {
        modifier(DrawingDeleteKeyHandler(
            selectedDrawingID: selectedDrawingID,
            drawingStore: drawingStore,
            pairID: pairID
        ))
    }
}
