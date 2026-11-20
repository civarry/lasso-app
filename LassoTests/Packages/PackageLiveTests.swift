import Foundation
import Testing
@testable import Lasso

/// A search package against a real service over the internet: Wikipedia's search API, keyless, so no
/// one's quota is spent. Opt-in: TEST_RUNNER_LASSO_PACKAGES_LIVE=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LASSO_PACKAGES_LIVE"] == "1"))
struct PackageLiveTests {
    static let wikipedia = """
    {"lasso": 1, "id": "wikipedia-search", "version": "1.0.0", "name": "Wikipedia", "author": "Lasso",
     "summary": "Encyclopedia articles for a search.", "category": "knowledge",
     "icon": {"symbol": "book.closed", "domain": "wikipedia.org"},
     "hosts": ["en.wikipedia.org"],
     "commands": [{"id": "search", "title": "Wikipedia", "surfaces": ["search"], "input": ["query"], "output": "results",
       "run": {"http": {"url": "https://en.wikipedia.org/w/api.php",
                        "query": {"action": "query", "list": "search", "format": "json", "srlimit": "5", "srsearch": "{{query}}"}},
               "role": "reserve",
               "results": {"list": "query.search", "title": "title", "snippet": "snippet", "limit": 5}},
       "test": {"query": "lasso"}}]}
    """

    @Test func aRealSearchPackageReturnsResults() async throws {
        let package = try #require(PackageValidator.validate(Data(Self.wikipedia.utf8)).package)
        let entry = PackageRegistry.Entry(package: package, values: [:], secrets: [], ready: true)
        let hits = await PackageSearch.run(entry, package.commands[0], query: "Ada Lovelace")
        print("[package-live] \(hits.map(\.title))")
        #expect(hits.contains { $0.title.contains("Ada Lovelace") })
        #expect(hits.allSatisfy { $0.source == "Wikipedia" })
    }
}
