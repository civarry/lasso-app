import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// On-disk persistence for chat conversations. Lives in **Application Support** (outside the `.app`
/// bundle), so history survives app updates and uninstall→reinstall via the GitHub DMG — the same
/// place `UserDefaults`/Keychain already survive.
///
/// Design (agreed): **one file per conversation** (tiny autosaves, isolated corruption, future
/// import/export) + a lightweight `index.json`. We persist the **source of truth only** — messages,
/// two-track memory, title, and the *textual* representation of images (`promptText` already folds in
/// the vision description; plus a small thumbnail for visual continuity). The semantic index
/// (embeddings) is **derived** and rebuilt lazily on load — never stored. Every file carries a
/// `schemaVersion` so a future format change can migrate instead of breaking.
enum ConversationStore {
    static let schemaVersion = 1

    // MARK: - Locations

    private static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Lasso", isDirectory: true)
    }
    private static var conversationsDir: URL { root.appendingPathComponent("conversations", isDirectory: true) }
    private static var imagesDir: URL { root.appendingPathComponent("images", isDirectory: true) }
    private static var indexURL: URL { root.appendingPathComponent("index.json") }

    private static func ensureDirs() {
        try? FileManager.default.createDirectory(at: conversationsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - DTOs (Codable source-of-truth)

    struct ConversationDTO: Codable {
        var schemaVersion: Int
        var id: UUID
        var createdAt: Date
        var kind: String
        var autoTitle: String?
        var summarizedTurnCount: Int
        var durableFacts: String
        /// Optional so older saved conversations (pre-DECISIONS) decode cleanly — Codable synthesis
        /// treats a missing key on an Optional as `nil` automatically, no migration needed.
        var decisions: String?
        var topicTrace: String
        var anchorSelection: String?
        var messages: [MessageDTO]
    }

    struct MessageDTO: Codable {
        var id: UUID
        var role: String
        var text: String
        var promptText: String?
        var reasoning: String
        var reasoningSeconds: Int?
        var sources: [WebSourcesProvider.Hit]
        var attachments: [AttachmentDTO]
    }

    struct AttachmentDTO: Codable {
        var id: UUID
        var caption: String?
        var ocr: String?
        var hasThumbnail: Bool
    }

    struct IndexEntry: Codable {
        var id: UUID
        var title: String
        var kind: String
        var createdAt: Date
        var lastModified: Date
        var messageCount: Int
    }

    private struct IndexFile: Codable {
        var schemaVersion: Int
        var conversations: [IndexEntry]
    }

    /// A CGImage awaiting thumbnail encoding, carried into the background writer. `@unchecked Sendable`:
    /// the CGImage is an immutable Core Graphics object.
    struct ThumbnailJob: @unchecked Sendable {
        let id: UUID
        let image: CGImage
    }

    // MARK: - Disk I/O (nonisolated — call from a background Task)

    /// Write one conversation's JSON + encode any not-yet-saved thumbnails (attachment images are
    /// immutable, so each thumbnail is encoded exactly once).
    static func writeConversation(_ dto: ConversationDTO, thumbnails: [ThumbnailJob]) {
        ensureDirs()
        if let data = try? makeEncoder().encode(dto) {
            try? data.write(to: conversationsDir.appendingPathComponent("\(dto.id.uuidString).json"),
                            options: .atomic)
        }
        for job in thumbnails {
            let url = imagesDir.appendingPathComponent("\(job.id.uuidString).jpg")
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            if let data = jpegThumbnail(job.image) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Rewrite the lightweight switcher/search index (tiny — safe to rewrite on any save).
    static func writeIndex(_ entries: [IndexEntry]) {
        ensureDirs()
        let file = IndexFile(schemaVersion: schemaVersion, conversations: entries)
        if let data = try? makeEncoder().encode(file) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    /// Load every stored conversation (directory scan — robust even if the index is stale/missing),
    /// oldest-first by creation date. Skips files from an unknown/newer schema.
    static func loadAll() -> [ConversationDTO] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: conversationsDir, includingPropertiesForKeys: nil) else { return [] }
        let decoder = makeDecoder()
        var out: [ConversationDTO] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let dto = try? decoder.decode(ConversationDTO.self, from: data),
                  dto.schemaVersion <= schemaVersion else { continue }
            out.append(dto)
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    /// Remove one conversation's JSON (thumbnails are left; `clearAll` reclaims them).
    static func delete(id: UUID) {
        try? FileManager.default.removeItem(
            at: conversationsDir.appendingPathComponent("\(id.uuidString).json"))
    }

    /// Wipe all persisted chat history (the "Clear history" privacy control).
    static func clearAll() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Thumbnails

    /// Load an attachment thumbnail back into a CGImage (nil if missing/corrupt).
    static func loadThumbnail(_ id: UUID) -> CGImage? {
        let url = imagesDir.appendingPathComponent("\(id.uuidString).jpg")
        guard let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return img
    }

    /// Downscale a CGImage to a small JPEG for storage/display continuity (not full-res — that's
    /// deferred). Keeps thumbnails to `maxDimension` on the long edge.
    static func jpegThumbnail(_ image: CGImage, maxDimension: CGFloat = 512) -> Data? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, maxDimension / CGFloat(max(w, h)))
        let tw = max(1, Int(CGFloat(w) * scale)), th = max(1, Int(CGFloat(h) * scale))
        guard let ctx = CGContext(
            data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}

// MARK: - Conversation ↔ DTO mapping (reads @MainActor model state)

@MainActor
extension ConversationStore {
    /// Snapshot a live conversation into its Codable source-of-truth form. Streaming/derived state
    /// (isStreaming, statusText, steps, the semantic index) is intentionally dropped — rebuilt at runtime.
    static func snapshot(_ c: Conversation) -> ConversationDTO {
        var anchorSelection: String?
        if case .selection(let s)? = c.anchor { anchorSelection = s }
        let messages = c.messages.map { m in
            MessageDTO(
                id: m.id,
                role: m.role == .user ? "user" : "assistant",
                text: m.text,
                promptText: m.promptText,
                reasoning: m.reasoning,
                reasoningSeconds: m.reasoningSeconds,
                sources: m.sources,
                attachments: m.attachments.map {
                    AttachmentDTO(id: $0.id, caption: $0.caption, ocr: $0.ocr, hasThumbnail: true)
                })
        }
        return ConversationDTO(
            schemaVersion: schemaVersion,
            id: c.id,
            createdAt: c.createdAt,
            kind: c.kind.rawValue,
            autoTitle: c.autoTitle,
            summarizedTurnCount: c.summarizedTurnCount,
            durableFacts: c.memory.durableFacts,
            decisions: c.memory.decisions,
            topicTrace: c.memory.topicTrace,
            anchorSelection: anchorSelection,
            messages: messages)
    }

    /// The attachment images to encode as thumbnails (writer skips ones already on disk).
    static func thumbnailJobs(_ c: Conversation) -> [ThumbnailJob] {
        c.messages.flatMap { $0.attachments }.map { ThumbnailJob(id: $0.id, image: $0.image) }
    }

    /// Lightweight index entry for the switcher/search (no message bodies).
    static func indexEntry(_ c: Conversation) -> IndexEntry {
        IndexEntry(id: c.id, title: c.title, kind: c.kind.rawValue,
                   createdAt: c.createdAt, lastModified: Date(), messageCount: c.messages.count)
    }

    /// Rebuild a live conversation from its stored form. Thumbnails load back as the attachment image
    /// (full-res is deferred); a missing thumbnail simply drops that attachment — the turn's text and
    /// `promptText` (which already folds in the vision description) keep the AI's understanding intact.
    static func rebuild(_ dto: ConversationDTO) -> Conversation {
        let c = Conversation(id: dto.id, createdAt: dto.createdAt)
        c.kind = Conversation.Kind(rawValue: dto.kind) ?? .general
        c.autoTitle = dto.autoTitle
        c.summarizedTurnCount = dto.summarizedTurnCount
        c.memory = ConversationMemory(durableFacts: dto.durableFacts, decisions: dto.decisions ?? "",
                                      topicTrace: dto.topicTrace)
        if let sel = dto.anchorSelection { c.anchor = .selection(sel) }
        c.messages = dto.messages.map { md in
            var msg = ChatMessage(role: md.role == "user" ? .user : .assistant, text: md.text)
            msg.promptText = md.promptText
            msg.reasoning = md.reasoning
            msg.reasoningSeconds = md.reasoningSeconds
            msg.sources = md.sources
            msg.attachments = md.attachments.compactMap { ad in
                guard ad.hasThumbnail, let img = loadThumbnail(ad.id) else { return nil }
                return Attachment(id: ad.id, image: img, caption: ad.caption, ocr: ad.ocr)
            }
            return msg
        }
        return c
    }
}
