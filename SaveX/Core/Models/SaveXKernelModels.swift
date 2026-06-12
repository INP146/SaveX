import Foundation

struct TweetRequest: Codable, Sendable, Equatable {
    let sourceURL: URL
    let tweetID: String
    let screenName: String?
    let selectedMediaIndex: Int?
    let selectedMediaKind: TweetMediaSelectionKind?

    init(
        sourceURL: URL,
        tweetID: String,
        screenName: String?,
        selectedMediaIndex: Int?,
        selectedMediaKind: TweetMediaSelectionKind? = nil
    ) {
        self.sourceURL = sourceURL
        self.tweetID = tweetID
        self.screenName = screenName
        self.selectedMediaIndex = selectedMediaIndex
        self.selectedMediaKind = selectedMediaKind
    }

    var displayID: String {
        tweetID
    }
}

enum TweetMediaSelectionKind: String, Codable, Sendable, Equatable {
    case video
    case photo
}

enum MediaTransport: String, Codable, Sendable {
    case http
    case https
    case m3u8
    case m3u8Native
    case external
    case unknown
}

enum MediaContainer: String, Codable, Sendable {
    case mp4
    case m3u8
    case ts
    case unknown
}

enum FormatSortField: String, Codable, Sendable {
    case resolution
    case preferM3U8
    case bitrate
    case fileSize
}

struct MediaSubtitle: Codable, Sendable {
    let languageCode: String
    let url: URL
}

struct MediaThumbnail: Codable, Sendable {
    let id: String
    let url: URL
    let width: Int?
    let height: Int?
}

struct MediaFormat: Identifiable, Codable, Sendable {
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
    let sourceMediaIndex: Int?
    let ageLimit: Int
    let tags: [String]
    let duration: Double?
    let formats: [MediaFormat]
    let subtitles: [MediaSubtitle]
    let thumbnails: [MediaThumbnail]
    let externalReferenceURL: URL?
    let formatSortFields: [FormatSortField]
}

enum DownloadJobPhase: String, Codable, Sendable {
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
    case waitingForSystem
    case paused
    case exportingMedia
    case savingToPhotos
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

struct DownloadProgressEvent: Sendable {
    enum Kind: String, Sendable {
        case phase
        case fileTransfer
        case hlsSegment
        case export
        case photoSave
    }

    let kind: Kind
    let phase: DownloadJobPhase
    let progress: Double
    let formatID: String?
    let downloadedBytes: Int64?
    let totalBytes: Int64?
    let speedBytesPerSecond: Double?
    let etaSeconds: TimeInterval?
    let completedSegmentCount: Int?
    let totalSegmentCount: Int?
    let message: String?

    init(
        kind: Kind,
        phase: DownloadJobPhase,
        progress: Double,
        formatID: String? = nil,
        downloadedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        speedBytesPerSecond: Double? = nil,
        etaSeconds: TimeInterval? = nil,
        completedSegmentCount: Int? = nil,
        totalSegmentCount: Int? = nil,
        message: String? = nil
    ) {
        self.kind = kind
        self.phase = phase
        self.progress = min(max(progress, 0), 1)
        self.formatID = formatID
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.speedBytesPerSecond = speedBytesPerSecond
        self.etaSeconds = etaSeconds
        self.completedSegmentCount = completedSegmentCount
        self.totalSegmentCount = totalSegmentCount
        self.message = message
    }
}

struct DownloadJob: Identifiable, Codable, Sendable {
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
    var downloadedBytes: Int64?
    var totalBytes: Int64?
    var speedBytesPerSecond: Double?
    var etaSeconds: TimeInterval?
    var completedSegmentCount: Int?
    var totalSegmentCount: Int?
    var progressMessage: String?

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
        errorMessage: String? = nil,
        downloadedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        speedBytesPerSecond: Double? = nil,
        etaSeconds: TimeInterval? = nil,
        completedSegmentCount: Int? = nil,
        totalSegmentCount: Int? = nil,
        progressMessage: String? = nil
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
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.speedBytesPerSecond = speedBytesPerSecond
        self.etaSeconds = etaSeconds
        self.completedSegmentCount = completedSegmentCount
        self.totalSegmentCount = totalSegmentCount
        self.progressMessage = progressMessage
    }
}
