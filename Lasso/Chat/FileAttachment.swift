import Foundation
import PDFKit
import UniformTypeIdentifiers

/// A non-image file attached to a chat message.
///
/// Lasso accepts any file and decides, by its type, the best form for whoever answers: the agent gets
/// its path (it reads files with its own tools); a regular model gets the text of a text file or PDF,
/// capped, or an honest note naming a file it can't take (audio, video, an archive), so it can say so
/// instead of the attach button being dead. Images aren't files here: they go through `Attachment`.
struct FileAttachment: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable, Codable { case text, pdf, other }

    let id: UUID
    let path: String
    let name: String
    let kind: Kind
    /// "PDF document", "MP3 audio", … for notes and the chip.
    let typeName: String
    let bytes: Int

    /// Most characters of a file's text given to a regular model, so a big file can't crowd out the chat.
    static let maxTextCharacters = 24_000

    init?(url: URL, id: UUID = UUID()) {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey]),
              values.isRegularFile == true else { return nil }
        let type = values.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        self.id = id
        path = url.path
        name = url.lastPathComponent
        bytes = values.fileSize ?? 0
        typeName = type.localizedDescription ?? (url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased() + " file")
        kind = Self.kind(of: type)
    }

    init(id: UUID, path: String, name: String, kind: Kind, typeName: String, bytes: Int) {
        self.id = id; self.path = path; self.name = name; self.kind = kind; self.typeName = typeName; self.bytes = bytes
    }

    static func kind(of type: UTType) -> Kind {
        if type.conforms(to: .pdf) { return .pdf }
        let textual: [UTType] = [.text, .sourceCode, .json, .xml, .yaml, .commaSeparatedText,
                                 .tabSeparatedText, .propertyList, .script]
        return textual.contains(where: type.conforms(to:)) ? .text : .other
    }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    /// The line the agent gets: where the file is, so it can open it with its tools.
    var agentReference: String { "- `\(path)` (\(typeName), \(sizeText))" }

    /// What a model that can't open files gets: the text (capped), or a note it can act on.
    func contentForModel() -> String {
        switch kind {
        case .text, .pdf:
            guard var text = readText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "[Attached \(name) (\(typeName), \(sizeText)): no readable text in it.]"
            }
            var note = ""
            if text.count > Self.maxTextCharacters {
                text = String(text.prefix(Self.maxTextCharacters))
                note = " Only the first \(Self.maxTextCharacters) characters are included."
            }
            return "[Attached \(name) (\(typeName), \(sizeText)).\(note)]\n```\n\(text)\n```"
        case .other:
            return "[Attached \(name) (\(typeName), \(sizeText)). Its content isn't something you can read here; "
                + "if the question needs it, say what you'd need instead.]"
        }
    }

    private func readText() -> String? {
        let url = URL(fileURLWithPath: path)
        switch kind {
        case .pdf:
            return PDFDocument(url: url)?.string
        case .text:
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            let head = data.prefix(Self.maxTextCharacters * 4 + 4)
            return String(decoding: head, as: UTF8.self)   // lenient: a cut can split a character
        case .other:
            return nil
        }
    }
}
