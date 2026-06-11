import Foundation

struct TweetRequest: Sendable, Equatable {
    let sourceURL: URL
    let tweetID: String
    let screenName: String?
    let selectedMediaIndex: Int?

    var displayID: String {
        tweetID
    }
}

enum MediaTransport: String, Sendable {
    case http
    case https
    case m3u8
    case m3u8Native
    case external
    case unknown
}

enum MediaContainer: String, Sendable {
    case mp4
    case m3u8
    case ts
    case unknown
}

enum FormatSortField: String, Sendable {
    case resolution
    case preferM3U8
    case bitrate
    case fileSize
}

struct MediaSubtitle: Sendable {
    let languageCode: String
    let url: URL
}

struct MediaThumbnail: Sendable {
    let id: String
    let url: URL
    let width: Int?
    let height: Int?
}

struct MediaFormat: Identifiable, Sendable {
    let id: String
    let url: URL
    let formatID: String
    let transport: MediaTransport
    let container: MediaContainer
    let bitrate: Int?
    let width: Int?
    let height: Int?
    let fileSizeApprox: Int?
    let videoCodec: String?
    let audioCodec: String?
    let httpHeaders: [String: String]

    var isHLS: Bool {
        transport == .m3u8 || transport == .m3u8Native || container == .m3u8
    }

    var pixelCount: Int {
        (width ?? 0) * (height ?? 0)
    }
}

struct TweetMediaInfo: Identifiable, Sendable {
    let id: String
    let displayID: String
    let title: String
    let description: String
    let uploader: String?
    let uploaderID: String?
    let uploaderURL: URL?
    let channelID: String?
    let timestamp: Date?
    let viewCount: Int?
    let likeCount: Int?
    let repostCount: Int?
    let commentCount: Int?
    let ageLimit: Int
    let tags: [String]
    let duration: Double?
    let formats: [MediaFormat]
    let subtitles: [MediaSubtitle]
    let thumbnails: [MediaThumbnail]
    let externalReferenceURL: URL?
    let formatSortFields: [FormatSortField]
}

enum DownloadJobPhase: String, Sendable {
    case idle
    case queued
    case validatingURL
    case fetchingGuestToken
    case fetchingTweet
    case normalizingTweet
    case extractingMedia
    case selectingFormat
    case preparingDownload
    case downloading
    case ready
    case completed
    case failed

    var isTerminal: Bool {
        self == .completed || self == .failed
    }
}

struct DownloadTraceEvent: Sendable {
    enum Kind: String, Sendable {
        case info
        case success
        case warning
        case error
    }

    let kind: Kind
    let message: String
}

struct DownloadJob: Identifiable, Sendable {
    let id: UUID
    let request: TweetRequest
    var phase: DownloadJobPhase
    var progress: Double
    var displayTitle: String?
    var selectedFormatID: String?
    var outputFilename: String?
    var localFileURL: URL?
    var savedFileSize: Int64?
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        request: TweetRequest,
        phase: DownloadJobPhase = .idle,
        progress: Double = 0,
        displayTitle: String? = nil,
        selectedFormatID: String? = nil,
        outputFilename: String? = nil,
        localFileURL: URL? = nil,
        savedFileSize: Int64? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.request = request
        self.phase = phase
        self.progress = progress
        self.displayTitle = displayTitle
        self.selectedFormatID = selectedFormatID
        self.outputFilename = outputFilename
        self.localFileURL = localFileURL
        self.savedFileSize = savedFileSize
        self.errorMessage = errorMessage
    }
}
