import AppKit

/// Checks a package's `requires` (spec, "Requirements"). Lasso never installs anything itself.
enum PackageRequirements {
    /// "Needs pandoc. Install it with: brew install pandoc", or nil when everything is there.
    static func missing(_ package: LassoPackage) async -> String? {
        for requirement in package.requires where !(await isMet(requirement)) {
            return sentence(requirement)
        }
        return nil
    }

    static func sentence(_ requirement: PackageRequirement) -> String {
        switch requirement {
        case .command(let name, let install):
            "Needs \(name)." + (install.map { " Install it with: \($0)" } ?? "")
        case .app(let id):
            "Needs the app \(appName(id))."
        }
    }

    static func name(_ requirement: PackageRequirement) -> String {
        switch requirement {
        case .command(let name, _): name
        case .app(let id): appName(id)
        }
    }

    static func appName(_ id: String) -> String {
        id.split(separator: ".").last.map(String.init) ?? id
    }

    static func isMet(_ requirement: PackageRequirement) async -> Bool {
        switch requirement {
        case .command(let name, _):
            return PackageScript.path.split(separator: ":").contains {
                FileManager.default.isExecutableFile(atPath: "\($0)/\(name)")
            }
        case .app(let id):
            return await MainActor.run { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil }
        }
    }

    /// Without waiting, for menus and Settings (the command check is a few file lookups).
    static func missingNow(_ package: LassoPackage) -> String? {
        for requirement in package.requires {
            let met: Bool = switch requirement {
            case .command(let name, _):
                PackageScript.path.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
            case .app(let id):
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
            }
            if !met { return sentence(requirement) }
        }
        return nil
    }
}
