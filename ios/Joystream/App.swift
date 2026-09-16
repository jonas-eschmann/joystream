import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = GamepadViewController()
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        (window?.rootViewController as? GamepadViewController)?.setActive(true)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        (window?.rootViewController as? GamepadViewController)?.setActive(false)
    }
}
