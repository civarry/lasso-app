import AppKit
import SwiftUI

/// Where package commands show up (build step 2): the capture toolbar, Send to, chat `/commands` and
/// hotkeys on highlighted text. Designed with a separate UI/UX review (`docs/APP_FLOW.md`).

extension PackageRegistry {
    /// Enabled commands on `surface`, with their package.
    func commands(for surface: PackageCommand.Surface) -> [(entry: Entry, command: PackageCommand)] {
        all.flatMap { entry in entry.package.commands.filter { $0.surfaces.contains(surface) }.map { (entry, $0) } }
            .sorted { ($0.entry.package.name, $0.entry.package.commands.firstIndex(of: $0.command) ?? 0)
                < ($1.entry.package.name, $1.entry.package.commands.firstIndex(of: $1.command) ?? 0) }
    }

    /// Why a command can't run right now (nil when it can): a missing key or setting, or local-only
    /// mode pausing a request that leaves the Mac.
    func unavailableReason(_ entry: Entry, _ command: PackageCommand, localOnly: Bool = PrivacyMode.localOnly) -> String? {
        if !entry.ready {
            let missing = entry.package.settings.first { setting in
                setting.kind != .toggle && setting.kind != .choice && (entry.values["settings.\(setting.id)"] ?? "").isEmpty
            }
            switch missing?.kind {
            case .folder?: return "Choose its \(missing!.label.lowercased()) in Settings › Packages."
            case .secret?: return "Add its API key in Settings › Packages."
            default: return "Finish setting it up in Settings › Packages."
            }
        }
        if let why = PackageRequirements.missingNow(entry.package) { return why }
        if localOnly, command.http != nil,
           !PackageHTTP.allowedHosts(entry.package, values: entry.values).allSatisfy(PackageValidator.isLoopback) {
            return "Paused in local-only mode."
        }
        if let shortcut = command.shortcut {
            if localOnly, !shortcut.offline { return "Paused in local-only mode." }
            if PackageShortcut.isInstalledNow(shortcut.name) == false {
                return "Get the Shortcut “\(shortcut.name)” from \(entry.package.name)'s page in Settings › Packages."
            }
        }
        return nil
    }

    /// The `/name` each slash command answers to. Lasso's own names are reserved; two packages using
    /// the same id both become `/<package-id>-<id>`.
    static let reservedSlashNames: Set<String> = ["new", "clear", "copy", "about", "web", "help"]

    func slashCommands() -> [(name: String, entry: Entry, command: PackageCommand)] {
        let list = commands(for: .slash)
        var counts: [String: Int] = [:]
        for item in list { counts[item.command.id, default: 0] += 1 }
        return list.map { item in
            let clash = (counts[item.command.id] ?? 0) > 1 || Self.reservedSlashNames.contains(item.command.id)
            return (clash ? "/\(item.entry.package.id)-\(item.command.id)" : "/\(item.command.id)", item.entry, item.command)
        }
    }
}

extension PackageWhen {
    /// The conditions that hide a command (everything but length, which only greys it).
    func holdsIgnoringLength(text: String, detected: Set<String>, bundleID: String?, hasImage: Bool) -> Bool {
        var copy = self
        copy.minLength = nil
        copy.maxLength = nil
        return copy.holds(text: text, detected: detected, bundleID: bundleID, hasImage: hasImage)
    }

    /// "Select more text." / "Select less text." when only length fails.
    func lengthProblem(_ text: String) -> String? {
        if let minLength, text.count < minLength { return "Select more text." }
        if let maxLength, text.count > maxLength { return "Select less text." }
        return nil
    }

    /// Whether this needs the slower detection pass (flights, tracking numbers, money).
    var needsDetection: Bool { !detects.isEmpty }
}

/// What a finished command does with its result, for every surface but chat (which shows a reply).
@MainActor
enum PackageOutput {
    /// Copy / open / notify. Returns false when there was nothing to act on (and says so).
    @discardableResult
    static func deliver(_ result: PackageCommandResult, output: PackageCommand.Output, title: String) async -> Bool {
        switch output {
        case .open:
            guard case .url(let url) = result else { StatusHUD.shared.show(icon: "exclamationmark.triangle", text: "No page to open.", persist: 2); return false }
            NSWorkspace.shared.open(url)
            StatusHUD.shared.hide()
            return true
        case .copy:
            guard let text = try? await text(result), !text.isEmpty else {
                StatusHUD.shared.show(icon: "exclamationmark.triangle", text: "Nothing to copy.", persist: 2); return false
            }
            Pasteboard.copy(text)
            StatusHUD.shared.show(icon: "checkmark.circle.fill", text: "Copied", persist: 1.2)
            return true
        case .notify:
            let text = (try? await text(result)) ?? ""
            StatusHUD.shared.show(icon: "checkmark.circle.fill", text: notifyText(text), persist: 1.5)
            return true
        case .file, .image:
            guard case .file(let url) = result else {
                StatusHUD.shared.show(icon: "exclamationmark.triangle", text: "No file came back.", persist: 2); return false
            }
            showFile(url, asImage: output == .image)
            return true
        default:
            return false
        }
    }

    /// A saved image opens in Lasso's viewer; any other file is shown in Finder.
    static func showFile(_ url: URL, asImage: Bool) {
        if asImage, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            StatusHUD.shared.hide()
            ImageViewer.shared.show(image, title: url.lastPathComponent, file: url)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        StatusHUD.shared.show(icon: "checkmark.circle.fill", text: "Saved \(url.lastPathComponent)", persist: 1.5)
    }

