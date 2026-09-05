import UIKit

/// Vamp Stream stays portrait, regardless of the remote window or display shape.
final class VampStreamAppDelegate: NSObject, UIApplicationDelegate {
    static let orientationMask: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.orientationMask
    }
}
