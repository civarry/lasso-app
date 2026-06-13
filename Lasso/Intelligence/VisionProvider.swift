import Foundation
import CoreGraphics
import AppKit

/// A backend that can look at an image and answer/describe it. Lets Identify and Ask-AI use whichever
/// is appropriate — local Ollama vision, or a multimodal cloud model when the user picked one.
protocol VisionProvider: Sendable {
    func isAvailable() async -> Bool
    func describe(_ image: CGImage, prompt: String) async throws -> String
}

extension URLSession {
    /// Bounded session for vision requests: caps both the per-request idle time and the **total**
    /// time, so a stalled/rate-limited cloud vision model fails in ~45s instead of hanging for
    /// minutes (URLRequest.timeoutInterval alone resets whenever a byte trickles in).
    static let vision: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        return URLSession(configuration: config)
    }()
}

/// Shared image encoding for vision requests (downscale + JPEG + base64).
enum ImageEncoder {
    // Default 768px: vision models describe a 768px crop nearly as well as 1024 but noticeably
    // faster. Reverse-image connectors pass their own (larger) maxEdge for match fidelity.
    static func jpegBase64(_ image: CGImage, maxEdge: Int = 768, quality: CGFloat = 0.82) -> String? {
        let scaled = image.downscaled(maxEdge: maxEdge)
        let rep = NSBitmapImageRep(cgImage: scaled)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])?
            .base64EncodedString()
    }
}
