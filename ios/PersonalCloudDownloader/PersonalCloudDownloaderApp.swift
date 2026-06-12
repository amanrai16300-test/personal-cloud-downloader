import SwiftUI
import UIKit

/// Enforces the app-wide orientation lock: portrait everywhere by default,
/// landscape-only while the fullscreen player is up. `OrientationHelper` flips
/// `lockMask` around the fullscreen lifecycle; this delegate just reports it.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationHelper.lockMask
    }
}

@main
struct PersonalCloudDownloaderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }
}
