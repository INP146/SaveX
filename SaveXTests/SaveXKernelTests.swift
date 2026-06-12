import XCTest
@testable import SaveX

final class SaveXKernelTests: XCTestCase {
    func testURLParserPreservesMediaKindAndIndex() throws {
        let request = try TwitterURLParser().parse("https://x.com/demo/status/1234567890/video/2")

        XCTAssertEqual(request.tweetID, "1234567890")
        XCTAssertEqual(request.screenName, "demo")
        XCTAssertEqual(request.selectedMediaIndex, 2)
        XCTAssertEqual(request.selectedMediaKind, .video)
    }

    func testMixedMediaVideoSelectionUsesOriginalMediaIndex() async throws {
        let request = TweetRequest(
            sourceURL: URL(string: "https://x.com/demo/status/1234567890/video/2")!,
            tweetID: "1234567890",
            screenName: "demo",
            selectedMediaIndex: 2,
            selectedMediaKind: .video
        )

        let entries = try await TwitterMediaExtractor().extractEntries(
            from: Self.mixedMediaStatus,
            request: request
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, "video-2")
        XCTAssertEqual(entries[0].sourceMediaIndex, 2)
    }

    func testPhotoSelectionReturnsMediaNotVideo() async throws {
        let request = TweetRequest(
            sourceURL: URL(string: "https://x.com/demo/status/1234567890/photo/1")!,
            tweetID: "1234567890",
            screenName: "demo",
            selectedMediaIndex: 1,
            selectedMediaKind: .photo
        )

        do {
            _ = try await TwitterMediaExtractor().extractEntries(
                from: Self.photoOnlyStatus,
                request: request
            )
            XCTFail("Expected mediaNotVideo for explicit photo selection")
        } catch SaveXError.mediaNotVideo(index: 1) {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHLSParserRejectsUnsupportedCriticalTags() throws {
        let parser = HLSManifestParser()
        let baseURL = URL(string: "https://video.example.test/media/index.m3u8")!

        let unsupportedPlaylists = [
            """
            #EXTM3U
            #EXT-X-MAP:URI="init.mp4"
            #EXTINF:5.000,
            segment-1.m4s
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXTINF:5.000,
            #EXT-X-BYTERANGE:500@0
            file.ts
            #EXT-X-ENDLIST
            """,
            """
            #EXTM3U
            #EXTINF:5.000,
            segment-1.ts
            #EXT-X-DISCONTINUITY
            #EXTINF:5.000,
            segment-2.ts
            #EXT-X-ENDLIST
            """,
        ]

        for source in unsupportedPlaylists {
            do {
                _ = try parser.parse(source, baseURL: baseURL)
                XCTFail("Expected unsupportedHLS for playlist:\n\(source)")
            } catch SaveXError.unsupportedHLS {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testReadyJobIsPreservedWhenRestoredFromStore() throws {
        let root = Self.temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let fileManager = TestFileManager(root: root)
        let job = DownloadJob(
            request: Self.request(),
            phase: .ready,
            progress: 1,
            displayTitle: "Ready video",
            selectedFormatID: "http-832000",
            outputFilename: "ready.mp4",
            localFileURL: root.appendingPathComponent("SaveX/Downloads/ready.mp4"),
            savedFileSize: 3,
            errorMessage: "Library save failed",
            downloadedBytes: 3,
            totalBytes: 3,
            progressMessage: "Downloaded, but Library save failed"
        )
        DownloadJobStore(fileManager: fileManager).upsert(DownloadJobRecord(
            job: job,
            preference: .preferMP4Direct
        ))

        let center = DownloadCenter(
            container: AppContainer(),
            loadPersistedLibrary: false,
            loadPersistedJobs: true,
            fileManager: fileManager
        )

        XCTAssertEqual(center.jobs.count, 1)
        XCTAssertEqual(center.jobs[0].phase, .ready)
        XCTAssertEqual(center.jobs[0].localFileURL, job.localFileURL)
        XCTAssertEqual(center.jobs[0].progress, 1)
    }

    @MainActor
    func testDeletingReadyJobRemovesUnreferencedLocalFile() throws {
        let root = Self.temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let fileManager = TestFileManager(root: root)
        let downloads = root.appendingPathComponent("SaveX/Downloads", isDirectory: true)
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        let fileURL = downloads.appendingPathComponent("ready.mp4", isDirectory: false)
        try Data([1, 2, 3]).write(to: fileURL)

        let job = DownloadJob(
            request: Self.request(),
            phase: .ready,
            progress: 1,
            outputFilename: fileURL.lastPathComponent,
            localFileURL: fileURL,
            savedFileSize: 3,
            downloadedBytes: 3,
            totalBytes: 3
        )
        let center = DownloadCenter(
            container: AppContainer(),
            jobs: [job],
            loadPersistedLibrary: false,
            loadPersistedJobs: false,
            fileManager: fileManager
        )

        center.deleteJob(job)

        XCTAssertTrue(center.jobs.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: fileURL.path))
    }

    func testDownloadEngineCancelAndCleanRemovesHLSResumeArtifacts() async throws {
        let root = Self.temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let fileManager = TestFileManager(root: root)
        let jobID = UUID()
        let format = Self.hlsFormat()
        let resumeStore = HLSResumeStore(fileManager: fileManager)
        resumeStore.prepareState(
            jobID: jobID,
            format: format,
            segments: [
                HLSSegment(
                    url: URL(string: "https://video.example.test/segment-1.ts")!,
                    duration: 4,
                    title: nil
                ),
            ]
        )
        let workingDirectory = resumeStore.workingDirectory(jobID: jobID)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try Data([0x47]).write(to: workingDirectory.appendingPathComponent("segment-00000.ts"))

        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        let engine = DownloadEngine(
            apiClient: TwitterAPIClient(session: session),
            extractor: TwitterMediaExtractor(),
            selector: FormatSelector(),
            fileDownloader: HTTPFileDownloader(
                session: session,
                backgroundCoordinator: nil,
                fileManager: fileManager
            ),
            hlsDownloader: HLSMediaDownloader(
                session: session,
                fileManager: fileManager,
                resumeStore: resumeStore
            )
        )

        XCTAssertNotNil(resumeStore.state(jobID: jobID))
        XCTAssertTrue(fileManager.fileExists(atPath: workingDirectory.path))

        await engine.cancelAndClean(jobID: jobID)

        XCTAssertNil(resumeStore.state(jobID: jobID))
        XCTAssertFalse(fileManager.fileExists(atPath: workingDirectory.path))
    }

    private static let mixedMediaStatus: JSONDictionary = [
        "full_text": "Mixed media",
        "extended_entities": [
            "media": [
                [
                    "id_str": "photo-1",
                    "type": "photo",
                    "media_url_https": "https://pbs.twimg.com/media/photo.jpg",
                ],
                [
                    "id_str": "video-2",
                    "type": "video",
                    "video_info": [
                        "variants": [
                            [
                                "bitrate": 832000,
                                "url": "https://video.twimg.com/ext_tw_video/2/pu/vid/640x360/demo.mp4",
                            ],
                        ],
                    ],
                ],
            ],
        ],
    ]

    private static let photoOnlyStatus: JSONDictionary = [
        "full_text": "Photo only",
        "extended_entities": [
            "media": [
                [
                    "id_str": "photo-1",
                    "type": "photo",
                    "media_url_https": "https://pbs.twimg.com/media/photo.jpg",
                ],
            ],
        ],
    ]

    private static func request() -> TweetRequest {
        TweetRequest(
            sourceURL: URL(string: "https://x.com/demo/status/1234567890")!,
            tweetID: "1234567890",
            screenName: "demo",
            selectedMediaIndex: nil
        )
    }

    private static func hlsFormat() -> MediaFormat {
        MediaFormat(
            id: "1234567890-hls",
            url: URL(string: "https://video.example.test/master.m3u8")!,
            formatID: "hls",
            transport: .m3u8Native,
            container: .mp4,
            bitrate: nil,
            width: 640,
            height: 360,
            fileSizeApprox: nil,
            videoCodec: nil,
            audioCodec: nil,
            httpHeaders: [:]
        )
    }

    private static func temporaryRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SaveXTests-\(UUID().uuidString)", isDirectory: true)
    }
}

private final class TestFileManager: FileManager, @unchecked Sendable {
    private let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        switch directory {
        case .documentDirectory, .applicationSupportDirectory:
            return [root]
        default:
            return super.urls(for: directory, in: domainMask)
        }
    }
}
