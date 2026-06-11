import Foundation

@main
struct SaveXKernelDownloadSmokeMain {
    static func main() async {
        let parser = TwitterURLParser()
        let authProvider = DefaultTwitterAuthProvider(authToken: nil, csrfToken: nil)
        let apiClient = TwitterAPIClient(authProvider: authProvider)
        let extractor = TwitterMediaExtractor()
        let selector = FormatSelector()
        let engine = DownloadEngine(
            apiClient: apiClient,
            extractor: extractor,
            selector: selector
        )

        let rawURL = "https://twitter.com/oshtru/status/1577855540407197696"
        let destinationDirectory = URL(fileURLWithPath: "/tmp/SaveXDownloads", isDirectory: true)

        do {
            let request = try parser.parse(rawURL)
            let asset = try await engine.download(
                request: request,
                mode: .graphql,
                preference: .preferMP4Direct,
                destinationDirectory: destinationDirectory
            )

            print("downloaded tweetID=\(asset.sourceTweetID)")
            print("formatID=\(asset.format.formatID)")
            print("transport=\(asset.format.transport.rawValue)")
            print("size=\(asset.fileSize)")
            print("mime=\(asset.responseMimeType ?? "nil")")
            print("path=\(asset.localFileURL.path)")
        } catch {
            print("FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }
}
