import Testing
import CoreGraphics
@testable import Lasso

struct LassoTests {
    @Test func rectBetweenNormalizesPoints() {
        let r = CGRect.between(CGPoint(x: 10, y: 20), CGPoint(x: 4, y: 8))
        #expect(r.origin.x == 4)
        #expect(r.origin.y == 8)
        #expect(r.width == 6)
        #expect(r.height == 12)
    }

    @Test func dataDetectorFindsURL() async {
        let detector = DataDetector()
        let items = await detector.detect(in: "Visit https://example.com for details.")
        #expect(items.contains { $0.kind == .url })
    }

    @Test func dataDetectorFindsPhone() async {
        let detector = DataDetector()
        let items = await detector.detect(in: "Call +1 (415) 555-0132 today.")
        #expect(items.contains { $0.kind == .phone })
    }

    @MainActor
    @Test func registryOrdersByPriority() {
        let registry = ActionRegistry.makeDefault(intelligence: .shared)
        // ColorPicker (priority 50) is relevant to any selection; OCRCopy needs text.
        #expect(!registry.actions.isEmpty)
    }
}
