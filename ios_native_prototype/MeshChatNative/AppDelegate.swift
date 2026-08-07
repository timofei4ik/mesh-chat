import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let navigationController = UINavigationController(rootViewController: ChatListViewController())
        navigationController.setNavigationBarHidden(true, animated: false)

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.backgroundColor = MeshTheme.background
        window.rootViewController = navigationController
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
