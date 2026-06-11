import Foundation

enum DownloadExecutionPlan: Sendable {
    case singleFile(MediaFormat)
}

struct DownloadedAsset: Sendable {
    let sourceTweetID: String
    let format: MediaFormat
    let localFileURL: URL
    let fileSize: Int64
    let responseMimeType: String?
}

struct DownloadPlanner {
    func makePlan(for format: MediaFormat) throws -> DownloadExecutionPlan {
        guard !format.isHLS else {
            throw SaveXError.notImplemented("HLS downloader is not implemented yet")
        }
        guard format.transport == .http || format.transport == .https else {
            throw SaveXError.notImplemented("Unsupported transport: \(format.transport.rawValue)")
        }
        return .singleFile(format)
    }
}

actor HTTPFileDownloader {
    private let session: URLSession
    private let fileManager: FileManager

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    func download(
        format: MediaFormat,
        tweetID: String,
        title: String,
        destinationDirectory: URL
    ) async throws -> DownloadedAsset {
        try ensureDirectoryExists(destinationDirectory)

        var request = URLRequest(url: format.url)
        for (header, value) in format.httpHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }

        let (temporaryURL, response) = try await session.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SaveXError.invalidResponse("Download response was not HTTP")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SaveXError.apiError(
                HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
                statusCode: httpResponse.statusCode
            )
        }

        let destinationURL = uniqueDestinationURL(
            in: destinationDirectory,
            baseName: makeFilename(tweetID: tweetID, title: title),
            ext: fileExtension(for: format, mimeType: httpResponse.mimeType)
        )

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)

        let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return DownloadedAsset(
            sourceTweetID: tweetID,
            format: format,
            localFileURL: destinationURL,
            fileSize: fileSize,
            responseMimeType: httpResponse.mimeType
        )
    }

    private func ensureDirectoryExists(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func uniqueDestinationURL(in directory: URL, baseName: String, ext: String) -> URL {
        var candidate = directory.appendingPathComponent("\(baseName).\(ext)", isDirectory: false)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(index).\(ext)", isDirectory: false)
            index += 1
        }
        return candidate
    }

    private func makeFilename(tweetID: String, title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_"))
        let sanitizedScalars = title.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character(" ") }
        let sanitized = String(sanitizedScalars)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = sanitized.isEmpty ? "tweet-\(tweetID)" : sanitized
        return cleanedTitle(prefix, limit: 60).replacingOccurrences(of: " ", with: "-")
    }

    private func fileExtension(for format: MediaFormat, mimeType: String?) -> String {
        switch format.container {
        case .mp4:
            return "mp4"
        case .m3u8:
            return "m3u8"
        case .ts:
            return "ts"
        case .unknown:
            if let mimeType, mimeType.contains("mp4") {
                return "mp4"
            }
            if let ext = format.url.pathExtension.split(separator: "?").first, !ext.isEmpty {
                return String(ext)
            }
            return "bin"
        }
    }
}

actor DownloadEngine {
    private let apiClient: TwitterAPIClient
    private let extractor: TwitterMediaExtractor
    private let selector: FormatSelector
    private let planner: DownloadPlanner
    private let fileDownloader: HTTPFileDownloader

    init(
        apiClient: TwitterAPIClient,
        extractor: TwitterMediaExtractor,
        selector: FormatSelector,
        planner: DownloadPlanner = DownloadPlanner(),
        fileDownloader: HTTPFileDownloader = HTTPFileDownloader()
    ) {
        self.apiClient = apiClient
        self.extractor = extractor
        self.selector = selector
        self.planner = planner
        self.fileDownloader = fileDownloader
    }

    func download(
        request: TweetRequest,
        mode: TwitterAPISelection = .graphql,
        preference: FormatSelectionPreference = .ytDLPCompatible,
        destinationDirectory: URL,
        onPhaseChange: (@Sendable (DownloadJobPhase, Double, String?) async -> Void)? = nil,
        onTraceEvent: (@Sendable (DownloadTraceEvent) async -> Void)? = nil
    ) async throws -> DownloadedAsset {
        let (entry, format) = try await resolveEntryAndFormat(
            request: request,
            initialMode: mode,
            preference: preference,
            onPhaseChange: onPhaseChange,
            onTraceEvent: onTraceEvent
        )

        await onTraceEvent?(.init(kind: .info, message: "Planning \(format.formatID) using \(format.transport.rawValue)"))
        await onPhaseChange?(.preparingDownload, 0.8, format.formatID)
        let plan = try planner.makePlan(for: format)

        switch plan {
        case let .singleFile(format):
            await onTraceEvent?(.init(kind: .info, message: "Downloading single-file media"))
            await onPhaseChange?(.downloading, 0.9, format.formatID)
            return try await fileDownloader.download(
                format: format,
                tweetID: request.tweetID,
                title: entry.title,
                destinationDirectory: destinationDirectory
            )
        }
    }

    private func resolveEntryAndFormat(
        request: TweetRequest,
        initialMode: TwitterAPISelection,
        preference: FormatSelectionPreference,
        onPhaseChange: (@Sendable (DownloadJobPhase, Double, String?) async -> Void)?,
        onTraceEvent: (@Sendable (DownloadTraceEvent) async -> Void)?
    ) async throws -> (TweetMediaInfo, MediaFormat) {
        var modes = [initialMode, TwitterAPISelection.legacy, .syndication]
        modes = modes.reduce(into: []) { result, mode in
            if !result.contains(mode) {
                result.append(mode)
            }
        }

        var recoverableError: Error?
        for mode in modes {
            do {
                await onTraceEvent?(.init(kind: .info, message: "Trying \(mode.rawValue) tweet source"))
                await onPhaseChange?(.fetchingTweet, 0.2, nil)
                let status = try await apiClient.fetchStatus(tweetID: request.tweetID, mode: mode)

                await onTraceEvent?(.init(kind: .success, message: "\(mode.rawValue) returned tweet payload"))
                await onPhaseChange?(.extractingMedia, 0.45, nil)
                let entries = try await extractor.extractEntries(
                    from: status,
                    request: request,
                    loadVMAP: { url in
                        try await self.apiClient.fetchVMAP(url: url)
                    }
                )

                guard let entry = entries.first else {
                    throw SaveXError.noVideoFound
                }

                await onTraceEvent?(.init(kind: .success, message: "Extracted \(entries.count) media entr\(entries.count == 1 ? "y" : "ies") from \(mode.rawValue)"))
                await onPhaseChange?(.selectingFormat, 0.65, nil)
                let format = try selector.selectBest(from: entry.formats, preference: preference)
                await onTraceEvent?(.init(kind: .success, message: "Selected format \(format.formatID)"))
                return (entry, format)
            } catch {
                guard Self.shouldTryNextMode(after: error) else {
                    await onTraceEvent?(.init(kind: .error, message: "\(mode.rawValue) failed: \(error.localizedDescription)"))
                    throw error
                }
                await onTraceEvent?(.init(kind: .warning, message: "\(mode.rawValue) failed: \(error.localizedDescription). Trying fallback."))
                recoverableError = error
            }
        }

        await onTraceEvent?(.init(kind: .error, message: "All tweet sources failed"))
        throw recoverableError ?? SaveXError.noVideoFound
    }

    private static func shouldTryNextMode(after error: Error) -> Bool {
        guard let saveXError = error as? SaveXError else {
            return false
        }

        switch saveXError {
        case .noVideoFound, .noFormatsFound, .videoUnavailable, .mediaNotVideo:
            return true
        case let .apiError(_, statusCode?):
            return statusCode == 404 || statusCode == 429
        default:
            return false
        }
    }
}
