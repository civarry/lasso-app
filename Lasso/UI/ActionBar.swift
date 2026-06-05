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
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(coordinator.actions, id: \.id) { action in
                                ActionPill(title: action.title, systemImage: action.systemImage) {
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
                        Image(systemName: "xmark")
                            .font(.callout)
                            .padding(7)
                            .background(.white.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Close — press the capture shortcut again or Esc")
                }
            }
        }
    }
}

private struct ActionPill: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.pillRadius))
        }
        .buttonStyle(.plain)
    }
}

private struct DataPill: View {
    let item: DetectedItem
    let action: () -> Void

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
                .background(.tint.opacity(0.22), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
