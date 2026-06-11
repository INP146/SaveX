import Foundation

enum HLSDownloadSmokeError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw HLSDownloadSmokeError.failed(message)
    }
}

final class MockHLSURLProtocol: URLProtocol {
    static var responses: [URL: (status: Int, body: Data, mimeType: String?)] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "video.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = Self.responses[url],
              let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: response.status,
                httpVersion: "HTTP/1.1",
                headerFields: response.mimeType.map { ["Content-Type": $0] } ?? [:]
              ) else {
            client?.urlProtocol(self, didFailWithError: HLSDownloadSmokeError.failed("No mock response"))
            return
        }

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
    }
}

@main
struct HLSDownloadSmokeMain {
    static func main() async {
        do {
            try await testHLSDownload()
            print("hls download smoke passed")
        } catch {
            print("FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func testHLSDownload() async throws {
        let masterURL = URL(string: "https://video.example.test/master.m3u8")!
        let lowURL = URL(string: "https://video.example.test/low/index.m3u8")!
        let highURL = URL(string: "https://video.example.test/high/index.m3u8")!
        let firstSegmentURL = URL(string: "https://video.example.test/high/segment-1.ts")!
        let secondSegmentURL = URL(string: "https://video.example.test/high/segment-2.ts")!

        MockHLSURLProtocol.responses = [
            masterURL: (200, Data("""
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=640x360
            low/index.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
            high/index.m3u8
            """.utf8), "application/vnd.apple.mpegurl"),
            lowURL: (200, Data("""
            #EXTM3U
            #EXTINF:1.0,
            segment-low.ts
            #EXT-X-ENDLIST
            """.utf8), "application/vnd.apple.mpegurl"),
            highURL: (200, Data("""
            #EXTM3U
            #EXT-X-TARGETDURATION:2
            #EXTINF:1.0,
            segment-1.ts
            #EXTINF:1.0,
            segment-2.ts
            #EXT-X-ENDLIST
            """.utf8), "application/vnd.apple.mpegurl"),
            firstSegmentURL: (200, Data([0x47, 0x11, 0x12]), "video/MP2T"),
            secondSegmentURL: (200, Data([0x47, 0x21]), "video/MP2T"),
        ]

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockHLSURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let downloader = HLSMediaDownloader(session: session)
        let destinationDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SaveXHLSSmoke-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: destinationDirectory)
        }

        let format = MediaFormat(
            id: "fixture-hls",
            url: masterURL,
            formatID: "hls",
            transport: .m3u8Native,
            container: .mp4,
            bitrate: nil,
            width: nil,
            height: nil,
            fileSizeApprox: nil,
            videoCodec: nil,
            audioCodec: nil,
            httpHeaders: [:]
        )

        let asset = try await downloader.download(
            format: format,
            tweetID: "1234567890",
            title: "Fixture HLS",
            destinationDirectory: destinationDirectory
        )

        try expect(asset.localFileURL.pathExtension == "ts", "HLS output should be a TS file")
        try expect(asset.fileSize == 5, "HLS output size should equal concatenated segment size")
        let outputData = try Data(contentsOf: asset.localFileURL)
        try expect(outputData == Data([0x47, 0x11, 0x12, 0x47, 0x21]), "HLS output bytes were not concatenated in order")
    }
}
