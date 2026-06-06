import SwiftUI

/// Shared visual constants for the floating overlay UI.
enum Theme {
    static let cornerRadius: CGFloat = 12
    static let pillRadius: CGFloat = 9
    static let spacing: CGFloat = 8

    static let panelMaterial: Material = .ultraThinMaterial
}

/// Grip used to drag the floating bar/result panel around the screen. Writes a live offset to the
/// coordinator so the action bar, translate bar, and result panels all move together.
struct DragHandle: View {
    @Bindable var coordinator: CaptureCoordinator
    @State private var base: CGSize?
    @State private var hovering = false

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.callout)
            .foregroundStyle(hovering ? .primary : .secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(hovering ? 0.22 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                self.hovering = hovering
                if hovering { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
            // `.global` so translation is measured in screen space, not relative to this handle
            // (which moves with the panel) — avoids the feedback loop that caused lag/ghosting.
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = base ?? coordinator.panelDragOffset
                        if base == nil { base = start }
                        coordinator.panelDragOffset = CGSize(
                            width: start.width + value.translation.width,
                            height: start.height + value.translation.height)
                    }
                    .onEnded { _ in base = nil }
            )
            .help("Drag to move")
    }
}

/// Base point size that `textScale` multiplies for result/answer/reading text.
let resultTextBaseSize: CGFloat = 15

/// Press feedback for controls that already have their own background (e.g. pills): a quick
/// scale/opacity dip so a click is unmistakable.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Bare icon button with an adaptive hover highlight + press animation, so it's obviously
/// clickable on both light and dark backgrounds behind the frosted panels.
struct IconButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 7
    var padding: CGFloat = 5

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, cornerRadius: cornerRadius, padding: padding)
    }

    struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        let padding: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(padding)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.accentColor.opacity(hovering && isEnabled ? 0.22 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                .scaleEffect(configuration.isPressed ? 0.88 : 1)
                .opacity(isEnabled ? 1 : 0.35)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// A−/A+ control for adjusting result text size. Bound to the shared `ui.resultTextScale` setting.
struct TextScaleControls: View {
    @Binding var scale: Double

    var body: some View {
        HStack(spacing: 2) {
            Button { scale = max(0.8, scale - 0.1) } label: {
                Image(systemName: "textformat.size.smaller")
            }
            .disabled(scale <= 0.8)

            Button { scale = min(2.0, scale + 0.1) } label: {
                Image(systemName: "textformat.size.larger")
            }
            .disabled(scale >= 2.0)
        }
        .buttonStyle(IconButtonStyle())
        .foregroundStyle(.primary)
        .help("Text size")
    }
}

/// A frosted container used for the ActionBar and ResultPane.
struct GlassPanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(10)
            .background(Theme.panelMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }
}
