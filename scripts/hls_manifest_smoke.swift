import Foundation

enum HLSManifestSmokeError: LocalizedError {
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
        throw HLSManifestSmokeError.failed(message)
    }
}

@main
struct HLSManifestSmokeMain {
    static func main() {
        do {
            try testMasterPlaylist()
            try testMediaPlaylist()
            try testUnsupportedEncryptedPlaylist()
            try testUnsupportedLivePlaylist()
            try testUnsupportedFMP4Playlist()
            try testUnsupportedByteRangePlaylist()
            try testUnsupportedDiscontinuityPlaylist()
            print("hls manifest smoke passed")
        } catch {
            print("FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func testMasterPlaylist() throws {
        let source = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-STREAM-INF:BANDWIDTH=832000,AVERAGE-BANDWIDTH=700000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=640x360
        360/prog_index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2176000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1280x720
        https://video.example.test/full/playlist.m3u8
        """

        let manifest = try HLSManifestParser().parse(source, baseURL: URL(string: "https://video.example.test/base/master.m3u8")!)
        guard case let .master(variants) = manifest else {
            throw HLSManifestSmokeError.failed("expected master playlist")
        }

        try expect(variants.count == 2, "expected two variants")
        try expect(variants[0].url.absoluteString == "https://video.example.test/base/360/prog_index.m3u8", "relative variant URL did not resolve")
        try expect(variants[0].bandwidth == 832000, "bandwidth did not parse")
        try expect(variants[0].averageBandwidth == 700000, "average bandwidth did not parse")
        try expect(variants[0].codecs == "avc1.4d401f,mp4a.40.2", "quoted codecs did not parse")
        try expect(variants[0].width == 640 && variants[0].height == 360, "resolution did not parse")
        try expect(variants[1].url.absoluteString == "https://video.example.test/full/playlist.m3u8", "absolute variant URL changed")
    }

    private static func testMediaPlaylist() throws {
        let source = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXTINF:5.000,
        segment-1.ts
        #EXTINF:4.500,tail
        ../segment-2.ts
        #EXT-X-ENDLIST
        """

        let manifest = try HLSManifestParser().parse(source, baseURL: URL(string: "https://video.example.test/path/media/index.m3u8")!)
        guard case let .media(media) = manifest else {
            throw HLSManifestSmokeError.failed("expected media playlist")
        }

        try expect(media.targetDuration == 6, "target duration did not parse")
        try expect(media.hasEndList, "media playlist should be marked finite")
        try expect(media.segments.count == 2, "expected two segments")
        try expect(media.segments[0].url.absoluteString == "https://video.example.test/path/media/segment-1.ts", "relative segment URL did not resolve")
        try expect(media.segments[1].url.absoluteString == "https://video.example.test/path/segment-2.ts", "parent-relative segment URL did not resolve")
        try expect(media.segments[1].duration == 4.5, "segment duration did not parse")
        try expect(media.segments[1].title == "tail", "segment title did not parse")
    }

    private static func testUnsupportedEncryptedPlaylist() throws {
        let source = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXTINF:5.000,
        segment-1.ts
        #EXT-X-ENDLIST
        """

        do {
            _ = try HLSManifestParser().parse(source, baseURL: URL(string: "https://video.example.test/media/index.m3u8")!)
            throw HLSManifestSmokeError.failed("encrypted playlist should fail")
        } catch SaveXError.unsupportedHLS {
        }
    }

    private static func testUnsupportedLivePlaylist() throws {
        let source = """
        #EXTM3U
        #EXTINF:5.000,
        segment-1.ts
        """

        do {
            _ = try HLSManifestParser().parse(source, baseURL: URL(string: "https://video.example.test/media/index.m3u8")!)
            throw HLSManifestSmokeError.failed("live playlist should fail")
        } catch SaveXError.unsupportedHLS {
        }
    }

    private static func testUnsupportedFMP4Playlist() throws {
        let source = """
        #EXTM3U
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:5.000,
        segment-1.m4s
        #EXT-X-ENDLIST
        """

        do {
            _ = try HLSManifestParser().parse(source, baseURL: URL(string: "https://video.example.test/media/index.m3u8")!)
            throw HLSManifestSmokeError.failed("fMP4 playlist should fail until EXT-X-MAP is supported")
        } catch SaveXError.unsupportedHLS {
        }
    }

    private static func testUnsupportedByteRangePlaylist() throws {
        let source = """
        #EXTM3U
        #EXTINF:5.000,
        #EXT-X-BYTERANGE:500@0
        file.ts
        #EXT-X-ENDLIST
        """

        do {
            _ = try HLSManifestParser().parse(source, baseURL: URL(string: "https://video.example.test/media/index.m3u8")!)
            throw HLSManifestSmokeError.failed("byte-range playlist should fail until range assembly is supported")
        } catch SaveXError.unsupportedHLS {
        }
    }

    private static func testUnsupportedDiscontinuityPlaylist() throws {
        let source = """
        #EXTM3U
        #EXTINF:5.000,
        segment-1.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:5.000,
        segment-2.ts
        #EXT-X-ENDLIST
        """

        do {
            _ = try HLSManifestParser().parse(source, baseURL: URL(string: "https://video.example.test/media/index.m3u8")!)
            throw HLSManifestSmokeError.failed("discontinuity playlist should fail until discontinuity assembly is supported")
        } catch SaveXError.unsupportedHLS {
        }
    }
}
