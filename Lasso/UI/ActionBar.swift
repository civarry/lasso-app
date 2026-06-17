import SwiftUI

/// How the action pills render. Compact (icon-only, name on hover) keeps the bar narrow so it never
/// needs horizontal scrolling — the fast default; Comfortable shows names inline, capped + grouped
/// with the long tail in a "More" menu so the bar never runs edge-to-edge.
enum ActionBarStyle: String, CaseIterable, Identifiable {
    case compact, labeled
    var id: String { rawValue }
    var label: String { self == .compact ? "Compact" : "Comfortable" }
}

/// Floating pill bar anchored near the selection. Renders relevant `CaptureAction`s plus
/// detected-data pills (links, phones, QR…) and quick send-to actions (Spec §6, §10).
struct ActionBar: View {
    @Bindable var coordinator: CaptureCoordinator
    @AppStorage("ui.actionBarStyle") private var styleRaw = ActionBarStyle.compact.rawValue
    @AppStorage("ui.actionBarHideUnavailable") private var hideUnavailable = false
    @AppStorage("ui.actionBarColorful") private var colorful = false
    private var style: ActionBarStyle { ActionBarStyle(rawValue: styleRaw) ?? .compact }

    /// Max labeled pills shown inline before the rest collapse into "More" (Comfortable only). Keeps
    /// the bar bounded instead of growing to the screen edge. Tunable.
    private static let maxLabeled = 6

    var body: some View {
        let items = barItems()
        let primaryID = items.first(where: { !$0.disabled })?.id
        // Compact is icon-only and stays narrow, so it shows everything; Comfortable caps + overflows.
        let visible = style == .compact ? items : Array(items.prefix(Self.maxLabeled))
        let overflow = style == .compact ? [] : Array(items.dropFirst(Self.maxLabeled))

        VStack(alignment: .leading, spacing: 8) {
            GlassPanel {
                HStack(spacing: 6) {
                    DragHandle(coordinator: coordinator)
                    HStack(spacing: 6) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { idx, item in
                            // Thin divider between priority bands (text · AI · image/utility).
                            if style == .labeled, idx > 0,
                               Self.band(item.priority) != Self.band(visible[idx - 1].priority) {
                                Divider().frame(height: 18)
                            }
                            ActionPill(title: item.title, systemImage: item.systemImage, style: style,
                                       index: idx, disabled: item.disabled, help: item.help,
                                       isPrimary: item.id == primaryID,
                                       tint: colorful ? Self.tint(for: item.id) : nil,
                                       action: item.run)
                        }
                        if !overflow.isEmpty {
                            Divider().frame(height: 18)
                            MorePill(items: overflow, index: visible.count)
                        }
                    }
                    Divider().frame(height: 18)
                    closeButton
                }
                .id(styleRaw)   // rebuild cleanly if the style is switched while the bar is open
            }

            // Detected dates/links/QR as separate chips floating *below* the bar (outside the panel).
            if let items = coordinator.context?.detectedData, !items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(items) { item in
                            DataPill(item: item) { coordinator.open(item) }
                        }
                    }
                }
            }
        }
    }

    private var closeButton: some View {
        Button { coordinator.cancel() } label: {
            Image(systemName: "xmark").font(.callout)
        }
        .buttonStyle(IconButtonStyle())
        .help("Close — press the capture shortcut again or Esc")
        .accessibilityLabel("Close")
    }

    /// Priority band an action belongs to, for grouping: 0 = text/data, 1 = AI, 2 = image/utility.
    /// Mirrors the `relevancePriority` ranges used across the action set.
    fileprivate static func band(_ priority: Int) -> Int {
        priority < 16 ? 0 : (priority < 50 ? 1 : 2)
    }

    /// Per-action color for the optional "Color-code actions" mode — a distinct hue per feature so
    /// they're easy to recognize. Applied as a glass tint, not a solid fill (keeps the aesthetic).
    fileprivate static func tint(for id: String) -> Color {
        switch id {
        case "ocr.copy":       return .blue
        case "translate":      return .green
        case "identify":       return .purple
        case "lens.search":    return .pink
        case "qr.open":        return .teal
        case "ai.grammar":     return .orange
        case "ai.summarize":   return .yellow
        case "ai.ask":         return .indigo
        case "color.pick":     return .cyan
        case "builtin.copyImage", "builtin.saveImage": return .gray
        default:               return .accentColor
        }
    }

    /// The full ordered set of bar entries: relevant actions (already priority-sorted) + the built-in
    /// image actions, with unavailable ones resolved (and dropped when "Hide unavailable" is on).
    private func barItems() -> [BarItem] {
        let vision = coordinator.intelligence?.visionAvailable ?? false
        var items: [BarItem] = coordinator.actions.map { action in
            let reason = coordinator.context.flatMap {
                action.disabledReason(for: $0, visionAvailable: vision)
            }
            return BarItem(id: action.id, title: action.title, systemImage: action.systemImage,
                           priority: action.relevancePriority, disabled: reason != nil, help: reason) {
                coordinator.run(action)
            }
        }
        items.append(BarItem(id: "builtin.copyImage", title: "Copy image", systemImage: "doc.on.doc",
                             priority: 60, disabled: false, help: nil) { coordinator.copyImageAndClose() })
        items.append(BarItem(id: "builtin.saveImage", title: "Save image", systemImage: "square.and.arrow.down",
                             priority: 61, disabled: false, help: nil) { coordinator.saveImageAndClose() })
        return hideUnavailable ? items.filter { !$0.disabled } : items
    }
}

