import SwiftUI

/// The SwiftUI content of one overlay window: frozen backdrop, dim layer with a "hole" punched
/// for the selection, drag-to-select, and (on the active display) the ActionBar + ResultPane.
///
/// Rectangle selection is implemented (M1/M2). Freeform lasso + tap-to-lift-subject are M5 — the
/// modifier hooks are noted inline.
struct CaptureSessionView: View {
    let shot: DisplayShot
    @Bindable var coordinator: CaptureCoordinator

    @State private var dragStart: CGPoint?
    @State private var liveRect: CGRect?

    private var selectionRect: CGRect? {
        if let liveRect { return liveRect }
        if coordinator.activeDisplayID == shot.id { return coordinator.committedRect }
        return nil
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Image(decorative: shot.image, scale: shot.scale)
                    .resizable()
                    .frame(width: geo.size.width, height: geo.size.height)

                // Dim everything except the selection (even-odd "hole").
                Canvas { ctx, size in
                    var path = Path(CGRect(origin: .zero, size: size))
                    if let r = selectionRect { path.addRect(r) }
                    ctx.fill(path, with: .color(.black.opacity(0.30)), style: FillStyle(eoFill: true))
                    if let r = selectionRect {
                        ctx.stroke(Path(r), with: .color(.white.opacity(0.95)), lineWidth: 1.5)
                    }
                }
                .allowsHitTesting(false)

                // Drag catcher.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(selectionGesture)

                // Anchored UI on the active display once a selection is committed.
                if coordinator.activeDisplayID == shot.id, let r = coordinator.committedRect {
                    anchoredUI(rect: r, in: geo.size)
                }
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .onExitCommand { coordinator.cancel() }   // Esc closes the session
    }

    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStart == nil { dragStart = value.startLocation }
                liveRect = CGRect.between(dragStart ?? value.startLocation, value.location)
            }
            .onEnded { value in
                let rect = CGRect.between(dragStart ?? value.startLocation, value.location)
                dragStart = nil
                liveRect = nil
                coordinator.commitSelection(rectInPoints: rect, displayID: shot.id)
            }
    }

    @ViewBuilder
    private func anchoredUI(rect: CGRect, in size: CGSize) -> some View {
        let panelWidth: CGFloat = 460
        let margin: CGFloat = 12
        let gap: CGFloat = 14

        // Horizontal: align to the selection's left edge, clamped fully on-screen.
        let x = min(max(rect.minX, margin), max(margin, size.width - panelWidth - margin))

        // If the selection is low on screen, grow the panel UPWARD from above the selection;
        // otherwise place it below. Uses alignment + padding so no height measurement is needed.
        let placeAbove = rect.maxY > size.height * 0.55

        let panel = VStack(alignment: .leading, spacing: 10) {
            ActionBar(coordinator: coordinator)
            if coordinator.result.visible {
                ResultPane(coordinator: coordinator)
            }
        }
        .frame(width: panelWidth, alignment: .leading)

        Color.clear.overlay(alignment: placeAbove ? .bottomLeading : .topLeading) {
            panel
                .padding(.leading, x)
                .padding(placeAbove ? .bottom : .top,
                         placeAbove ? (size.height - rect.minY + gap) : (rect.maxY + gap))
        }
    }
}

extension CGRect {
    /// Normalized rect spanning two points.
    static func between(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
