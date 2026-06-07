import Foundation
import CoreGraphics
import AppKit

/// A backend that can look at an image and answer/describe it. Lets Identify and Ask-AI use whichever
/// is appropriate — local Ollama vision, or a multimodal cloud model when the user picked one.
protocol VisionProvider: Sendable {
    func isAvailable() async -> Bool
    func describe(_ image: CGImage, prompt: String) async throws -> String
}

/// Shared image encoding for vision requests (downscale + JPEG + base64).
enum ImageEncoder {
    static func jpegBase64(_ image: CGImage, maxEdge: Int = 1024, quality: CGFloat = 0.82) -> String? {
        let scaled = image.downscaled(maxEdge: maxEdge)
        let rep = NSBitmapImageRep(cgImage: scaled)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])?
            .base64EncodedString()
    }
}
