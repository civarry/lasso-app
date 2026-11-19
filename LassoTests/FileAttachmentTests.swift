import Testing
import Foundation
import AppKit
@testable import Lasso

/// Any file can be attached; its type decides what the model gets. A model is never handed bytes it
/// can't use, and never left guessing: it gets the text, or a note naming what was attached.
@MainActor
@Suite(.serialized)
struct FileAttachmentTests {
    private let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appending(path: "file-att-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appending(path: name)
        try data.write(to: url)
        return url
    }

    @Test func typesAreSortedByWhatAModelCanUse() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FileAttachment(url: try write("notes.md", Data("# hi".utf8)))?.kind == .text)
        #expect(FileAttachment(url: try write("data.csv", Data("a,b\n1,2".utf8)))?.kind == .text)
        #expect(FileAttachment(url: try write("main.swift", Data("let x = 1".utf8)))?.kind == .text)
        #expect(FileAttachment(url: try write("doc.pdf", Data("%PDF-1.4".utf8)))?.kind == .pdf)
        #expect(FileAttachment(url: try write("song.mp3", Data([0xFF, 0xFB, 0x90])))?.kind == .other)
        #expect(FileAttachment(url: dir) == nil, "a folder isn't a file attachment")
    }

    @Test func aTextFileReachesTheModelCappedAndLabelled() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let small = try #require(FileAttachment(url: try write("todo.txt", Data("buy rice\ncall mom".utf8))))
        let content = small.contentForModel()
        #expect(content.contains("Attached todo.txt"))
        #expect(content.contains("buy rice\ncall mom"))
        let big = try #require(FileAttachment(url: try write("big.txt",
            Data(String(repeating: "x", count: FileAttachment.maxTextCharacters + 500).utf8))))
        let capped = big.contentForModel()
        #expect(capped.contains("Only the first \(FileAttachment.maxTextCharacters) characters"))
        #expect(capped.count < FileAttachment.maxTextCharacters + 300)
    }

    @Test func aFileTheModelCantReadGetsANoteNotARefusal() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let song = try #require(FileAttachment(url: try write("song.mp3", Data([0xFF, 0xFB, 0x90]))))
        let note = song.contentForModel()
        #expect(note.contains("Attached song.mp3"))
        #expect(note.contains("isn't something you can read here"))
        #expect(song.agentReference.contains(song.path))
    }

    @Test func attachingSortsImagesFromFiles() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let chat = ChatController.shared
        chat.newChat()
        let conversation = chat.active.id
        defer { chat.close(conversation) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        chat.attachFile(try write("pic.png", try #require(rep.representation(using: .png, properties: [:]))))
        chat.attachFile(try write("notes.txt", Data("hello".utf8)))
        chat.attachFile(try write("notes.txt", Data("hello".utf8)))   // the same file twice: once
        #expect(chat.pendingAttachments.count == 1)
        #expect(chat.pendingFiles.map(\.name) == ["notes.txt"])
        chat.clearAttachments()
        #expect(chat.pendingFiles.isEmpty && chat.pendingAttachments.isEmpty)
    }
}
