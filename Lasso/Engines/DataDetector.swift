import Foundation

/// Wraps `NSDataDetector` to turn OCR text into tappable `DetectedItem`s (links, phones, …).
/// Cheap enough to run in the capture pre-pass.
actor DataDetector {
    private let detector: NSDataDetector? = {
        let types: NSTextCheckingResult.CheckingType = [.link, .phoneNumber, .address, .date]
        return try? NSDataDetector(types: types.rawValue)
    }()

    func detect(in text: String) -> [DetectedItem] {
        guard let detector, !text.isEmpty else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var items: [DetectedItem] = []

        detector.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match else { return }
            switch match.resultType {
            case .link:
                if let url = match.url {
                    let kind: DetectedKind = url.scheme == "mailto" ? .email : .url
                    items.append(DetectedItem(kind: kind, value: url.absoluteString, url: url))
                }
            case .phoneNumber:
                if let phone = match.phoneNumber {
                    let url = URL(string: "tel:\(phone.filter { !$0.isWhitespace })")
                    items.append(DetectedItem(kind: .phone, value: phone, url: url))
                }
            case .address:
                let value = (text as NSString).substring(with: match.range)
                let query = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                let url = URL(string: "https://maps.apple.com/?q=\(query)")
                items.append(DetectedItem(kind: .address, value: value, url: url))
            case .date:
                let value = (text as NSString).substring(with: match.range)
                items.append(DetectedItem(kind: .date, value: value, url: nil))
            default:
                break
            }
        }
        return items
    }
}