/// A single entry in the bar — a `CaptureAction` or a built-in image action — normalized so the row
/// and the "More" menu can render either uniformly.
private struct BarItem: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let priority: Int
    let disabled: Bool
    let help: String?
    let run: () -> Void
}

private struct ActionPill: View {
    let title: String
    let systemImage: String
    var style: ActionBarStyle = .labeled
    var index: Int = 0
    var disabled: Bool = false
    var help: String? = nil
    var isPrimary: Bool = false
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovering = false
    @State private var shown = false

    /// Glass fill: a per-action color when "Color-code actions" is on, else an accent tint for the
    /// primary action and neutral for the rest. Disabled stays flat. Translucent throughout so the
    /// pill reads as colored glass, not a solid button.
    private var fill: AnyShapeStyle {
        if disabled { return AnyShapeStyle(.white.opacity(0.10)) }
        if let tint {
            return AnyShapeStyle(tint.opacity(hovering ? (isPrimary ? 0.52 : 0.40)
                                                       : (isPrimary ? 0.40 : 0.26)))
        }
        if isPrimary { return AnyShapeStyle(Color.accentColor.opacity(hovering ? 0.32 : 0.22)) }
        return AnyShapeStyle(.white.opacity(hovering ? 0.20 : 0.10))
    }

    var body: some View {
        Button(action: action) {
            Group {
                if style == .compact {
                    Image(systemName: systemImage).frame(minWidth: 22, minHeight: 18)
                } else {
                    Label(title, systemImage: systemImage).frame(minHeight: 18)
                }
            }
            .lineLimit(1)                                    // never wrap a label to two lines
            .fixedSize(horizontal: true, vertical: false)    // take full width (bar is capped, so safe)
            .font(.callout)
            .padding(.horizontal, style == .compact ? 8 : 10)
            .padding(.vertical, 7)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.pillRadius))
            .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(PressableStyle())
        .disabled(disabled)
        .accessibilityLabel(title)
        .accessibilityHint(help ?? "")
        // Sequential cascade as the bar appears (and on style switch, via .id), plus a smooth
        // grey→enabled fade when the OCR pre-pass catches up.
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 6)
        .onAppear { withAnimation(.easeOut(duration: 0.22).delay(Double(index) * 0.04)) { shown = true } }
        .animation(.easeOut(duration: 0.18), value: disabled)
        .onHover { hovering = $0 }
        .help(help ?? "")   // blocked reason (works on disabled pills too)
        // Icon-only mode: show the name as a floating label above the pill on hover.
        .overlay(alignment: .top) {
            if hovering, style == .compact, !disabled {
                Text(title)
                    .font(.caption2).fontWeight(.medium)
                    .fixedSize()
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
                    .offset(y: -30)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The overflow "More" pill — a native menu of the actions that didn't fit the labeled row, grouped
/// by band. Native menu = familiar, scrollable, and scales to any number of actions.
private struct MorePill: View {
    let items: [BarItem]
    var index: Int = 0
    @State private var hovering = false
    @State private var shown = false

    var body: some View {
        Menu {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                if idx > 0, ActionBar.band(item.priority) != ActionBar.band(items[idx - 1].priority) {
                    Divider()
                }
                Button { item.run() } label: { Label(item.title, systemImage: item.systemImage) }
                    .disabled(item.disabled)
            }
        } label: {
            Label("More", systemImage: "ellipsis")
                .font(.callout).frame(minHeight: 18)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.white.opacity(hovering ? 0.20 : 0.10),
                            in: RoundedRectangle(cornerRadius: Theme.pillRadius))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions")
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 6)
        .onAppear { withAnimation(.easeOut(duration: 0.22).delay(Double(index) * 0.04)) { shown = true } }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct DataPill: View {
    let item: DetectedItem
    let action: () -> Void
    @State private var hovering = false

    private var symbol: String {
        switch item.kind {
        case .url: "link"
        case .phone: "phone"
        case .email: "envelope"
        case .address: "mappin.and.ellipse"
        case .date: "calendar"
        case .qr: "qrcode"
        case .barcode: "barcode"
        }
    }

    var body: some View {
        Button(action: action) {
            Label(item.value, systemImage: symbol)
                .lineLimit(1)
                .truncationMode(item.kind == .url ? .tail : .middle)
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .frame(maxWidth: 220)
                .background(.tint.opacity(hovering ? 0.45 : 0.30), in: Capsule())
                .background(.regularMaterial, in: Capsule())   // legible as a floating chip
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
