import Testing
@testable import Lasso

/// A downloaded update installs (and relaunches Lasso) only when nothing is in progress. The real
/// download, signature check and relaunch were run end to end against a local feed; this pins the
/// timing rule, which that run can't make fail on demand.
@MainActor
@Suite(.serialized)
struct AppUpdaterTests {
    private let updater = AppUpdater.shared

    @Test func waitsWhileBusyThenInstallsOnce() {
        let idleCheck = updater.isIdle
        defer { updater.isIdle = idleCheck; updater.installIfIdle() }
        var busy = true
        var installs = 0
        updater.isIdle = { !busy }

        updater.installWhenIdle { installs += 1 }
        #expect(installs == 0, "installed while a capture or reply was running")
        #expect(updater.hasPendingInstall)

        updater.installIfIdle()   // the 30 s timer firing, still busy
        #expect(installs == 0)

        busy = false
        updater.installIfIdle()   // the timer, now idle
        #expect(installs == 1)
        #expect(!updater.hasPendingInstall)

        updater.installIfIdle()   // later ticks do nothing more
        #expect(installs == 1)
    }

    @Test func installsAtOnceWhenAlreadyIdle() {
        let idleCheck = updater.isIdle
        defer { updater.isIdle = idleCheck }
        var installs = 0
        updater.isIdle = { true }
        updater.installWhenIdle { installs += 1 }
        #expect(installs == 1)
        #expect(!updater.hasPendingInstall)
    }
}
