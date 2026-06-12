import UIKit

/// Drives interface orientation for the fullscreen player using only public,
/// iOS 16+ APIs (`UIWindowScene.requestGeometryUpdate`) — no private
/// `UIDevice.setValue` orientation hacks.
///
/// `lockMask` is the app-wide source of truth read by the `AppDelegate`'s
/// `supportedInterfaceOrientationsFor`: portrait everywhere by default, and
/// landscape-only while the fullscreen player is up. The geometry request
/// rotates the scene; the mask keeps it there (and keeps every other screen
/// portrait).
enum OrientationHelper {
    /// Orientations currently allowed app-wide. The `AppDelegate` returns this
    /// from `supportedInterfaceOrientationsFor`, so non-player screens stay
    /// portrait and the fullscreen player is held in landscape.
    static var lockMask: UIInterfaceOrientationMask = .portrait

    /// The active foreground window scene, if any. All requests target it.
    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
    }

    /// The scene's current interface orientation, captured before entering
    /// fullscreen so it can be restored on exit. Falls back to `.portrait`.
    static func currentOrientation() -> UIInterfaceOrientation {
        activeScene?.interfaceOrientation ?? .portrait
    }

    /// Lock to landscape-only for the fullscreen player, then request the
    /// rotation. Defaults to landscape-right.
    static func lockLandscape() {
        lockMask = .landscape
        request(.landscapeRight)
    }

    /// Restore the portrait-only app default on fullscreen exit. The captured
    /// pre-fullscreen orientation can only have been portrait (the app mask
    /// forbids landscape outside the player), so everything maps to portrait.
    static func restore(_ orientation: UIInterfaceOrientation) {
        lockMask = .portrait
        request(.portrait)
    }

    /// Issue the geometry update. Also nudges the TOPMOST presented controller
    /// (the `fullScreenCover` host when the player is up, else the root) to
    /// re-evaluate its supported orientations so the request is honored promptly.
    private static func request(_ mask: UIInterfaceOrientationMask) {
        guard let scene = activeScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        var topmost = scene.keyWindow?.rootViewController
        while let presented = topmost?.presentedViewController {
            topmost = presented
        }
        topmost?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
