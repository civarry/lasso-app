import AppKit
import SwiftUI

// MARK: - Design tokens

/// The single source of truth for Settings layout. Every row, card and control in the Intelligence
/// panel measures itself from here, so a spacing or width change is one edit, not one per section.
enum SettingsMetrics {
    /// Row padding, matching a native grouped-inset list.
    static let rowPaddingH: CGFloat = 16
    static let rowPaddingV: CGFloat = 14
    /// Minimum gap between a row's label half and its control half.
    static let columnGap: CGFloat = 16
    /// Width of a text input. Everything else in a row is sized by its content.
    static let fieldWidth: CGFloat = 240
    /// Standard macOS control height (pop-up button, text field, small switch).
    static let controlHeight: CGFloat = 22
    static let sectionSpacing: CGFloat = 26
    static let cardRadius: CGFloat = 10
    static let pagePadding: CGFloat = 22
}

/// Page and card colours for the grouped-inset look.
///
/// `NSColor.controlBackgroundColor` is the obvious choice for a card and the wrong one: measured, it
/// resolves to *exactly* `windowBackgroundColor` in both appearances (#1E1E1E dark, #FFFFFF light), so
/// a card painted with it is invisible against the page. A native grouped list separates the two, so
/// we do it explicitly: lift the card in dark (where the page is already near-black), and drop the
/// page in light (where the card can't get lighter than white).
enum SettingsPalette {
    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// Behind the cards. Dark keeps the window colour; light drops to a grey so white cards read.
    static let pageFill = dynamic(dark: .windowBackgroundColor, light: NSColor(white: 0.95, alpha: 1))

    /// The card itself: a 6% lift in dark, plain white in light.
    static let cardFill = dynamic(dark: NSColor.white.withAlphaComponent(0.06), light: .white)

    static let cardBorder = dynamic(dark: NSColor.white.withAlphaComponent(0.09),
                                    light: NSColor.black.withAlphaComponent(0.10))
}

/// Three ranks of type, so a section header, a row label and a helper line are never confusable.
enum SettingsFont {
    static let sectionHeader = Font.system(size: 13, weight: .semibold)
    static let label = Font.system(size: 13)
    static let sub = Font.system(size: 11)
}

// MARK: - Card

/// A grouped inset card: a section header above the box, hairline-separated rows inside it, and an
/// optional footnote below. The box clips its content, so the last row's separator lands on the
/// border and disappears — the rows own their padding, not the card.
struct SettingsCard<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                Text(title)
                    .font(SettingsFont.sectionHeader)
                    .foregroundStyle(.primary)
                    .padding(.leading, 2)
            }

            VStack(spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SettingsPalette.cardFill)
                .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                        .strokeBorder(SettingsPalette.cardBorder, lineWidth: 1))

            if let footnote, !footnote.isEmpty {
                Text(footnote)
                    .font(SettingsFont.sub)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
        }
    }
}

// MARK: - Row

/// One row of a card, laid out **space-between**: the label is pinned to the leading edge and the
/// control to the trailing edge. The control is sized by its own content and takes layout priority;
/// the label half absorbs whatever slack is left. So controls vary in width — a pop-up button is as
/// wide as its widest option, a text field as wide as `SettingsMetrics.fieldWidth` — but every one of
/// them ends on the container's right edge, which is the alignment the eye actually reads. The
/// optional sub-label sits directly under the label, where explanatory text belongs.
struct SettingsRow<Control: View>: View {
    private let label: String
    private let symbol: String?
    private let caption: String?
    private let control: Control

    init(_ label: String, symbol: String? = nil, caption: String? = nil,
         @ViewBuilder control: () -> Control) {
        self.label = label
        self.symbol = symbol
        self.caption = caption
        self.control = control()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: SettingsMetrics.columnGap) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let symbol {
                            Image(systemName: symbol).foregroundStyle(.secondary)
                        }
                        Text(label)
                            .font(SettingsFont.label)
                            .foregroundStyle(.primary)
                    }
                    if let caption, !caption.isEmpty {
                        Text(caption)
                            .font(SettingsFont.sub)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) { control }
                    .layoutPriority(1)
            }
            .padding(.horizontal, SettingsMetrics.rowPaddingH)
            .padding(.vertical, SettingsMetrics.rowPaddingV)
            .frame(minHeight: SettingsMetrics.controlHeight)

            Divider()
        }
    }
}

