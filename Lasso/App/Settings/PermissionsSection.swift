import SwiftUI

/// Settings › Privacy › Permissions: whether macOS allows Lasso each permission, and Reset for one
/// that's stuck: on in System Settings, but given to another copy of Lasso (see `PermissionsService`).
struct PermissionsSection: View {
    private let permissions = CaptureCoordinator.shared.permissions
    @State private var allowed: [PermissionsService.Kind: Bool] = [:]
    @State private var working: PermissionsService.Kind?
    @State private var problem: String?

    var body: some View {
        Section("Permissions") {
            ForEach(PermissionsService.Kind.allCases) { row($0) }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            } else if allowed.values.contains(false) {
                // Screen Recording takes effect only after a relaunch: say so first, or someone who just
                // switched it on would press Reset and clear the permission they had just given.
                Text("Switched Lasso on in System Settings? Quit and reopen Lasso. Still not allowed after that? macOS is holding a permission from another copy of Lasso: Reset clears it, then switch Lasso on again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func row(_ kind: PermissionsService.Kind) -> some View {
        LabeledContent {
            if allowed[kind] ?? true {
                Text("Allowed").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    if working == kind { ProgressView().controlSize(.small) }
                    Text("Not allowed").foregroundStyle(.secondary)
                    Button("Reset") { reset(kind) }.disabled(working != nil)
                }
            }
        } label: {
            Text(kind.title)
            Text(kind.use)
        }
    }

    private func refresh() {
        for kind in PermissionsService.Kind.allCases { allowed[kind] = permissions.isAllowed(kind) }
    }

    private func reset(_ kind: PermissionsService.Kind) {
        working = kind
        problem = nil
        Task {
            do { try await permissions.reset(kind) } catch { problem = error.localizedDescription }
            working = nil
            refresh()
        }
    }
}
