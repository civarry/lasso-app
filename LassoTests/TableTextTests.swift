import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Lasso

/// A lassoed table: OCR gives each cell as its own line; `TableText` rebuilds rows and columns from
/// where they sit (Vision coordinates, origin bottom-left).
struct TableTextTests {
    private func cell(_ text: String, x: CGFloat, row: Int, width: CGFloat = 0.15) -> OCRLine {
        OCRLine(string: text, boundingBox: CGRect(x: x, y: 0.8 - CGFloat(row) * 0.1, width: width, height: 0.04))
    }

    @Test func aGridBecomesTabSeparatedRows() {
        let lines = [
            cell("Name", x: 0.05, row: 0), cell("Age", x: 0.4, row: 0), cell("City", x: 0.7, row: 0),
            cell("Ada Lovelace", x: 0.05, row: 1, width: 0.3), cell("36", x: 0.41, row: 1), cell("London", x: 0.7, row: 1),
            cell("Alan", x: 0.06, row: 2), cell("41", x: 0.4, row: 2), cell("Wilmslow", x: 0.69, row: 2),
        ].shuffled()
        #expect(TableText.tsv(from: lines) == "Name\tAge\tCity\nAda Lovelace\t36\tLondon\nAlan\t41\tWilmslow")
    }

    @Test func anEmptyCellKeepsItsColumn() {
        let lines = [
            cell("Item", x: 0.05, row: 0), cell("Qty", x: 0.4, row: 0), cell("Note", x: 0.7, row: 0),
            cell("Milk", x: 0.05, row: 1), cell("2", x: 0.4, row: 1),
            cell("Eggs", x: 0.05, row: 2), cell("12", x: 0.4, row: 2), cell("free range", x: 0.7, row: 2),
        ]
        #expect(TableText.tsv(from: lines) == "Item\tQty\tNote\nMilk\t2\t\nEggs\t12\tfree range")
    }

    @Test func aParagraphIsntATable() {
        let lines = (0..<5).map { cell("A line of ordinary prose that wraps across the page \($0)", x: 0.05, row: $0, width: 0.9) }
        #expect(TableText.tsv(from: lines) == nil)
        #expect(TableText.tsv(from: [cell("a", x: 0.1, row: 0), cell("b", x: 0.5, row: 0)]) == nil)
    }

    @Test func packagesCanTakeTheTableAndSayHowToUseIt() throws {
        let manifest = """
        {"lasso": 1, "id": "table-to-csv", "version": "1.1.0", "name": "Table to CSV", "summary": "x", "author": "Me",
         "commands": [{"id": "to-csv", "title": "Table to CSV", "surfaces": ["toolbar"], "input": ["table"],
           "when": {"detects": ["table"]}, "output": "file", "howTo": "Lasso a table, then click Table to CSV.",
           "run": {"script": {"path": "scripts/to-csv.py"}}}]}
        """
        let package = try #require(PackageValidator.validate(Data(manifest.utf8)).package, "\(PackageValidator.validate(Data(manifest.utf8)).problems)")
        #expect(package.commands[0].howTo == "Lasso a table, then click Table to CSV.")
        let onHotkey = PackageValidator.validate(Data(manifest.replacingOccurrences(of: #""surfaces": ["toolbar"]"#, with: #""surfaces": ["hotkey"]"#).utf8))
        #expect(onHotkey.problems.contains { $0.message.contains("\"table\" is only for toolbar commands") })
        let entry = PackageRegistry.Entry(package: package, values: [:], secrets: [], ready: true)
        let stdin = String(decoding: PackageScript.stdin(entry, package.commands[0], input: PackageInput(text: "x", table: "a\tb\n1\t2")), as: UTF8.self)
        #expect(stdin == #"{"command":"to-csv","settings":{},"table":"a\tb\n1\t2"}"#)
    }
}

@MainActor
struct AppLocationTests {
    @Test func onlyApplicationsCounts() {
        #expect(AppLocation.isInApplications(URL(fileURLWithPath: "/Applications/Lasso.app")))
        #expect(AppLocation.isInApplications(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/Lasso.app")))
        #expect(!AppLocation.isInApplications(URL(fileURLWithPath: "/Users/x/Library/Developer/Xcode/DerivedData/L/Build/Products/Debug/Lasso.app")))
        #expect(!AppLocation.isInApplications(URL(fileURLWithPath: "/Volumes/Lasso/Lasso.app")))
        #expect(!AppLocation.isInApplications(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads/Lasso.app")))
    }
}

/// A real table image through Lasso's own OCR, then `TableText`: what a lassoed spreadsheet gives.
struct TableOCRTests {
    @Test func aRenderedTableReadsBackAsRowsAndColumns() async throws {
        let rows = [["Name", "Age", "City"], ["Ada", "36", "London"], ["Alan", "41", "Wilmslow"], ["Grace", "85", "Arlington"]]
        let width = 900, height = 360
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 34), .foregroundColor: NSColor.black]
        for (r, row) in rows.enumerated() {
            for (c, text) in row.enumerated() {
                NSAttributedString(string: text, attributes: attributes)
                    .draw(at: CGPoint(x: 40 + c * 290, y: height - 70 - r * 80))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = try #require(ctx.makeImage())
        let result = try await OCREngine().recognize(image)
        #expect(TableText.tsv(from: result.lines) == rows.map { $0.joined(separator: "\t") }.joined(separator: "\n"),
                "OCR lines: \(result.lines.map(\.string))")
    }
}

/// A real screenshot (a sample dataset a chat model wrote): right-aligned numbers sit close to the next
/// column, and OCR joins them ("28 Engineering", "75,000 Active", "ID Name"). The image's blank strips
/// split them back.
struct TableScreenshotTests {
    @Test func aRealTableScreenshotReadsBackColumnByColumn() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/dataset-table.png")
        let image = try #require(NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let result = try await OCREngine().recognize(image)
        let table = try #require(TableText.tsv(from: result.lines, image: image))
        let rows = table.components(separatedBy: "\n").map { $0.components(separatedBy: "\t") }
        #expect(rows.first == ["ID", "Name", "Age", "Department", "Position", "Salary (USD)", "Status"], "\(table)")
        #expect(rows.count == 11)
        #expect(rows[1] == ["001", "Alex Morgan", "28", "Engineering", "Software Engineer", "75,000", "Active"])
        #expect(rows.allSatisfy { $0.count == 7 })
        // Where Vision joined cells (it does on some Macs, not all), the image is what splits them:
        // without it they stay joined.
        if result.lines.contains(where: { $0.string == "28 Engineering" }) {
            #expect(TableText.tsv(from: result.lines)?.contains("28 Engineering") == true)
        }
    }
}
