import SwiftUI

/// Floating pill bar anchored near the selection. Renders relevant `CaptureAction`s plus
/// detected-data pills (links, phones, QR…) and quick send-to actions (Spec §6, §10).
struct ActionBar: View {
    @Bindable var coordinator: CaptureCoordinator

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 8) {
                // Detected data (links/phones/QR) — only when present.
                if let items = coordinator.context?.detectedData, !items.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(items) { item in
                                DataPill(item: item) { coordinator.open(item) }
                            }
                        }
                    }
                }

                // Capability actions (scrollable) with a pinned, always-visible Close button.
                HStack(spacing: 6) {
                    DragHandle(coordinator: coordinator)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(coordinator.actions, id: \.id) { action in
                                let blocked = (coordinator.context.map { action.needsVision(for: $0) } ?? false)
                                    && !(coordinator.intelligence?.visionAvailable ?? false)
                                ActionPill(
                                    title: action.title, systemImage: action.systemImage,
                                    disabled: blocked,
                                    help: blocked
                                        ? "\(action.title) needs a vision model — install Ollama or add a cloud image model in Settings ▸ Intelligence ▸ Image."
                                        : nil
                                ) {
                                    coordinator.run(action)
                                }
                            }
                            Divider().frame(height: 18)
                            ActionPill(title: "Copy image", systemImage: "doc.on.doc") {
                                coordinator.copyImageAndClose()
                            }
                            ActionPill(title: "Save", systemImage: "square.and.arrow.down") {
                                coordinator.saveImageAndClose()
                            }
                        }
                    }

                    Divider().frame(height: 18)

                    Button { coordinator.cancel() } label: {
                        Image(systemName: "xmark").font(.callout)
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("Close — press the capture shortcut again or Esc")
                }
            }
        }
    }
}

private struct ActionPill: View {
    let title: String
    let systemImage: String
    var disabled: Bool = false
    var help: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white.opacity(hovering && !disabled ? 0.20 : 0.10),
                            in: RoundedRectangle(cornerRadius: Theme.pillRadius))
                .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(PressableStyle())
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(help ?? "")
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
