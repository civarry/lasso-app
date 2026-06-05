import SwiftUI

/// Shows the output of the running action: streamed AI text, OCR text, errors, or a custom view.
struct ResultPane: View {
    @Bindable var coordinator: CaptureCoordinator

    private var result: ResultState { coordinator.result }

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(result.title).font(.headline)
                    if result.isStreaming { ProgressView().controlSize(.small) }
                    Spacer()
                    if !result.text.isEmpty {
                        Button {
                            Pasteboard.copy(result.text)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .help("Copy result")
                    }
                    Button { coordinator.result = .hidden } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if let custom = result.custom {
                    custom
                } else if let error = result.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else {
                    ScrollView {
                        Text(result.text.isEmpty && result.isStreaming
                             ? AttributedString("…")
                             : AttributedString.fromMarkdown(result.text))
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 80, maxHeight: 340)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}
