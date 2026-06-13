import SwiftUI

struct AppRouter: View {
    let container: AppContainer
    @StateObject private var downloadCenter: DownloadCenter

    init(container: AppContainer) {
        self.container = container
        _downloadCenter = StateObject(wrappedValue: DownloadCenter(container: container))
    }

    var body: some View {
        TabView {
            HomeView(downloadCenter: downloadCenter)
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            JobsView(downloadCenter: downloadCenter)
                .tabItem {
                    Label("Jobs", systemImage: "arrow.down.circle")
                }

            LibraryView(downloadCenter: downloadCenter)
                .tabItem {
                    Label("Library", systemImage: "books.vertical.fill")
                }

            LogsView(downloadCenter: downloadCenter)
                .tabItem {
                    Label("Logs", systemImage: "list.bullet.rectangle")
                }

            SettingsView(cookieStore: container.twitterCookieStore)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .task {
            await downloadCenter.prepareCapabilities()
        }
    }
}

#Preview("App") {
    AppRouter(container: AppContainer())
}