extension View {
    /// Width for a **text input**, which is the one control that can't size to its content — an empty
    /// field would collapse to nothing. Pop-up buttons, menus, switches and buttons take no width
    /// modifier at all: they hug, and the row parks them on the trailing edge.
    func settingsFieldWidth() -> some View { frame(width: SettingsMetrics.fieldWidth) }

    /// A pop-up whose label can be long (a model id): hugs its content up to the field width, then
    /// truncates, parked on the trailing edge. A plain `.fixedSize()` let a 58-character MLX model id
    /// make the form 561pt wide in a 520pt window, pushing it past the left edge.
    func settingsCappedMenu() -> some View {
        ViewThatFits(in: .horizontal) {
            fixedSize()
            frame(width: SettingsMetrics.fieldWidth)
        }
        .frame(maxWidth: SettingsMetrics.fieldWidth, alignment: .trailing)
    }
}

/// The panel's one switch control: an optional trailing caption next to the switch, sized to its
/// content so the row's control half right-aligns it.
struct SettingsSwitch: View {
    let title: String
    @Binding var isOn: Bool
    var info: String?

    @State private var showInfo = false

    var body: some View {
        HStack(spacing: 10) {
            if !title.isEmpty {
                Text(title).font(SettingsFont.sub).foregroundStyle(.secondary)
            }
            if let info {
                Button { showInfo.toggle() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                        Text(info)
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(width: 250).padding(12)
                    }
            }
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// A dot + short phrase, for a state that is checked rather than set (connection reachability).
struct SettingsStatusChip: View {
    let text: String
    let tint: Color
    var busy = false

    var body: some View {
        HStack(spacing: 6) {
            if busy {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(tint).frame(width: 7, height: 7)
            }
            Text(text).font(SettingsFont.sub).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
        }
    }
}

// MARK: - Secret fields

/// The one control for a persisted secret: a masked field that can be revealed, edited in place, or
/// cleared for replacement. Used for every stored key in the app, so no saved value is a dead end.
struct SettingsKeyField: View {
    @Binding var text: String
    var placeholder: String = ""
    /// When set, a ⋯ menu offers Replace / Clear. Omit for a field that has nothing persisted yet.
    var onClear: (() -> Void)?

    @State private var revealed = false

    var body: some View {
        HStack(spacing: 6) {
            // SwiftUI's SecureField (NSSecureTextField under the hood) ignores alignment and scrolls
            // to the caret, so a long key showed its clipped tail floating to the right. We back the
            // field with AppKit instead (`KeyTextField`) for guaranteed left-aligned, fill-width
            // behaviour, and draw our own rounded box so secure/plain look pixel-identical. The
            // `.id(revealed)` forces the NSView to be rebuilt as the secure vs. plain class on toggle.
            KeyTextField(text: $text, placeholder: placeholder, isSecure: !revealed)
                .frame(maxWidth: .infinity)
                .id(revealed)
                .padding(.horizontal, 8)
                .frame(height: SettingsMetrics.controlHeight)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))

            Button { revealed.toggle() } label: {
                Image(systemName: revealed ? "eye.slash" : "eye").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(revealed ? "Hide key" : "Show key")

            if let onClear {
                Menu {
                    Button(revealed ? "Hide" : "Reveal") { revealed.toggle() }
                    Button("Replace…") { revealed = true; onClear() }
                    Divider()
                    Button("Clear", role: .destructive) { revealed = false; onClear() }
                } label: {
                    Image(systemName: "ellipsis").font(.caption2).foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("View, replace, or clear this key")
            }
        }
    }
}

/// Labelled wrapper for the panels outside the model-section grid (Connectors).
struct SecureKeyField: View {
    let title: String
    @Binding var text: String

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    var body: some View {
        SettingsKeyField(text: $text, placeholder: title)
    }
}

/// AppKit-backed single-line key field. SwiftUI's `SecureField` won't reliably left-align or fill
/// width on macOS, so we wrap `NSTextField`/`NSSecureTextField` directly: borderless and transparent
/// (the SwiftUI parent draws the box), left-aligned, and low hugging priority so it fills the slot.
struct KeyTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isSecure: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSTextField {
        let field = isSecure ? NSSecureTextField() : NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .left
        field.lineBreakMode = .byClipping
        field.usesSingleLineMode = true
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = context.coordinator
        // Fill the available width instead of hugging the typed content.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