    /// Where a saved file is, as people say it: "~/LassoWorkspace/table-to-csv/table.csv".
    static func shortPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    /// The `answer` when it's short enough to read at a glance, otherwise "Done".
    static func notifyText(_ answer: String) -> String {
        let line = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty || line.count > 60 || line.contains("\n") ? "Done" : line
    }

    static func text(_ result: PackageCommandResult) async throws -> String {
        switch result {
        case .text(let t): return t
        case .url(let u): return u.absoluteString
        case .file(let u): return shortPath(u)
        case .stream(let s): return try await PackageCommandRunner.collect(s)
        case .console(let c): return c.text
        }
    }

    /// "Study tools · api.example.com" for http, "Study tools" for prompt (the result card adds the model).
    static func attribution(_ entry: PackageRegistry.Entry, _ command: PackageCommand) -> String {
        if let shortcut = command.shortcut { return "\(entry.package.name) · Shortcut “\(shortcut.name)”" }
        if command.script != nil { return "\(entry.package.name) · script on this Mac" + (entry.fullAccess ? " (full access)" : "") }
        if command.http != nil, let host = PackageHTTP.allowedHosts(entry.package, values: entry.values).sorted().first {
            return "\(entry.package.name) · \(host)"
        }
        return entry.package.name
    }

    /// Human wording for a failure, with secrets out.
    static func failure(_ error: Error, _ entry: PackageRegistry.Entry, _ command: PackageCommand) -> String {
        let host = PackageHTTP.allowedHosts(entry.package, values: entry.values).sorted().first ?? entry.package.name
        let message: String
        switch error {
        case PackageHTTP.RunError.status(401), PackageHTTP.RunError.status(403):
            message = "\(host) refused the key. Check it in Settings › Packages."
        case PackageHTTP.RunError.status(429):
            message = "\(entry.package.name) is rate limiting. Try again later."
        case PackageHTTP.RunError.failed(let reason) where reason.localizedCaseInsensitiveContains("timed out"):
            message = "\(host) didn't answer in \(Int(command.http?.timeout ?? 8)) seconds."
        case PackageHTTP.RunError.failed:
            message = "Couldn't reach \(host)."
        default:
            message = error.localizedDescription
        }
        return PackageHTTP.redact(message, secrets: entry.secrets)
    }
}

/// A package `toolbar` command as a capture-bar action.
struct PackageCommandAction: CaptureAction {
    let entry: PackageRegistry.Entry
    let command: PackageCommand

    static func id(_ package: String, _ command: String) -> String { "pkg:\(package)/\(command)" }

    var id: String { Self.id(entry.package.id, command.id) }
    var title: String { command.title }
    var systemImage: String { command.symbol ?? entry.package.iconSymbol ?? "shippingbox" }
    /// After Lasso's own (Copy image and Save image are 60 and 61, Send to 62).
    var relevancePriority: Int { 70 }
    var resultAttribution: String? { PackageOutput.attribution(entry, command) }

    func isRelevant(to ctx: CaptureContext) -> Bool {
        guard let when = command.when else { return true }
        // Before the pre-pass there's no text to test: offer nothing yet rather than flash a pill.
        guard ctx.ocrText != nil || when.hasImage == true else { return when.match == nil && when.detects.isEmpty }
        return when.holdsIgnoringLength(text: ctx.ocrText ?? "", detected: ctx.packageKinds,
                                        bundleID: ctx.sourceBundleID, hasImage: ctx.ocrText == nil)
    }

    func disabledReason(for ctx: CaptureContext, visionAvailable: Bool) -> String? {
        if let reason = PackageRegistry.shared.unavailableReason(entry, command) { return reason }
        let text = ctx.ocrText ?? ""
        if command.input.contains(.text), text.isEmpty { return "No text in this selection." }
        if command.input.contains(.table), ctx.tableText == nil { return "Lasso a table: rows and columns." }
        return command.when?.lengthProblem(text)
    }

    func perform(_ ctx: CaptureContext) async throws -> ActionResult {
        let input = PackageInput(text: ctx.ocrText, sourceApp: ctx.sourceApp, sourceBundleID: ctx.sourceBundleID,
                                 table: ctx.tableText, image: command.input.contains(.image) ? PackageInput.png(ctx.image) : nil,
                                 lines: ctx.ocrLines)
        if command.output != .markdown {
            StatusHUD.shared.show(icon: "", text: "\(command.title)…", spinner: true)
        }
        do {
            let result = try await PackageCommandRunner.run(entry, command, input: input)
            switch command.output {
            case .markdown:
                switch result {
                case .stream(let s): return .stream(s)
                case .text(let t): return .text(t)
                case .url(let u): return .text(u.absoluteString)
                case .file(let u): return .text(PackageOutput.shortPath(u))
                case .console(let c): return .text(c.text)
                }
            case .open:
                await PackageOutput.deliver(result, output: .open, title: command.title)
                if case .url(let url) = result { return .openedURL(url) }
                return .none
            default:
                await PackageOutput.deliver(result, output: command.output, title: command.title)
                return .none
            }
        } catch {
            let message = PackageOutput.failure(error, entry, command)
            if command.output == .markdown { throw PackageFailure(message: message) }
            StatusHUD.shared.show(icon: "exclamationmark.triangle", text: message, persist: 4)
            return .none
        }
    }
}

/// A failure already worded for people (the result card shows `localizedDescription`).
struct PackageFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
