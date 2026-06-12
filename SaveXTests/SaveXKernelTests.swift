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
}
