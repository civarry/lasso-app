import AppKit
import KeyboardShortcuts
import SwiftUI

/// Package `hotkey` commands: a key the user assigns runs the command on the text highlighted in the
/// front app, the way Proofread highlighted text does (and with its clipboard handling).
@MainActor
final class PackageHotkeys {
    static let shared = PackageHotkeys()
    private init() {}

    private var registered: [KeyboardShortcuts.Name] = []
    private var running = false
    private var observer: NSObjectProtocol?

    static func name(_ package: String, _ command: String) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("pkg.\(package).\(command)")
    }

    /// Listen for every enabled hotkey command, and again whenever packages change.
    func start() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: PackageStore.didChange, object: nil, queue: .main) { _ in
            Task { @MainActor in PackageHotkeys.shared.refresh() }
        }
    }

    func refresh() {
        for name in registered { KeyboardShortcuts.removeHandler(for: name) }
        registered = []
        for item in PackageRegistry.shared.commands(for: .hotkey) {
            let name = Self.name(item.entry.package.id, item.command.id)
            KeyboardShortcuts.onKeyUp(for: name) { [packageID = item.entry.package.id, commandID = item.command.id] in
                Task { @MainActor in PackageHotkeys.shared.run(packageID, commandID) }
            }
            registered.append(name)
        }
    }

    /// Forget a removed package's keys (spec: cleared on Remove).
    static func clear(_ package: LassoPackage) {
        for command in package.commands where command.surfaces.contains(.hotkey) {
            KeyboardShortcuts.reset(name(package.id, command.id))
        }
    }

    func run(_ packageID: String, _ commandID: String) {
        guard !running,
              let item = PackageRegistry.shared.commands(for: .hotkey).first(where: { $0.entry.package.id == packageID && $0.command.id == commandID })
        else { return }
        running = true
        Task { await perform(item.entry, item.command); running = false }
    }

    private func perform(_ entry: PackageRegistry.Entry, _ command: PackageCommand) async {
        let fix = GrammarFixService.shared
        if let reason = PackageRegistry.shared.unavailableReason(entry, command) {
            StatusHUD.shared.show(icon: reason.hasPrefix("Paused") ? "lock.fill" : "exclamationmark.triangle",
                                  text: reason.hasPrefix("Paused") ? "\(command.title) is paused in local-only mode." : reason, persist: 4)
            return
        }
        guard fix.ensureAccessibility() else {
            StatusHUD.shared.show(icon: "lock.shield", text: "Enable Accessibility for Lasso in System Settings, then try again.", persist: 4)
            fix.openAccessibilitySettings()
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        let before = pb.changeCount
        fix.sendKey(fix.keyC)
        guard let selected = await fix.readClipboard(changedFrom: before),
              !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            StatusHUD.shared.show(icon: "text.cursor", text: "Select some text first.", persist: 2)
            fix.restore(saved, to: pb)
            return
        }
        if let when = command.when,
           !when.holds(text: selected, detected: when.needsDetection ? await PackageDetection.kinds(in: selected) : [],
                       bundleID: front?.bundleIdentifier, hasImage: false) {
            StatusHUD.shared.show(icon: "text.cursor", text: Self.whenRefusal(when, command: command, text: selected, app: front?.localizedName), persist: 2)
            fix.restore(saved, to: pb)
            return
        }
        let editable = command.output == .replace ? fix.isSelectionEditable() : false
        StatusHUD.shared.show(icon: "", text: "\(command.title)…", spinner: true)
        let input = PackageInput(text: selected, sourceApp: front?.localizedName, sourceBundleID: front?.bundleIdentifier)
        do {
            let result = try await PackageCommandRunner.run(entry, command, input: input)
            switch command.output {
            case .replace:
                let text = try await PackageOutput.text(result).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty || text == selected.trimmingCharacters(in: .whitespacesAndNewlines) || fix.looksLikeRefusal(text) {
                    StatusHUD.shared.show(icon: "checkmark", text: "Nothing to change.", persist: 1.5)
                    fix.restore(saved, to: pb)
                } else if editable {
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    fix.sendKey(fix.keyV)
                    StatusHUD.shared.show(icon: "checkmark.circle.fill", text: "Replaced. ⌘Z to undo", persist: 2)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    fix.restore(saved, to: pb)
                } else {
                    // Read-only text: show it to copy instead, as Proofread does.
                    fix.restore(saved, to: pb)
                    StatusHUD.shared.hide()
                    FloatingPanelController.shared.present(
                        AnyView(FloatingResultView(title: command.title, result: .text(text),
                                                   attribution: PackageOutput.attribution(entry, command))), anchor: nil)
                }
            case .markdown:
                fix.restore(saved, to: pb)
                StatusHUD.shared.hide()
                let shown: ActionResult = switch result {
                case .stream(let s): .stream(s)
                case .text(let t): .text(t)
                case .url(let u): .text(u.absoluteString)
                }
                FloatingPanelController.shared.present(
                    AnyView(FloatingResultView(title: command.title, result: shown,
                                               attribution: PackageOutput.attribution(entry, command))), anchor: nil)
            default:
                fix.restore(saved, to: pb)
                await PackageOutput.deliver(result, output: command.output, title: command.title)
            }
        } catch {
            fix.restore(saved, to: pb)
            StatusHUD.shared.show(icon: "exclamationmark.triangle", text: PackageOutput.failure(error, entry, command), persist: 4)
        }
    }

    /// Why a hotkey didn't run on this text, in the user's terms.
    static func whenRefusal(_ when: PackageWhen, command: PackageCommand, text: String, app: String?) -> String {
        if let min = when.minLength, text.count < min { return "Select at least \(min) characters." }
        if let max = when.maxLength, text.count > max { return "Select at most \(max) characters." }
        if !when.apps.isEmpty { return "\(command.title) doesn't run in \(app ?? "this app")." }
        return "\(command.title) doesn't apply to this text."
    }
}
