import AppKit
import CoreGraphics

/// Layout for the translation overlay: one opaque plate per translated block, covering the whole
/// block so none of the original shows around it, grown downward when the translation needs more room
/// and pushed down past any plate it would otherwise overlap. Pure, so the no-overlap rule is tested.
enum PlateLayout {
    enum Content: Equatable {
        /// Already in the target language (or nothing to translate): no plate at all. Painting over
        /// text that did not change is just covering it.
        case untranslated
        /// Waiting on pass 1: a skeleton plate the size of the block.
        case pending
        case text(String)
    }

    struct Input {
        let id: UUID
        /// The block's frame in view points (top-left origin).
        let frame: CGRect
        let lineCount: Int
        let content: Content
    }

    struct Plate: Equatable {
        let id: UUID
        let rect: CGRect
        let fontSize: CGFloat
        /// nil for a pending (skeleton) plate.
        let text: String?
    }

    static let outset: CGFloat = 2
    static let padding = CGSize(width: 4, height: 2)
    static let fontRange: ClosedRange<CGFloat> = 12...24

    /// `measure(text, width, fontSize)` returns the height the text needs wrapped to `width`.
    /// `bounds` is the selection: a plate may widen into empty space up to its right edge.
    static func layout(_ inputs: [Input], bounds: CGRect,
                       measure: (String, CGFloat, CGFloat) -> CGFloat) -> [Plate] {
        var placed: [Plate] = []
        for input in inputs {
            var rect = input.frame.insetBy(dx: -outset, dy: -outset)
            let lineHeight = input.frame.height / CGFloat(max(1, input.lineCount))
            let startSize = min(fontRange.upperBound, max(fontRange.lowerBound, lineHeight * 0.7))
            var fontSize = startSize
            var text: String?

            switch input.content {
            case .untranslated:
                continue
            case .pending:
                break
            case .text(let t):
                text = t
                // Largest size that fits `width` within the block's height, or nil if none does.
                func fitting(_ width: CGFloat) -> CGFloat? {
                    var size = startSize
                    while true {
                        if measure(t, width - 2 * padding.width, size) <= rect.height - 2 * padding.height { return size }
                        if size <= fontRange.lowerBound { return nil }
                        size = max(fontRange.lowerBound, size - 1)
                    }
                }
                if let size = fitting(rect.width) {
                    fontSize = size
                } else {
                    // Too long for the block. Growing down would push the next plate off its text, so
                    // first widen into the empty space beside it (a translation is often wider than a
                    // short heading), and only as much as it needs.
                    let maxWidth = rightLimit(for: input, rect: rect, among: inputs, bounds: bounds) - rect.minX
                    if maxWidth > rect.width, let size = fitting(maxWidth) {
                        var lo = rect.width, hi = maxWidth
                        while hi - lo > 2 {
                            let mid = (lo + hi) / 2
                            if let s = fitting(mid), s >= size { hi = mid } else { lo = mid }
                        }
                        rect.size.width = ceil(hi)
                        fontSize = fitting(rect.width) ?? size
                    } else {
                        // No room beside it either: widen as far as it can, then grow down.
                        rect.size.width = max(rect.width, maxWidth)
                        fontSize = fontRange.lowerBound
                        let needed = measure(t, rect.width - 2 * padding.width, fontSize)
                        rect.size.height = max(rect.height, ceil(needed) + 2 * padding.height)
                    }
                }
            }

            // Push down past every earlier plate this one would overlap, in reading order, until it
            // overlaps none. Each push moves strictly down, so this terminates.
            var moved = true
            while moved {
                moved = false
                for other in placed where other.rect.intersects(rect)
                    && other.rect.intersection(rect).width > 0 && other.rect.intersection(rect).height > 0 {
                    rect.origin.y = other.rect.maxY
                    moved = true
                }
            }
            placed.append(Plate(id: input.id, rect: rect, fontSize: fontSize, text: text))
        }
        return placed
    }

    /// How far right a plate may widen: the selection's edge, or just short of the nearest block
    /// beside it (translated or not: an untranslated one's text must stay visible).
    private static func rightLimit(for input: Input, rect: CGRect, among inputs: [Input],
                                   bounds: CGRect) -> CGFloat {
        var limit = bounds.maxX
        for other in inputs where other.id != input.id {
            let f = other.frame
            guard f.minX >= input.frame.maxX, f.maxY > rect.minY, f.minY < rect.maxY else { continue }
            limit = min(limit, f.minX - 2 * outset)
        }
        return max(limit, rect.maxX)
    }

    /// Height AppKit needs to draw `text` in the plate's font at `width`. Slightly generous: SwiftUI's
    /// `Text` and AppKit's measurement disagree by a point or so.
    static func appKitMeasure(_ text: String, width: CGFloat, fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        return ceil(bounds.height) + 2
    }
}

/// Picks a plate colour from the capture itself: the median of pixels just outside a block's frame,
/// so a plate on a light page is light. Nil when the surround is mixed (an image, a gradient), where
/// the caller keeps its plain dark plate.
struct PlateBackgroundSampler {
    struct RGB: Equatable {
        let r: Double, g: Double, b: Double
        var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    }

    private let pixels: [UInt8]
    private let width: Int
    private let height: Int

    init?(image: CGImage) {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        pixels = buffer; width = w; height = h
    }

    init(pixels: [UInt8], width: Int, height: Int) {
        self.pixels = pixels; self.width = width; self.height = height
    }

    /// `frame` is normalized with a bottom-left origin (Vision's convention). The bitmap context above
    /// also has a bottom-left origin in user space, but its memory rows run top-down, so row 0 is the
    /// top of the image.
    func background(around frame: CGRect) -> RGB? {
        let x0 = frame.minX * CGFloat(width), x1 = frame.maxX * CGFloat(width)
        let yTop = (1 - frame.maxY) * CGFloat(height), yBottom = (1 - frame.minY) * CGFloat(height)
        let off: CGFloat = 3
        var samples: [RGB] = []
        for i in 0..<8 {
            let t = (CGFloat(i) + 0.5) / 8
            let x = x0 + (x1 - x0) * t, y = yTop + (yBottom - yTop) * t
            for (px, py) in [(x, yTop - off), (x, yBottom + off), (x0 - off, y), (x1 + off, y)] {
                if let s = sample(px, py) { samples.append(s) }
            }
        }
        guard samples.count >= 8 else { return nil }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let m = RGB(r: median(samples.map(\.r)), g: median(samples.map(\.g)), b: median(samples.map(\.b)))
        let close = samples.filter { abs($0.r - m.r) + abs($0.g - m.g) + abs($0.b - m.b) < 0.12 }.count
        return Double(close) / Double(samples.count) >= 0.7 ? m : nil
    }

    private func sample(_ x: CGFloat, _ y: CGFloat) -> RGB? {
        let ix = Int(x.rounded(.down)), iy = Int(y.rounded(.down))
        guard ix >= 0, iy >= 0, ix < width, iy < height else { return nil }
        let o = (iy * width + ix) * 4
        return RGB(r: Double(pixels[o]) / 255, g: Double(pixels[o + 1]) / 255, b: Double(pixels[o + 2]) / 255)
    }
}
