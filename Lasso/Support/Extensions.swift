import CoreGraphics
import Foundation
import AppKit

extension CGImage {
    /// Crop to a rect expressed in the image's own pixel coordinate space.
    func cropping(toPixelRect rect: CGRect) -> CGImage? {
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }
        return cropping(to: clamped.integral)
    }

    /// Downscale so the longest edge is at most `maxEdge` pixels. Returns self if already small.
    func downscaled(maxEdge: Int) -> CGImage {
        let longest = max(width, height)
        guard longest > maxEdge else { return self }
        let scale = CGFloat(maxEdge) / CGFloat(longest)
        let newW = Int((CGFloat(width) * scale).rounded())
        let newH = Int((CGFloat(height) * scale).rounded())
        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return self }
        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? self
    }

    /// Color of a single pixel (in pixel coordinates), if readable.
    func pixelColor(atX x: Int, y: Int) -> NSColor? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        guard let data = dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        let bpp = bitsPerPixel / 8
        let offset = y * bytesPerRow + x * bpp
        // Best-effort: assumes 8-bit RGBA/ARGB-ish layouts produced by ScreenCaptureKit.
        let b0 = CGFloat(ptr[offset]) / 255.0
        let b1 = CGFloat(ptr[offset + 1]) / 255.0
        let b2 = CGFloat(ptr[offset + 2]) / 255.0
        let order = bitmapInfo.intersection(.byteOrderMask)
        if order == .byteOrder32Little {
            // BGRA
            return NSColor(srgbRed: b2, green: b1, blue: b0, alpha: 1)
        }
        return NSColor(srgbRed: b0, green: b1, blue: b2, alpha: 1)
    }

    var nsImage: NSImage {
        NSImage(cgImage: self, size: NSSize(width: width, height: height))
    }
}

extension NSColor {
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    var rgbString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "rgb(0, 0, 0)" }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return "rgb(\(r), \(g), \(b))"
    }

    var swiftUIColorString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "Color.black" }
        let r = String(format: "%.3f", rgb.redComponent)
        let g = String(format: "%.3f", rgb.greenComponent)
        let b = String(format: "%.3f", rgb.blueComponent)
        return "Color(red: \(r), green: \(g), blue: \(b))"
    }
}
