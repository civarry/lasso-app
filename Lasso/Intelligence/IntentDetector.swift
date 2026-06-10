import Foundation

/// What the user most likely captured. Drives connector routing (don't fire web/reverse-image for a
/// block of text) and sharpens the synthesis prompt.
enum IdentifyIntent: String {
    // Visual subjects — worth reaching out (reverse-image + web).
    case product, place, person, plant, animal, food, artwork, brand, object
    // Textual content — local summarize/translate is the point; outward search just adds noise.
    case text, code, ui
    case unknown

    /// Clearly-textual captures suppress outward sources.
    var suppressesSources: Bool { self == .text || self == .code || self == .ui }
    var needsReverseImage: Bool { !suppressesSources }
    var needsWeb: Bool { !suppressesSources }

    /// Human label for the synthesis prompt (empty when we shouldn't bias the model).
    var label: String {
        switch self {
        case .product: "a product"
        case .place: "a place or landmark"
        case .person: "a person"
        case .plant: "a plant"
        case .animal: "an animal"
        case .food: "food or a dish"
        case .artwork: "artwork"
        case .brand: "a logo or brand"
        case .object: "an object"
        case .text, .code, .ui, .unknown: ""
        }
    }
}

/// Classifies a selection into an `IdentifyIntent` with simple, local rules — no model, no network.
/// Text-heavy captures are textual; otherwise we keyword-match the vision model's description into a
/// coarse category (used only as a synthesis hint — routing just needs visual-vs-textual).
enum IntentDetector {
    static func detect(visionText: String, ocrText: String?, hasStrongText: Bool) -> IdentifyIntent {
        if hasStrongText {
            return looksLikeCode(ocrText ?? "") ? .code : .text
        }
        let reference = (visionText.isEmpty ? (ocrText ?? "") : visionText).lowercased()
        guard !reference.isEmpty else { return .unknown }
        return categorize(reference)
    }

    /// Ordered keyword buckets — first match wins (more specific categories first).
    private static let buckets: [(IdentifyIntent, [String])] = [
        (.person, ["person", "man", "woman", "face", "portrait", "people", "actor", "celebrity", "selfie"]),
        (.food, ["food", "dish", "meal", "drink", "coffee", "cake", "pizza", "burger", "recipe", "plate of"]),
        (.plant, ["plant", "flower", "tree", "leaf", "succulent", "fern", "bouquet", "garden"]),
        (.animal, ["animal", "dog", "cat", "bird", "fish", "insect", "pet", "horse", "wildlife"]),
        (.brand, ["logo", "brand", "trademark", "emblem", "wordmark"]),
        (.artwork, ["painting", "drawing", "illustration", "artwork", "sketch", "poster", "graphic", "diagram"]),
        (.place, ["building", "landmark", "city", "mountain", "beach", "street", "architecture",
                  "interior", "room", "landscape", "skyline"]),
        (.product, ["product", "device", "gadget", "phone", "smartphone", "laptop", "bottle",
                    "packaging", "box", "appliance", "shoe", "watch", "headphone", "car"]),
    ]

    private static func categorize(_ text: String) -> IdentifyIntent {
        for (intent, words) in buckets where words.contains(where: { text.contains($0) }) { return intent }
        return .object
    }

    private static func looksLikeCode(_ text: String) -> Bool {
        let signals = ["func ", "def ", "import ", "const ", "let ", "var ", "class ", "</", "=>",
                       "{\n", "});", "();", "() {", "public ", "private "]
        return signals.filter { text.contains($0) }.count >= 2
    }
}
