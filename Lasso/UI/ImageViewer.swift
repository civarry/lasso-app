import AppKit
import SwiftUI

/// Shows an image from the chat at full size: a pending attachment, one in a sent message, or a picture
/// in a reply. The chat panel is too narrow to show anything "bigger", so this is its own window, sized
/// to the image (up to most of the screen), reused for the next image, closed with Esc or ⌘W.
@MainActor
final class ImageViewer: NSObject, NSWindowDelegate {
    static let shared = ImageViewer()

    private var window: NSWindow?

    /// `file`: where the image came from, if it's a file on this Mac (adds Show in Finder, and Open in
    /// Preview opens that file instead of a copy).
    func show(_ image: CGImage, title: String = "Image", file: URL? = nil) {
        let size = fittedSize(for: image)
        let view = ImageViewerView(image: image, file: file) { [weak self] in self?.close() }
        if let window {
            window.title = title
            window.contentViewController = Self.hosting(view, size: size)
            window.setContentSize(size)
            window.center()
            AppActivation.bringForward(window)
            return
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // Above the chat panel, which floats.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 280, height: 220)
        window.contentViewController = Self.hosting(view, size: size)
        window.delegate = self
        window.center()
        AppActivation.bringForward(window)
        self.window = window
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) { window = nil }

    private static func hosting(_ view: ImageViewerView, size: NSSize) -> NSHostingController<ImageViewerView> {
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        hosting.view.frame = NSRect(origin: .zero, size: size)
        hosting.view.autoresizingMask = [.width, .height]
        return hosting
    }

    /// The image's size in points, shrunk to fit 85% of the screen, plus room for the button row.
    private func fittedSize(for image: CGImage) -> NSSize {
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let bar: CGFloat = 52
        var w = CGFloat(image.width) / scale, h = CGFloat(image.height) / scale
        let fit = min(1, (screen.width * 0.85) / w, (screen.height * 0.85 - bar) / h)
        w *= fit; h *= fit
        return NSSize(width: max(w, 320), height: max(h, 200) + bar)
    }
}

private struct ImageViewerView: View {
    let image: CGImage
    let file: URL?
    let close: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            Image(decorative: image, scale: NSScreen.main?.backingScaleFactor ?? 2)
                .resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 8) {
                Text("\(image.width) × \(image.height)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    Pasteboard.copy(image)
                    copied = true
                }
                .keyboardShortcut("c", modifiers: .command)
                if let file {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
                Button("Open in Preview") { openInPreview() }
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .background(.black.opacity(0.85))
        .onExitCommand(perform: close)
    }

    /// The original file if there is one; otherwise a copy written to a temporary folder.
    private func openInPreview() {
        if let file, FileManager.default.fileExists(atPath: file.path) {
            Self.openInPreviewApp(file)
            return
        }
        let dir = FileManager.default.temporaryDirectory.appending(path: "Lasso Images", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "Image \(Self.stamp()).png")
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? data.write(to: url)) != nil else { return }
        Self.openInPreviewApp(url)
    }

    /// Opens the file in Preview itself. Never by the file's default app: a package's picture can be
    /// named anything, and `chart.command` would open in Terminal and run.
    static func openInPreviewApp(_ file: URL) {
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else { return }
        NSWorkspace.shared.open([file], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }
}
