import Testing
import Foundation
import CoreServices
@testable import Lasso

@MainActor
struct DevSettingsImportTests {
    private func fresh() -> UserDefaults {
        let name = "tests.devimport.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func copiesTheInstalledAppsSettingsOnceWithoutOverwriting() {
        let dev = fresh()
        dev.set("mine", forKey: "chat.model")
        let release: [String: Any] = ["chat.model": "theirs", "ollama.autoStart": true]
        #expect(DevSettingsImport.run(into: dev, bundleID: "com.cjcarito.Lasso.dev", release: release) == 1)
        #expect(dev.string(forKey: "chat.model") == "mine")
        #expect(dev.bool(forKey: "ollama.autoStart"))
        // Once only: later changes in the installed app don't flow in.
        #expect(DevSettingsImport.run(into: dev, bundleID: "com.cjcarito.Lasso.dev", release: ["x": 1]) == 0)
        #expect(dev.object(forKey: "x") == nil)
    }

    @Test func theInstalledAppNeverImports() {
        let defaults = fresh()
        #expect(DevSettingsImport.run(into: defaults, bundleID: "com.cjcarito.Lasso", release: ["x": 1]) == 0)
        #expect(defaults.object(forKey: "x") == nil)
    }
}

struct PermissionResetTests {
    /// The real `tccutil`, on the test build's own ID (never the installed Lasso's). Launch Services
    /// ignores apps in /tmp, where test builds live, so this registers a copy in Caches first.
    @Test func resetsThisAppsOwnEntryWithoutAPassword() async throws {
        let id = try #require(Bundle.main.bundleIdentifier)
        #expect(id == "com.cjcarito.Lasso.dev", "tests must run as the dev app, or this would reset the installed Lasso")
        guard id == "com.cjcarito.Lasso.dev" else { return }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "lasso-tcc-test-\(UUID().uuidString.prefix(6))")
        let copy = folder.appending(path: "Lasso.app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: copy)
        defer {
            try? FileManager.default.removeItem(at: folder)
            LSRegisterURL(copy as CFURL, true)   // re-registering a deleted path drops it
        }
        LSRegisterURL(copy as CFURL, true)
        try await PermissionsService.tccReset("ScreenCapture", bundleID: id)
        try await PermissionsService.tccReset("Accessibility", bundleID: id)
    }

    @Test func aFailedResetSaysWhy() async {
        await #expect(throws: PermissionsService.ResetError.self) {
            try await PermissionsService.tccReset("ScreenCapture", bundleID: "com.cjcarito.NoSuchApp")
        }
    }
}
