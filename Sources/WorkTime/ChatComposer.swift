import AppKit
import SwiftUI

/// A text field that grows with its text up to `maxLines`, then scrolls. Return sends and Shift+Return starts a new line.
struct ChatComposer: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let placeholder: String
    var maxLines = 6
    let send: () -> Void

    static let inset = NSSize(width: 0, height: 4)

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
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainerInset = Self.inset
        textView.textContainer?.widthTracksTextView = true
        let scroll = ComposerScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.onWidthChange = { [weak coordinator = context.coordinator] in coordinator?.updateHeight() }
        context.coordinator.textView = textView
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        let replaced = textView.string != text
        if replaced { textView.string = text }
        context.coordinator.updateHeight(reveal: replaced ? .top : nil)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposer
        weak var textView: NSTextView?

        init(_ parent: ChatComposer) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            parent.text = textView?.string ?? ""
            updateHeight(reveal: .caret)
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

        enum Reveal { case top, caret }

        /// The text's height at the field's current width, between one line and `maxLines`. Text put in from outside, like a
        /// pre-filled prompt, is shown from its first line; typing keeps the caret in view.
        func updateHeight(reveal target: Reveal? = nil) {
            guard let textView, let container = textView.textContainer, let layout = textView.layoutManager,
                  let font = textView.font, textView.bounds.width > 0 else { return }
            layout.ensureLayout(for: container)
            let line = layout.defaultLineHeight(for: font)
            let padding = ChatComposer.inset.height * 2
            let height = ceil(min(max(layout.usedRect(for: container).height, line), line * CGFloat(parent.maxLines)) + padding)
            let reveal = {
                switch target {
                case .top: textView.scroll(.zero)
                case .caret: textView.scrollRangeToVisible(textView.selectedRange())
                case nil: break
                }
            }
            guard abs(parent.height - height) > 0.5 else { return reveal() }
            DispatchQueue.main.async {
                self.parent.height = height
                reveal()
            }
        }
    }
}

/// Tells the composer when its width changes, since the wrapped text's height depends on it.
private final class ComposerScrollView: NSScrollView {
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override func tile() {
        super.tile()
        guard abs(contentSize.width - lastWidth) > 0.5 else { return }
        lastWidth = contentSize.width
        documentView?.frame.size.width = contentSize.width
        onWidthChange?()
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
