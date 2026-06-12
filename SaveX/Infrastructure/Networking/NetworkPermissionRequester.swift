import Foundation

struct NetworkPermissionResult: Sendable {
    let isReady: Bool
    let message: String
}

actor NetworkPermissionRequester {
    private let probeURL: URL
    private let session: URLSession

    init(probeURL: URL = URL(string: "https://www.apple.com/library/test/success.html")!) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.waitsForConnectivity = false

        self.probeURL = probeURL
        self.session = URLSession(configuration: configuration)
    }

    func requestAccess() async -> NetworkPermissionResult {
        var request = URLRequest(url: probeURL)
        request.httpMethod = "GET"
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return NetworkPermissionResult(isReady: true, message: "Network request completed")
            }

            if (200..<400).contains(httpResponse.statusCode) {
                return NetworkPermissionResult(isReady: true, message: "Network access is ready")
            }

            return NetworkPermissionResult(
                isReady: false,
                message: "Network probe returned HTTP \(httpResponse.statusCode)"
            )
        } catch {
            return NetworkPermissionResult(
                isReady: false,
                message: error.localizedDescription
            )
        }
    }
}
