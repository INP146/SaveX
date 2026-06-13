import Foundation

struct AppContainer {
    let urlParser: TwitterURLParser
    let twitterCookieStore: TwitterCookieStore
    let authProvider: DefaultTwitterAuthProvider
    let apiClient: TwitterAPIClient
    let mediaExtractor: TwitterMediaExtractor
    let formatSelector: FormatSelector
    let downloadEngine: DownloadEngine
    let photoLibraryWriter: PhotoLibraryWriter
    let networkPermissionRequester: NetworkPermissionRequester

    init() {
        let twitterCookieStore = TwitterCookieStore()
        let authProvider = DefaultTwitterAuthProvider(cookieStore: twitterCookieStore)
        let apiClient = TwitterAPIClient(authProvider: authProvider)
        let mediaExtractor = TwitterMediaExtractor()
        let formatSelector = FormatSelector()
        self.urlParser = TwitterURLParser()
        self.twitterCookieStore = twitterCookieStore
        self.authProvider = authProvider
        self.apiClient = apiClient
        self.mediaExtractor = mediaExtractor
        self.formatSelector = formatSelector
        self.downloadEngine = DownloadEngine(
            apiClient: apiClient,
            extractor: mediaExtractor,
            selector: formatSelector
        )
        self.photoLibraryWriter = PhotoLibraryWriter()
        self.networkPermissionRequester = NetworkPermissionRequester()
    }
}
