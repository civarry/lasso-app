import CoreGraphics
import Foundation

/// A table in a capture, rebuilt from where each piece of text sits: OCR reads every cell as its own
/// line, so the text alone has no rows or columns. Rows are lines at the same height; columns are the
/// left edges that line up across rows. Tab-separated, one row per line, or nil when it isn't a table.
enum TableText {
    static func tsv(from lines: [OCRLine]) -> String? {
        let cells = lines.filter { !$0.string.trimmingCharacters(in: .whitespaces).isEmpty }
        guard cells.count >= 4 else { return nil }
        let heights = cells.map(\.boundingBox.height).sorted()
        let lineHeight = max(heights[heights.count / 2], 0.001)

        // Rows: top to bottom (Vision's origin is bottom-left), a cell joins a row at its height.
        var rows: [[OCRLine]] = []
        for cell in cells.sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
            if let last = rows.last, let anchor = last.first,
               abs(anchor.boundingBox.midY - cell.boundingBox.midY) < lineHeight * 0.6 {
                rows[rows.count - 1].append(cell)
            } else {
                rows.append([cell])
            }
        }
        rows = rows.map { $0.sorted { $0.boundingBox.minX < $1.boundingBox.minX } }
        let multi = rows.filter { $0.count >= 2 }
        guard multi.count >= 2, Double(multi.count) >= Double(rows.count) * 0.6 else { return nil }

        // Columns: left edges that line up, clustered with a tolerance of about one line height.
        let edges = multi.flatMap { $0.map(\.boundingBox.minX) }.sorted()
        var columns: [[CGFloat]] = []
        for edge in edges {
            if let last = columns.last?.last, edge - last < lineHeight * 1.5 { columns[columns.count - 1].append(edge) }
            else { columns.append([edge]) }
        }
        let anchors = columns.filter { $0.count >= 2 }.map { $0.reduce(0, +) / CGFloat($0.count) }
        guard anchors.count >= 2 else { return nil }

        func column(_ x: CGFloat) -> Int {
            anchors.indices.min { abs(anchors[$0] - x) < abs(anchors[$1] - x) } ?? 0
        }
        let out = rows.map { row -> String in
            var cellsByColumn = Array(repeating: "", count: anchors.count)
            for cell in row {
                let i = column(cell.boundingBox.minX)
                let text = cell.string.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces)
                cellsByColumn[i] = cellsByColumn[i].isEmpty ? text : cellsByColumn[i] + " " + text
            }
            return cellsByColumn.joined(separator: "\t")
        }
        return out.joined(separator: "\n")
    }
}
