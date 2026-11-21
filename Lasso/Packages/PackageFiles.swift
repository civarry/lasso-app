import CryptoKit
import Foundation

/// A package folder's files: read, hashed and checked the same way by Lasso and `lasso-pkg`.
enum PackageFiles {
    /// Files beside the manifest (`scripts/…`, a README), by path inside the package.
    typealias Files = [String: Data]

    struct Invalid: Error { var problems: [PackageProblem] }

    static let maxFolderBytes = 5 * 1024 * 1024

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Everything in a package folder but `lasso.json`: no hidden files, no links, at most 5 MB.
    static func read(_ folder: URL) throws -> Files {
        let fm = FileManager.default
        var out: Files = [:], total = 0
        let base = folder.resolvingSymlinksInPath().path + "/"
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                         options: [.skipsHiddenFiles]) else { return [:] }
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw Invalid(problems: [PackageProblem(path: url.lastPathComponent, message: "Links aren't allowed in a package.")]) }
            guard values.isRegularFile == true else { continue }
            let path = String(url.resolvingSymlinksInPath().path.dropFirst(base.count))
            guard path != "lasso.json" else { continue }
            let data = try Data(contentsOf: url)
            total += data.count
            guard total <= maxFolderBytes else { throw Invalid(problems: [PackageProblem(path: "", message: "The package folder is over 5 MB.")]) }
            out[path] = data
        }
        return out
    }

    static func hashes(_ files: Files) -> [String: String] { files.mapValues(sha256) }

    /// The manifest's hash, with every file's when there are any (a script changed on disk counts).
    static func contentHash(_ manifest: Data, _ files: Files) -> String {
        guard !files.isEmpty else { return sha256(manifest) }
        let list = hashes(files).sorted { $0.key < $1.key }.map { "\($0.key)\u{0}\($0.value)" }.joined(separator: "\n")
        return sha256(manifest + Data(list.utf8))
    }

    /// Problems with the files a manifest names: each script must be in the package and start with `#!`.
    static func problems(_ package: LassoPackage, _ files: Files) -> [PackageProblem] {
        var out: [PackageProblem] = []
        for (i, command) in package.commands.enumerated() {
            guard let script = command.script else { continue }
            let at = "commands[\(i)].run.script.path"
            guard let data = files[script.path] else {
                out.append(PackageProblem(path: at, message: "\(script.path) isn't in the package. Add the package folder, not only its lasso.json."))
                continue
            }
            if !data.starts(with: Data("#!".utf8)) { out.append(PackageProblem(path: at, message: "\(script.path) must start with a #! line.")) }
        }
        return out
    }
}
