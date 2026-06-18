import SwiftUI

struct AppRouter: View {
    let container: AppContainer
    @StateObject private var downloadCenter: DownloadCenter
    @AppStorage(SaveXStorageKey.theme) private var themeRaw = SaveXThemeSelection.defaultSelection.rawValue
    @AppStorage(SaveXStorageKey.interfaceStyle) private var interfaceStyleRaw = SaveXInterfaceStyle.defaultStyle.rawValue
    @AppStorage(SaveXStorageKey.customThemeAccent) private var customAccentRaw = ""
    @AppStorage(SaveXStorageKey.customThemeBackgroundAccent) private var customBackgroundAccentRaw = ""
    @AppStorage(SaveXStorageKey.customThemeBackgroundAccentSecondary) private var customBackgroundAccentSecondaryRaw = ""

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
        .environment(\.saveXTheme, resolvedTheme)
        .tint(resolvedTheme.palette.accent)
        .preferredColorScheme(selectedInterfaceStyle.preferredColorScheme)
        .saveXKeyboardDismissOverlay()
        .tabBarMinimizeBehavior(.onScrollDown)
        .task {
            await downloadCenter.prepareCapabilities()
        }
    }

    private var resolvedTheme: SaveXResolvedTheme {
        SaveXResolvedTheme.resolve(
            selectionRaw: themeRaw,
            customAccentRaw: customAccentRaw,
            customBackgroundAccentRaw: customBackgroundAccentRaw,
            customBackgroundAccentSecondaryRaw: customBackgroundAccentSecondaryRaw
        )
    }

    private var selectedInterfaceStyle: SaveXInterfaceStyle {
        SaveXInterfaceStyle(rawValue: interfaceStyleRaw) ?? .defaultStyle
    }
}

#Preview("App") {
    AppRouter(container: AppContainer())
}
