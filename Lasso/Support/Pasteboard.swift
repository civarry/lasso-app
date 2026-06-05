import AppKit
import CoreGraphics

/// Thin wrapper around NSPasteboard for the actions that copy text / images.
@MainActor
enum Pasteboard {
    static func copy(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    static func copy(_ image: CGImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image.nsImage])
    }
}
