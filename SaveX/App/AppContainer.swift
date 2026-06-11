import Foundation

struct AppContainer {
    let urlParser: TwitterURLParser
    let authProvider: DefaultTwitterAuthProvider
    let apiClient: TwitterAPIClient
    let mediaExtractor: TwitterMediaExtractor
    let formatSelector: FormatSelector
    let downloadEngine: DownloadEngine
    let photoLibraryWriter: PhotoLibraryWriter

    init() {
        let authProvider = DefaultTwitterAuthProvider(authToken: nil, csrfToken: nil)
        let apiClient = TwitterAPIClient(authProvider: authProvider)
        let mediaExtractor = TwitterMediaExtractor()
        let formatSelector = FormatSelector()
        self.urlParser = TwitterURLParser()
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
    }
}
