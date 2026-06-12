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
    static var requestCounts: [URL: Int] = [:]

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

        Self.requestCounts[url, default: 0] += 1
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
            try await testHLSExportFailure()
            try await testHLSResumeReusesCompletedSegments()
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
        let exporter = MockHLSExporter()
        let downloader = HLSMediaDownloader(session: session, exporter: exporter)
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

        try expect(asset.localFileURL.pathExtension == "mp4", "HLS output should be an MP4 file")
        try expect(asset.responseMimeType == "video/mp4", "HLS output MIME type should be video/mp4")
        try expect(asset.fileSize == 5, "HLS output size should come from exported MP4")
        let outputData = try Data(contentsOf: asset.localFileURL)
        try expect(outputData == Data([0x47, 0x11, 0x12, 0x47, 0x21]), "HLS output bytes were not concatenated in order")
        try expect(exporter.sourceURL?.pathExtension == "ts", "exporter should receive the temporary assembled TS file")
        try expect(exporter.destinationURL == asset.localFileURL, "downloader should return the exporter destination")
        let hasTemporaryDirectory = try hasTemporaryHLSDirectory(in: destinationDirectory)
        try expect(!hasTemporaryDirectory, "temporary HLS working directory should be cleaned up")
    }

    private static func testHLSExportFailure() async throws {
        let masterURL = URL(string: "https://video.example.test/failure-master.m3u8")!
        let mediaURL = URL(string: "https://video.example.test/failure/index.m3u8")!
        let segmentURL = URL(string: "https://video.example.test/failure/segment-1.ts")!

        MockHLSURLProtocol.responses = [
            masterURL: (200, Data("""
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=640x360
            failure/index.m3u8
            """.utf8), "application/vnd.apple.mpegurl"),
            mediaURL: (200, Data("""
            #EXTM3U
            #EXTINF:1.0,
            segment-1.ts
            #EXT-X-ENDLIST
            """.utf8), "application/vnd.apple.mpegurl"),
            segmentURL: (200, Data([0x47, 0x31]), "video/MP2T"),
        ]

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockHLSURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let downloader = HLSMediaDownloader(
            session: session,
            exporter: MockHLSExporter(error: HLSDownloadSmokeError.failed("mock export failed"))
        )
        let destinationDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SaveXHLSFailureSmoke-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: destinationDirectory)
        }

        let format = MediaFormat(
            id: "fixture-hls-failure",
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

        do {
            _ = try await downloader.download(
                format: format,
                tweetID: "1234567891",
                title: "Fixture HLS Failure",
                destinationDirectory: destinationDirectory
            )
            throw HLSDownloadSmokeError.failed("HLS export failure should fail the download")
        } catch HLSDownloadSmokeError.failed("mock export failed") {
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: destinationDirectory,
            includingPropertiesForKeys: nil
        )
        try expect(!contents.contains { $0.pathExtension == "mp4" }, "failed export should not leave a final MP4")
        let hasTemporaryDirectory = try hasTemporaryHLSDirectory(in: destinationDirectory)
        try expect(!hasTemporaryDirectory, "failed export should clean up temporary HLS files")
    }

    private static func testHLSResumeReusesCompletedSegments() async throws {
        let masterURL = URL(string: "https://video.example.test/resume-master.m3u8")!
        let mediaURL = URL(string: "https://video.example.test/resume/index.m3u8")!
        let firstSegmentURL = URL(string: "https://video.example.test/resume/segment-1.ts")!
        let secondSegmentURL = URL(string: "https://video.example.test/resume/segment-2.ts")!
        let jobID = UUID()

        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SaveXHLSResumeSmoke-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let fileManager = SmokeFileManager(root: root)
        let destinationDirectory = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let format = MediaFormat(
            id: "fixture-hls-resume",
            url: masterURL,
            formatID: "hls-resume",
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

        MockHLSURLProtocol.responses = [
            masterURL: (200, Data("""
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=640x360
            resume/index.m3u8
            """.utf8), "application/vnd.apple.mpegurl"),
            mediaURL: (200, Data("""
            #EXTM3U
            #EXTINF:1.0,
            segment-1.ts
            #EXTINF:1.0,
            segment-2.ts
            #EXT-X-ENDLIST
            """.utf8), "application/vnd.apple.mpegurl"),
            firstSegmentURL: (200, Data([0x47, 0x41]), "video/MP2T"),
            secondSegmentURL: (200, Data([0x47, 0x42]), "video/MP2T"),
        ]
        MockHLSURLProtocol.requestCounts = [:]

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockHLSURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let failingDownloader = HLSMediaDownloader(
            session: session,
            exporter: MockHLSExporter(error: HLSDownloadSmokeError.failed("mock resume export failed")),
            fileManager: fileManager
        )

        do {
            _ = try await failingDownloader.download(
                jobID: jobID,
                format: format,
                tweetID: "1234567892",
                title: "Fixture HLS Resume",
                destinationDirectory: destinationDirectory
            )
            throw HLSDownloadSmokeError.failed("first HLS resume run should fail during export")
        } catch HLSDownloadSmokeError.failed("mock resume export failed") {
        }

        try expect(MockHLSURLProtocol.requestCounts[firstSegmentURL] == 1, "first run should download segment 1")
        try expect(MockHLSURLProtocol.requestCounts[secondSegmentURL] == 1, "first run should download segment 2")

        MockHLSURLProtocol.responses = [
            masterURL: MockHLSURLProtocol.responses[masterURL]!,
            mediaURL: MockHLSURLProtocol.responses[mediaURL]!,
        ]
        MockHLSURLProtocol.requestCounts = [:]

        let resumedDownloader = HLSMediaDownloader(
            session: session,
            exporter: MockHLSExporter(),
            fileManager: fileManager
        )
        let asset = try await resumedDownloader.download(
            jobID: jobID,
            format: format,
            tweetID: "1234567892",
            title: "Fixture HLS Resume",
            destinationDirectory: destinationDirectory
        )

        let outputData = try Data(contentsOf: asset.localFileURL)
        try expect(outputData == Data([0x47, 0x41, 0x47, 0x42]), "resumed HLS output should reuse local segments in order")
        try expect(MockHLSURLProtocol.requestCounts[firstSegmentURL] == nil, "second run should not request segment 1")
        try expect(MockHLSURLProtocol.requestCounts[secondSegmentURL] == nil, "second run should not request segment 2")
    }
}

private final class MockHLSExporter: HLSMediaExporting, @unchecked Sendable {
    private let error: Error?
    private(set) var sourceURL: URL?
    private(set) var destinationURL: URL?

    init(error: Error? = nil) {
        self.error = error
    }

    func exportMP4(from sourceURL: URL, to destinationURL: URL) async throws {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        if let error {
            throw error
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }
}

private func hasTemporaryHLSDirectory(in directory: URL) throws -> Bool {
    guard FileManager.default.fileExists(atPath: directory.path) else {
        return false
    }
    let contents = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    return contents.contains { $0.lastPathComponent.hasPrefix(".savex-hls-") }
}

private final class SmokeFileManager: FileManager, @unchecked Sendable {
    private let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        switch directory {
        case .applicationSupportDirectory:
            return [root.appendingPathComponent("ApplicationSupport", isDirectory: true)]
        case .documentDirectory:
            return [root.appendingPathComponent("Documents", isDirectory: true)]
        default:
            return super.urls(for: directory, in: domainMask)
        }
    }
}
