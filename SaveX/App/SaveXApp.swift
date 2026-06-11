import SwiftUI

@main
struct SaveXApp: App {
    private let container = AppContainer()

    var body: some Scene {
        WindowGroup {
            AppRouter(container: container)
        }
    }
}
