import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Images an Agent reply points to with Hermes's `MEDIA:/absolute/path` directive.
///
/// Hermes delivers files on messaging platforms by writing that line; its API server turns it into an
/// image only on the chat-completions style endpoints, and leaves it as text on `/v1/runs`, the one
/// Lasso uses (for steps and approvals). So Lasso does it: an image file on this Mac becomes a picture in
/// the reply, and the line goes. Anything else (a missing file, a non-image, a remote Hermes whose paths
/// aren't on this Mac) stays as the plain path, so nothing the agent said is lost.
enum AgentMedia {
    static let maxImages = 4
    static let maxFileBytes = 20 * 1024 * 1024
    private static let maxPixels = 2048

    /// The directive's path, if `line` is one (`MEDIA:/abs/path` or `MEDIA:file:///abs/path`).
    static func path(inDirective line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("MEDIA:") else { return nil }
        var value = String(trimmed.dropFirst("MEDIA:".count)).trimmingCharacters(in: .whitespaces)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "`'\""))
        if value.hasPrefix("file://") { value = URL(string: value)?.path ?? "" }
        guard value.hasPrefix("/"), !value.contains(where: \.isWhitespace) else { return nil }
        return value
    }

    /// The reply without its directive lines, and their paths in order. Pure.
    static func split(_ text: String) -> (text: String, paths: [String]) {
        var kept: [Substring] = []
        var paths: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let path = path(inDirective: line) { paths.append(path) } else { kept.append(line) }
        }
        var out = kept.joined(separator: "\n")
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return (out.trimmingCharacters(in: .whitespacesAndNewlines), paths)
    }

    /// While streaming: the text with directive lines hidden, so a raw path never flashes on screen.
    static func hidingDirectives(_ text: String) -> String { split(text).text }

    /// The reply with images for every directive that names an image file here; the rest go back into
    /// the text as plain paths.
    static func resolve(_ text: String) -> (text: String, images: [(image: CGImage, path: String)]) {
        let parts = split(text)
        var images: [(CGImage, String)] = []
        var unresolved: [String] = []
        for path in parts.paths {
            if images.count < maxImages, let image = loadImage(at: path) { images.append((image, path)) }
            else { unresolved.append(path) }
        }
        let tail = unresolved.map { "`\($0)`" }.joined(separator: "\n")
        let body = [parts.text, tail].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return (body, images)
    }

    /// A downsampled image, or nil if the path isn't a readable image file of a sane size.
    static func loadImage(at path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey]),
              values.isRegularFile == true, (values.fileSize ?? .max) <= maxFileBytes,
              values.contentType?.conforms(to: .image) == true,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
