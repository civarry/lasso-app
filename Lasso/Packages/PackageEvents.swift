import Foundation

/// Event commands (the `event` surface): a package command that runs by itself after a capture is read
/// or a chat reply finishes. Only once the user turns on **Run automatically** on its page: off by
/// default, per package, never set by a package, and off again when an update changes what runs.
/// Each run is the same as a click: same sandbox, local-only gate, keys and limits.
@MainActor
enum PackageEvents {
    private static func key(_ id: String) -> String { "packages.\(id).events" }

    static func isAllowed(_ id: String, _ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: key(id)) }
    static func setAllowed(_ on: Bool, _ id: String, _ defaults: UserDefaults = .standard) { defaults.set(on, forKey: key(id)) }

    /// The event commands that would run now for `event`.
    static func commands(for event: PackageCommand.Event, registry: PackageRegistry = .shared,
                         defaults: UserDefaults = .standard) -> [(entry: PackageRegistry.Entry, command: PackageCommand)] {
        registry.commands(for: .event).filter { item in
            item.command.on.contains(event) && isAllowed(item.entry.package.id, defaults)
                && registry.unavailableReason(item.entry, item.command) == nil
        }
    }

    static var anyFor: (PackageCommand.Event) -> Bool = { !commands(for: $0).isEmpty }

    /// Runs each allowed command for `event` in the background. Output: a short notify line shows, a
    /// file is saved to the workspace quietly; failures are logged, never shown mid-task.
    static func fire(_ event: PackageCommand.Event, input: @autoclosure () -> PackageInput,
                     registry: PackageRegistry = .shared) {
        let list = commands(for: event, registry: registry)
        guard !list.isEmpty else { return }
        let built = input()
        for (entry, command) in list {
            Task { @MainActor in
                do {
                    let result = try await PackageCommandRunner.run(entry, command, input: built)
                    switch (command.output, result) {
                    case (.notify, _):
                        let text = PackageOutput.notifyText((try? await PackageOutput.text(result)) ?? "")
                        if text != "Done" { StatusHUD.shared.show(icon: "bolt.fill", text: "\(entry.package.name): \(text)", persist: 2) }
                    case (_, .file(let url)):
                        Log.app.notice("packages · \(entry.package.id, privacy: .public) saved \(url.lastPathComponent, privacy: .public) on \(event.rawValue, privacy: .public)")
                    default: break
                    }
                } catch {
                    Log.app.error("packages · \(entry.package.id, privacy: .public) on \(event.rawValue, privacy: .public) didn't work: \(PackageOutput.failure(error, entry, command), privacy: .public)")
                }
            }
        }
    }
}
