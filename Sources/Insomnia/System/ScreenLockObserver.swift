import CoreGraphics
import Foundation

/// Reports when the login session's screen locks and unlocks, from the
/// `com.apple.screenIsLocked` and `com.apple.screenIsUnlocked` distributed
/// notifications loginwindow posts for Ctrl-Cmd-Q, a lid-close lock, a
/// display sleep that asks for the password and fast user switching. Lives
/// as long as the app, so the state is known when a session starts. The
/// state at launch is read once and reported before anything else: the app
/// can start, and resume a session, behind a locked screen.
@MainActor
final class ScreenLockObserver {
    static let lockedName = Notification.Name("com.apple.screenIsLocked")
    static let unlockedName = Notification.Name("com.apple.screenIsUnlocked")

    private let center: DistributedNotificationCenter
    /// Set once in `init` and read once more in `deinit`, which does not
    /// run on the main actor; `removeObserver` is safe from any thread.
    nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []

    /// `lockedNow` reads the session; tests pass their own.
    init(
        center: DistributedNotificationCenter = .default(),
        lockedNow: () -> Bool = ScreenLockObserver.screenLockedNow,
        onChange: @escaping @MainActor (_ locked: Bool) -> Void
    ) {
        self.center = center
        onChange(lockedNow())
        for (name, locked) in [(Self.lockedName, true), (Self.unlockedName, false)] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onChange(locked) }
            })
        }
    }

    /// `CGSSessionScreenIsLocked` in the current session's dictionary, the
    /// key `ioreg -n Root -d1` shows. False when it is absent or the
    /// dictionary cannot be read.
    nonisolated static func screenLockedNow() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Not `isolated deinit`; see `DisplaySleepObserver`.
    deinit {
        tokens.forEach(center.removeObserver)
    }
}
