import SwiftUI

/// How the action pills render. Compact (icon-only, name on hover) keeps the bar narrow so it never
/// needs horizontal scrolling — the fast default; Labeled shows names inline.
enum ActionBarStyle: String, CaseIterable, Identifiable {
    case compact, labeled
    var id: String { rawValue }
    var label: String { self == .compact ? "Compact" : "Cozy" }
}

/// Floating pill bar anchored near the selection. Renders relevant `CaptureAction`s plus
/// detected-data pills (links, phones, QR…) and quick send-to actions (Spec §6, §10).
struct ActionBar: View {
    @Bindable var coordinator: CaptureCoordinator
    @AppStorage("ui.actionBarStyle") private var styleRaw = ActionBarStyle.compact.rawValue
    @AppStorage("ui.actionBarHideUnavailable") private var hideUnavailable = false
    private var style: ActionBarStyle { ActionBarStyle(rawValue: styleRaw) ?? .compact }

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 8) {
                // A single row sized to its contents — the floating bar just grows as wide as needed,
                // so nothing wraps or scrolls. Compact (icons) is narrow; labeled is wider.
                HStack(spacing: 6) {
                    DragHandle(coordinator: coordinator)
                    HStack(spacing: 6) { pillItems }
                    Divider().frame(height: 18)
                    closeButton
                }
                .id(styleRaw)   // rebuild cleanly if the style is switched while the bar is open

                // Detected data (links/phones/QR) — below the actions, so it never collides with the
                // hover labels that float above the action row.
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
    }

    private var closeButton: some View {
        Button { coordinator.cancel() } label: {
            Image(systemName: "xmark").font(.callout)
        }
        .buttonStyle(IconButtonStyle())
        .help("Close — press the capture shortcut again or Esc")
    }

    @ViewBuilder private var pillItems: some View {
        let vision = coordinator.intelligence?.visionAvailable ?? false
        // Resolve each action's disabled reason; in minimal mode, drop the unavailable ones entirely.
        let resolved = coordinator.actions.map { action -> (action: any CaptureAction, reason: String?) in
            (action, coordinator.context.flatMap { action.disabledReason(for: $0, visionAvailable: vision) })
        }
        let shown = hideUnavailable ? resolved.filter { $0.reason == nil } : resolved

        ForEach(Array(shown.enumerated()), id: \.element.action.id) { index, item in
            ActionPill(
                title: item.action.title, systemImage: item.action.systemImage, style: style,
                index: index, disabled: item.reason != nil, help: item.reason
            ) {
                coordinator.run(item.action)
            }
        }
        ActionPill(title: "Copy image", systemImage: "doc.on.doc", style: style, index: shown.count) {
            coordinator.copyImageAndClose()
        }
        ActionPill(title: "Save", systemImage: "square.and.arrow.down", style: style, index: shown.count + 1) {
            coordinator.saveImageAndClose()
        }
    }
}


private struct ActionPill: View {
    let title: String
    let systemImage: String
    var style: ActionBarStyle = .labeled
    var index: Int = 0
    var disabled: Bool = false
    var help: String? = nil
    let action: () -> Void
    @State private var hovering = false
    @State private var shown = false

    var body: some View {
        Button(action: action) {
            Group {
                if style == .compact {
                    Image(systemName: systemImage).frame(width: 22, height: 18)
                } else {
                    Label(title, systemImage: systemImage).frame(height: 18)
                }
            }
            .font(.callout)
            .padding(.horizontal, style == .compact ? 8 : 10)
            .padding(.vertical, 6)
            .background(.white.opacity(hovering && !disabled ? 0.20 : 0.10),
                        in: RoundedRectangle(cornerRadius: Theme.pillRadius))
            .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(PressableStyle())
        .disabled(disabled)
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
                .truncationMode(.middle)
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .frame(maxWidth: 220)
                .background(.tint.opacity(hovering ? 0.38 : 0.22), in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
