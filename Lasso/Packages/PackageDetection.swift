import DataDetection
import Foundation

/// The kinds `when.detects` names, found in text: links, email, phones, addresses and dates come from
/// Foundation's detector (as Lasso's own pre-pass uses), flights, parcel tracking numbers and money
/// from Apple's DataDetection.
enum PackageDetection {
    static func kinds(in text: String) async -> Set<String> {
        guard !text.isEmpty else { return [] }
        let sample = String(text.prefix(10_000))
        var found = Set<String>()
        let types: NSTextCheckingResult.CheckingType = [.link, .phoneNumber, .address, .date]
        if let detector = try? NSDataDetector(types: types.rawValue) {
            detector.enumerateMatches(in: sample, range: NSRange(sample.startIndex..., in: sample)) { match, _, _ in
                guard let match else { return }
                switch match.resultType {
                case .link: found.insert(match.url?.scheme == "mailto" ? "email" : "link")
                case .phoneNumber: found.insert("phone")
                case .address: found.insert("address")
                case .date: found.insert("date")
                default: break
                }
            }
        }
        for await match in sample.dataDetectorMatches([.flightNumber, .shipmentTrackingNumber, .moneyAmount, .emailAddress]) {
            switch match.details {
            case .flightNumber: found.insert("flight")
            case .shipmentTrackingNumber: found.insert("tracking")
            case .moneyAmount: found.insert("money")
            case .emailAddress: found.insert("email")
            default: break
            }
        }
        return found
    }
}
