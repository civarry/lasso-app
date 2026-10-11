import CoreGraphics
import Foundation
import Vision

/// Detects QR codes / barcodes in a frozen crop and returns their payloads.
actor BarcodeEngine {
    func detect(in image: CGImage) async throws -> [DetectedItem] {
        let request = DetectBarcodesRequest()
        let observations = try await request.perform(on: image)

        return observations.compactMap { obs -> DetectedItem? in
            guard let payload = obs.payloadString, !payload.isEmpty else { return nil }
            // QR codes most commonly carry URLs; treat a parseable http(s) payload as a link.
            let isQR = obs.symbology == .qr || obs.symbology == .microQR
            if let url = URL(string: payload), url.scheme?.hasPrefix("http") == true {
                return DetectedItem(kind: isQR ? .qr : .barcode, value: payload, url: url)
            }
            return DetectedItem(kind: isQR ? .qr : .barcode, value: payload, url: nil)
        }
    }
}


