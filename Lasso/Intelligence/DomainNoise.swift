import Foundation

/// Hosts that may *contain* an image but don't help identify its subject — stock-photo libraries,
/// marketplaces, and social/video sites. Stock hosts especially mislead synthesis ("it's a
/// Shutterstock page") so we filter them from both reverse-image matches and web results.
enum DomainNoise {
    private static let blocked = [
        // stock photo / media libraries
        "shutterstock.", "gettyimages.", "istockphoto.", "alamy.", "dreamstime.",
        "depositphotos.", "123rf.", "stock.adobe.", "freepik.", "vecteezy.",
        "pexels.", "unsplash.", "pixabay.", "canstockphoto.", "bigstockphoto.",
        // marketplaces
        "amazon.", "etsy.", "aliexpress.", "ebay.", "walmart.", "temu.", "alibaba.",
        "redbubble.", "lazada.", "shopee.",
        // social / video
        "pinterest.", "facebook.", "instagram.", "tiktok.", "youtube.",
        // wallpapers
        "wallpaper",
    ]

    static func isNoise(_ host: String) -> Bool {
        let h = host.lowercased()
        return blocked.contains { h.contains($0) }
    }
}
