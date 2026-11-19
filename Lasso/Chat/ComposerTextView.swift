import AppKit
import SwiftUI

/// What dictation needs from the message box: read it, find the caret, and replace a span of it.
/// The real box is an `NSTextView`; when the chat panel isn't open (and in tests) a plain string
/// stands in, backed by `ChatController.shared.input`.
@MainActor
protocol ComposerEditing: AnyObject {
    var text: String { get }
    /// Caret or selection, in UTF-16 units.
    var selectedRange: NSRange { get }
    /// Replace `range` and put the caret at `caret` (default: the end of the new text). Undoable edits
    /// are Cmd-Z steps; dictation's live updates aren't, only the cleanup swap is.
    func replace(_ range: NSRange, with string: String, caret: Int?, undoable: Bool)
    /// Grey out the recognizer's unconfirmed words, or clear that styling with nil.
    func markVolatile(_ range: NSRange?)
    /// A dictation is starting: forget undo history (live edits aren't recorded, so older steps would
    /// point at the wrong places in the text) and follow the newest word again.
    func beginDictation()
}

@MainActor
enum Composer {
    /// The panel's text view while it's on screen.
    static weak var textView: ComposerNSTextView?

    static var current: ComposerEditing { textView ?? StringComposer.shared }
}

/// The box as a plain string, for when no text view exists.
@MainActor
final class StringComposer: ComposerEditing {
    static let shared = StringComposer()
    /// Nil means the end of the text.
    var caret: Int?

    var text: String { ChatController.shared.input }
    var selectedRange: NSRange {
        let length = text.utf16.count
        return NSRange(location: min(caret ?? length, length), length: 0)
    }

    func replace(_ range: NSRange, with string: String, caret: Int?, undoable: Bool) {
        let ns = text as NSString
        guard NSMaxRange(range) <= ns.length else { return }
        ChatController.shared.input = ns.replacingCharacters(in: range, with: string)
        self.caret = caret ?? range.location + string.utf16.count
    }

    func markVolatile(_ range: NSRange?) {}
    func beginDictation() {}
}

/// The chat message box: grows with its text up to `maxLines`, then scrolls. Return sends;
/// Shift- or Option-Return adds a line. While dictating it keeps the newest word in view.
struct ComposerTextView: NSViewRepresentable {
    enum Key { case submit, up, down, tab, escape }

    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var height: CGFloat
    var placeholder: String
    /// Return true when the key was handled; false lets the text view do its default.
    var onKey: (Key) -> Bool

    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let maxLines: CGFloat = 6
    static var lineHeight: CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: font)) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false

        let view = ComposerNSTextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.drawsBackground = false
        view.font = Self.font
        view.textColor = .labelColor
        view.typingAttributes = [.font: Self.font, .foregroundColor: NSColor.labelColor]
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.string = text
        view.placeholder = placeholder
        scroll.documentView = view
        Composer.textView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ComposerNSTextView else { return }
        Composer.textView = view
        if view.placeholder != placeholder { view.placeholder = placeholder; view.needsDisplay = true }
        // Text set from outside (send clears it, editing a message fills it): show it, caret at the end.
        if view.string != text, !view.hasMarkedText() {
            view.setTextFromModel(text)
        }
        if isFocused, view.window != nil, view.window?.firstResponder !== view {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
        context.coordinator.updateHeight(view)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        let undo = UndoManager()

        init(_ parent: ComposerTextView) { self.parent = parent }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? ComposerNSTextView else { return }
            if parent.text != view.string { parent.text = view.string }
            updateHeight(view)
        }

        func textView(_ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            if let view = view as? ComposerNSTextView, !view.isProgrammatic {
                VoiceInputController.shared.composerEdited(range, replacementLength: replacementString?.utf16.count ?? 0)
            }
            return true
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) || flags.contains(.option) {
                    view.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                return parent.onKey(.submit)
            case #selector(NSResponder.moveUp(_:)): return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.onKey(.down)
            case #selector(NSResponder.insertTab(_:)): return parent.onKey(.tab)
            case #selector(NSResponder.cancelOperation(_:)):
                // Unused Esc goes to the panel, as it did from the old text field. NSTextView's own
                // Esc opens the autocomplete list.
                if parent.onKey(.escape) { return true }
                view.nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)
                return true
            default: return false
            }
        }

        func focusChanged(_ focused: Bool) {
            if parent.isFocused != focused { parent.isFocused = focused }
        }

        /// One line tall when empty, growing to `maxLines`, then the box scrolls.
        func updateHeight(_ view: NSTextView) {
            guard let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let line = ComposerTextView.lineHeight
            let used = ceil(layout.usedRect(for: container).height)
            let target = min(max(used, line), line * ComposerTextView.maxLines)
            if abs(target - parent.height) > 0.5 {
                DispatchQueue.main.async { [parent] in parent.height = target }
            }
        }
    }
}

/// The text view behind the message box. Also the `ComposerEditing` dictation writes through.
final class ComposerNSTextView: NSTextView, ComposerEditing {
    weak var coordinator: ComposerTextView.Coordinator?
    var placeholder = ""
    /// True while code (not the person typing) is changing the text.
    private(set) var isProgrammatic = false
    /// The person scrolled up to reread during dictation; stop following the newest word until they
    /// scroll back to the end or the next dictation starts.
    private var scrolledAway = false

    var text: String { string }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { coordinator?.focusChanged(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { coordinator?.focusChanged(false) }
        return resigned
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        (placeholder as NSString).draw(at: textContainerOrigin, withAttributes: [
            .font: ComposerTextView.font, .foregroundColor: NSColor.placeholderTextColor,
        ])
    }

    func setTextFromModel(_ text: String) {
        isProgrammatic = true
        string = text
        isProgrammatic = false
        coordinator?.undo.removeAllActions()
        setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        needsDisplay = true
    }

    func replace(_ range: NSRange, with replacement: String, caret: Int?, undoable: Bool) {
        guard let storage = textStorage, NSMaxRange(range) <= storage.length else { return }
        isProgrammatic = true
        defer { isProgrammatic = false }
        if undoable {
            guard shouldChangeText(in: range, replacementString: replacement) else { return }
            storage.replaceCharacters(in: range, with: replacement)
            storage.addAttributes(typingAttributes, range: NSRange(location: range.location, length: replacement.utf16.count))
            didChangeText()
        } else {
            storage.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: typingAttributes))
            // Not through shouldChangeText/didChangeText (that would record an undo step), so tell
            // SwiftUI ourselves.
            ChatController.shared.input = string
            coordinator?.updateHeight(self)
        }
        let end = caret ?? range.location + replacement.utf16.count
        setSelectedRange(NSRange(location: min(end, storage.length), length: 0))
        followCaret()
        needsDisplay = true
    }

    func markVolatile(_ range: NSRange?) {
        guard let storage = textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: all)
        if let range, NSMaxRange(range) <= storage.length, range.length > 0 {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        }
    }

    func beginDictation() {
        coordinator?.undo.removeAllActions()
        scrolledAway = false
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        guard let clip = enclosingScrollView?.contentView else { return }
        scrolledAway = clip.documentVisibleRect.maxY < bounds.maxY - 2
    }

    /// Keep the line with the caret (the newest dictated word) visible, after layout has settled.
    private func followCaret() {
        guard !scrolledAway, let layout = layoutManager, let container = textContainer else { return }
        layout.ensureLayout(for: container)
        scrollRangeToVisible(selectedRange())
    }
}
