import UIKit

/// Drives interface orientation for the fullscreen player using only public,
/// iOS 16+ APIs (`UIWindowScene.requestGeometryUpdate`) — no private
/// `UIDevice.setValue` orientation hacks.
///
/// The app declares no `UISupportedInterfaceOrientations`, so the default mask
/// (portrait + both landscapes) already permits the requests below; this just
/// asks the active scene to rotate, then restores on the way out.
enum OrientationHelper {
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

    /// Request landscape for the fullscreen player. Defaults to landscape-right.
    static func lockLandscape() {
        request(.landscapeRight)
    }

    /// Restore a previously-captured orientation, or portrait as a safe
    /// fallback. Upside-down maps to portrait since it is not in the app mask.
    static func restore(_ orientation: UIInterfaceOrientation) {
        switch orientation {
        case .landscapeLeft:
            request(.landscapeLeft)
        case .landscapeRight:
            request(.landscapeRight)
        default:
            request(.portrait)
        }
    }

    /// Issue the geometry update. Also nudges the root controller to re-evaluate
    /// its supported orientations so the request is honored promptly.
    private static func request(_ mask: UIInterfaceOrientationMask) {
        guard let scene = activeScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        scene.keyWindow?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
