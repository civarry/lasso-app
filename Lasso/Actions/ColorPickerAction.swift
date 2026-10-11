import SwiftUI

/// Eyedropper: sample a pixel from the frozen crop and copy it as hex / RGB / SwiftUI Color
/// (Spec §11.1). Trivial given we already hold the frozen `CGImage`.
struct ColorPickerAction: CaptureAction {
    let id = "color.pick"
    let title = "Pick color"
    let systemImage = "eyedropper"
    let relevancePriority = 50

    func isRelevant(to ctx: CaptureContext) -> Bool { true }

    func perform(_ ctx: CaptureContext) async throws -> ActionResult {
        let image = ctx.image
        let color = image.pixelColor(atX: image.width / 2, y: image.height / 2) ?? .black
        return .custom(AnyView(ColorResultView(color: color)))
    }
}

private struct ColorResultView: View {
    let color: NSColor

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: color))
                .frame(width: 56, height: 56)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.2)))

            VStack(alignment: .leading, spacing: 4) {
                CopyRow(label: color.hexString, value: color.hexString)
                CopyRow(label: color.rgbString, value: color.rgbString)
                CopyRow(label: "SwiftUI Color", value: color.swiftUIColorString)
            }
        }
        .frame(width: 360, alignment: .leading)
    }
}

private struct CopyRow: View {
    let label: String
    let value: String

    var body: some View {
        Button {
            Pasteboard.copy(value)
        } label: {
            HStack {
                Text(label).font(.system(.callout, design: .monospaced))
                Spacer()
                Image(systemName: "doc.on.doc").font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help("Copy \(value)")
    }
}
