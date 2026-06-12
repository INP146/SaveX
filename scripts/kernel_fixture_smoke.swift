import Foundation

enum KernelFixtureSmokeError: LocalizedError {
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
        throw KernelFixtureSmokeError.failed(message)
    }
}

@main
struct SaveXKernelFixtureSmokeMain {
    static func main() async {
        do {
            try testURLParser()
            try await testMediaExtractionAndSelection()
            print("kernel fixture smoke passed")
        } catch {
            print("FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func testURLParser() throws {
        let parser = TwitterURLParser()
        let request = try parser.parse("https://x.com/demo/status/1234567890/video/2")

        try expect(request.tweetID == "1234567890", "tweetID was not parsed")
        try expect(request.screenName == "demo", "screen name was not parsed")
        try expect(request.selectedMediaIndex == 2, "selected media index was not parsed")
        try expect(request.selectedMediaKind == .video, "selected media kind was not parsed")
    }

    private static func testMediaExtractionAndSelection() async throws {
        let request = TweetRequest(
            sourceURL: URL(string: "https://x.com/demo/status/1234567890")!,
            tweetID: "1234567890",
            screenName: "demo",
            selectedMediaIndex: nil
        )
        let status: JSONDictionary = [
            "full_text": "Fixture video https://t.co/example",
            "user": [
                "name": "Demo User",
                "screen_name": "demo",
                "id_str": "42",
            ],
            "view_count": 1000,
            "favorite_count": 25,
            "retweet_count": 4,
            "reply_count": 3,
            "extended_entities": [
                "media": [
                    [
                        "id_str": "987654321",
                        "type": "video",
                        "media_url_https": "https://pbs.twimg.com/ext_tw_video_thumb/987654321/pu/img/thumb.jpg",
                        "sizes": [
                            "small": ["w": 320, "h": 180],
                            "large": ["w": 1280, "h": 720],
                        ],
                        "video_info": [
                            "duration_millis": 6000,
                            "variants": [
                                [
                                    "bitrate": 832000,
                                    "url": "https://video.twimg.com/ext_tw_video/987654321/pu/vid/640x360/demo.mp4?tag=12",
                                ],
                                [
                                    "bitrate": 2176000,
                                    "url": "https://video.twimg.com/ext_tw_video/987654321/pu/vid/1280x720/demo.mp4?tag=12",
                                ],
                                [
                                    "content_type": "application/x-mpegURL",
                                    "url": "https://video.twimg.com/ext_tw_video/987654321/pu/pl/1280x720/playlist.m3u8?tag=12",
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let entries = try await TwitterMediaExtractor().extractEntries(from: status, request: request)
        try expect(entries.count == 1, "expected one extracted media entry")

        let entry = entries[0]
        try expect(entry.title == "Demo User - Fixture video", "title cleanup changed")
        try expect(entry.duration == 6, "duration was not converted from milliseconds")
        try expect(entry.thumbnails.count == 2, "thumbnail extraction changed")
        try expect(entry.formats.count == 3, "expected three normalized formats")

        let selector = FormatSelector()
        let direct = try selector.selectBest(from: entry.formats, preference: .preferMP4Direct)
        try expect(direct.formatID == "http-2176000", "MP4 preference should pick highest bitrate direct format")
        try expect(!direct.isHLS, "MP4 preference should not pick HLS")

        let hls = try selector.selectBest(from: entry.formats, preference: .preferHLS)
        try expect(hls.isHLS, "HLS preference should pick HLS")

        let hlsWithoutDimensions = MediaFormat(
            id: "fixture-hls-no-dimensions",
            url: URL(string: "https://video.twimg.com/ext_tw_video/987654321/pu/pl/playlist.m3u8?tag=12")!,
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
        let explicitHLS = try selector.selectBest(
            from: [direct, hlsWithoutDimensions],
            preference: .preferHLS
        )
        try expect(explicitHLS.isHLS, "HLS preference should be route-first even when HLS lacks dimensions")

        let mixedRequest = TweetRequest(
            sourceURL: URL(string: "https://x.com/demo/status/1234567890/video/2")!,
            tweetID: "1234567890",
            screenName: "demo",
            selectedMediaIndex: 2,
            selectedMediaKind: .video
        )
        let mixedStatus: JSONDictionary = [
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

        let mixedEntries = try await TwitterMediaExtractor().extractEntries(from: mixedStatus, request: mixedRequest)
        try expect(mixedEntries.count == 1, "selected mixed media video should resolve")
        try expect(mixedEntries[0].id == "video-2", "selected media index should match original media position")

        let photoRequest = TweetRequest(
            sourceURL: URL(string: "https://x.com/demo/status/1234567890/photo/1")!,
            tweetID: "1234567890",
            screenName: "demo",
            selectedMediaIndex: 1,
            selectedMediaKind: .photo
        )
        do {
            _ = try await TwitterMediaExtractor().extractEntries(from: mixedStatus, request: photoRequest)
            throw KernelFixtureSmokeError.failed("selected photo media should not be treated as video")
        } catch SaveXError.mediaNotVideo(index: 1) {
        }
    }
}
