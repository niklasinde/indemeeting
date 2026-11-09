import AppKit
import SwiftUI

/// A growing text field where Return sends and Shift+Return starts a new line.
struct ChatComposer: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let placeholder: String
    let send: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PlaceholderTextView()
        textView.placeholder = placeholder
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        context.coordinator.textView = textView
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text { textView.string = text }
        context.coordinator.updateHeight()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposer
        weak var textView: NSTextView?

        init(_ parent: ChatComposer) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            parent.text = textView?.string ?? ""
            updateHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.send()
            }
            return true
        }

        func updateHeight() {
            guard let textView, let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let height = min(max(layout.usedRect(for: container).height + 8, 26), 140)
            guard abs(parent.height - height) > 0.5 else { return }
            DispatchQueue.main.async { self.parent.height = height }
        }
    }
}

private final class PlaceholderTextView: NSTextView {
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor]
        placeholder.draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height),
                         withAttributes: attributes)
    }

    override var string: String {
        didSet { needsDisplay = true }
    }
}
