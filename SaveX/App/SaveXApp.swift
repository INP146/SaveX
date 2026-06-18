import SwiftUI
import UIKit

enum SaveXStorageKey {
    static let defaultDownloadRoute = "SaveX.defaultDownloadRoute"
    static let libraryLayout = "SaveX.libraryLayout"
    static let theme = "SaveX.theme"
    static let interfaceStyle = "SaveX.interfaceStyle"
    static let customThemeAccent = "SaveX.customThemeAccent"
    static let customThemeBackgroundAccent = "SaveX.customThemeBackgroundAccent"
    static let customThemeBackgroundAccentSecondary = "SaveX.customThemeBackgroundAccentSecondary"
    static let savesDownloadsToLibrary = "SaveX.savesDownloadsToLibrary"
    static let savesDownloadsToPhotos = "SaveX.savesDownloadsToPhotos"
    static let downloadsAllTweetVideosByDefault = "SaveX.downloadsAllTweetVideosByDefault"
}

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
