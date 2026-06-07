import WebKit

/// Shared setup for the hidden helper WebViews (TinEye / Reddit). We only read text/JSON from them,
/// so we block image/media/font loads — this removes "WEBP initImage failed" log spam and ATS
/// http-image warnings, and trims the memory spikes from decoding assets we never show.
@MainActor
enum WebScraper {
    private static var ruleList: WKContentRuleList?

    /// Add the media-blocking rule to `webView`, then run `load` (compiles once, then cached).
    static func loadBlockingMedia(_ webView: WKWebView, then load: @escaping () -> Void) {
        if let ruleList {
            webView.configuration.userContentController.add(ruleList)
            load()
            return
        }
        let rules = #"[{"trigger":{"url-filter":".*","resource-type":["image","media","font"]},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "lasso-block-media", encodedContentRuleList: rules
        ) { list, _ in
            if let list {
                ruleList = list
                webView.configuration.userContentController.add(list)
            }
            load()
        }
    }
}
