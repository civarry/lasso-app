import CoreGraphics
import Foundation

/// A table in a capture, rebuilt from where each piece of text sits: OCR reads every cell as its own
/// line, so the text alone has no rows or columns. Rows are lines at the same height; columns are the
/// vertical bands most rows fill, split by gaps few rows reach. Tab-separated, one row per line, or nil
/// when it isn't a table.
enum TableText {
    /// With the captured `image`, cells OCR joined ("28 Engineering") are split where the pixels show a
    /// wide blank gap inside the line.
    static func tsv(from lines: [OCRLine], image: CGImage? = nil) -> String? {
        let found = lines.filter { !$0.string.trimmingCharacters(in: .whitespaces).isEmpty }
        let cells = image.flatMap { Ink($0) }.map { ink in found.flatMap { split($0, ink) } } ?? found
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

        // Columns: where rows have text. Count, across the rows, how many reach each sliver of the
        // width; a gap is where almost none do. A header OCR joined with its neighbour ("ID Name")
        // covers a gap in one row only, so it can't merge two columns.
        let bins = 400
        var coverage = [Int](repeating: 0, count: bins)
        for row in multi {
            var covered = [Bool](repeating: false, count: bins)
            // Cells, already split where the image shows a gap (Vision's word boxes are too loose).
            for box in row.map(\.boundingBox) {
                let lo = max(0, Int(box.minX * CGFloat(bins))), hi = min(bins - 1, Int(box.maxX * CGFloat(bins)))
                if lo <= hi { for i in lo...hi { covered[i] = true } }
            }
            for i in 0..<bins where covered[i] { coverage[i] += 1 }
        }
        let floor = max(1, multi.count / 5)
        var bands: [(minX: CGFloat, maxX: CGFloat)] = []
        var start: Int?
        for i in 0...bins {
            let filled = i < bins && coverage[i] > floor
            if filled, start == nil { start = i }
            if !filled, let s = start {
                bands.append((CGFloat(s) / CGFloat(bins), CGFloat(i) / CGFloat(bins)))
                start = nil
            }
        }
        guard bands.count >= 2 else { return nil }

        func column(_ x: CGFloat) -> Int {
            if let i = bands.firstIndex(where: { x >= $0.minX && x <= $0.maxX }) { return i }
            return bands.indices.min { abs((bands[$0].minX + bands[$0].maxX) / 2 - x) < abs((bands[$1].minX + bands[$1].maxX) / 2 - x) } ?? 0
        }
        /// A cell, or its words when OCR joined it across a column gap.
        func pieces(_ cell: OCRLine) -> [(Int, String)] {
            let first = column(cell.boundingBox.minX + 0.001), last = column(cell.boundingBox.maxX - 0.001)
            if first != last, !cell.words.isEmpty {
                return cell.words.map { (column($0.boundingBox.midX), $0.string) }
            }
            return [(column(cell.boundingBox.midX), cell.string)]
        }
        let out = rows.map { row -> String in
            var cellsByColumn = Array(repeating: "", count: bands.count)
            for cell in row {
                for (i, piece) in pieces(cell) {
                    let text = piece.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces)
                    cellsByColumn[i] = cellsByColumn[i].isEmpty ? text : cellsByColumn[i] + " " + text
                }
            }
            return cellsByColumn.joined(separator: "\t")
        }
        return out.joined(separator: "\n")
    }

    // MARK: Splitting joined cells by the image

    /// Grey levels of the capture, to find blank columns inside a line.
    struct Ink {
        let width: Int, height: Int
        let pixels: [UInt8]
        init?(_ image: CGImage) {
            width = image.width; height = image.height
            guard width > 0, height > 0, width * height < 40_000_000 else { return nil }
            var buffer = [UInt8](repeating: 0, count: width * height)
            guard let ctx = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            pixels = buffer
        }
        /// Row `y` counted from the top.
        func at(_ x: Int, _ y: Int) -> UInt8 { pixels[(height - 1 - y) * width + x] }
    }

    /// `line` as one cell, or several where a blank strip wider than a space runs through it.
    static func split(_ line: OCRLine, _ ink: Ink) -> [OCRLine] {
        guard line.words.count >= 2 else { return [line] }
        let box = line.boundingBox
        let x0 = max(0, Int(box.minX * CGFloat(ink.width))), x1 = min(ink.width - 1, Int(box.maxX * CGFloat(ink.width)))
        let yTop = max(0, Int((1 - box.maxY) * CGFloat(ink.height))), yBottom = min(ink.height - 1, Int((1 - box.minY) * CGFloat(ink.height)))
        guard x1 - x0 > 4, yBottom - yTop > 2 else { return [line] }
        // The background is the most common grey in the line's box.
        var counts = [Int](repeating: 0, count: 256)
        for y in stride(from: yTop, through: yBottom, by: 2) { for x in stride(from: x0, through: x1, by: 2) { counts[Int(ink.at(x, y))] += 1 } }
        let background = counts.indices.max { counts[$0] < counts[$1] } ?? 255
        func blank(_ x: Int) -> Bool {
            for y in yTop...yBottom where abs(Int(ink.at(x, y)) - background) > 48 { return false }
            return true
        }
        // A space between words is about a third of the line's height; a column gap is wider.
        let gapMin = max(3, Int(Double(yBottom - yTop) * 0.55))
        var segments: [(Int, Int)] = []
        var start: Int? = nil, run = 0
        for x in x0...x1 {
            if blank(x) {
                run += 1
                if run == gapMin, let s = start { segments.append((s, x - gapMin)); start = nil }
            } else {
                if start == nil { start = x }
                run = 0
            }
        }
        if let s = start { segments.append((s, x1)) }
        guard segments.count >= 2 else { return [line] }
        // Each word goes to the segment over its middle (Vision's word boxes are loose, their middles aren't).
        var groups = [[OCRWord]](repeating: [], count: segments.count)
        for word in line.words {
            let mid = Int(word.boundingBox.midX * CGFloat(ink.width))
            let i = segments.indices.min { abs((segments[$0].0 + segments[$0].1) / 2 - mid) - (segments[$0].1 - segments[$0].0) / 2
                                           < abs((segments[$1].0 + segments[$1].1) / 2 - mid) - (segments[$1].1 - segments[$1].0) / 2 } ?? 0
            groups[i].append(word)
        }
        guard groups.allSatisfy({ !$0.isEmpty }) else { return [line] }
        return zip(segments, groups).map { segment, words in
            let rect = CGRect(x: CGFloat(segment.0) / CGFloat(ink.width), y: box.minY,
                              width: CGFloat(segment.1 - segment.0) / CGFloat(ink.width), height: box.height)
            return OCRLine(string: words.map(\.string).joined(separator: " "), boundingBox: rect, words: words)
        }
    }
}
