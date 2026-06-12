import SwiftUI
import UIKit

final class SaveXAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundHTTPDownloadCoordinator.shared.setBackgroundCompletionHandler(
            completionHandler,
            for: identifier
        )
    }
}

@main
struct SaveXApp: App {
    @UIApplicationDelegateAdaptor(SaveXAppDelegate.self) private var appDelegate

    private let container = AppContainer()

    var body: some Scene {
        WindowGroup {
            AppRouter(container: container)
        }
    }
}
