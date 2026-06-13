import Foundation

actor DownloadEngine {
    private let apiClient: TwitterAPIClient
    private let extractor: TwitterMediaExtractor
    private let selector: FormatSelector
    private let planner: DownloadPlanner
    private let fileDownloader: HTTPFileDownloader
    private let hlsDownloader: HLSMediaDownloader

    init(
        apiClient: TwitterAPIClient,
        extractor: TwitterMediaExtractor,
        selector: FormatSelector,
        planner: DownloadPlanner = DownloadPlanner(),
        fileDownloader: HTTPFileDownloader = HTTPFileDownloader(),
        hlsDownloader: HLSMediaDownloader = HLSMediaDownloader()
    ) {
        self.apiClient = apiClient
        self.extractor = extractor
        self.selector = selector
        self.planner = planner
        self.fileDownloader = fileDownloader
        self.hlsDownloader = hlsDownloader
    }

    func download(
        jobID: UUID? = nil,
        request: TweetRequest,
        mode: TwitterAPISelection = .graphql,
        preference: FormatSelectionPreference = .ytDLPCompatible,
        destinationDirectory: URL,
        onProgressEvent: (@Sendable (DownloadProgressEvent) async -> Void)? = nil,
        onTraceEvent: (@Sendable (DownloadTraceEvent) async -> Void)? = nil
    ) async throws -> DownloadedAsset {
        let (entry, format) = try await resolveEntryAndFormat(
            request: request,
            initialMode: mode,
            preference: preference,
            onProgressEvent: onProgressEvent,
            onTraceEvent: onTraceEvent
        )

        await onTraceEvent?(.init(kind: .info, message: "Planning \(format.formatID) using \(format.transport.rawValue)"))
        await onProgressEvent?(.init(
            kind: .phase,
            phase: .preparingDownload,
            progress: 0.8,
            formatID: format.formatID,
            message: "Planning download"
        ))
        let plan = try planner.makePlan(for: format)

        switch plan {
        case let .singleFile(format):
            await onTraceEvent?(.init(kind: .info, message: "Downloading single-file media"))
            await onProgressEvent?(.init(
                kind: .fileTransfer,
                phase: .downloading,
                progress: 0.82,
                formatID: format.formatID,
                message: "Starting file download"
            ))
            return try await fileDownloader.download(
                jobID: jobID,
                format: format,
                tweetID: request.tweetID,
                title: entry.title,
                destinationDirectory: destinationDirectory,
                onProgressEvent: onProgressEvent
            )
        case let .hls(format):
            await onTraceEvent?(.init(kind: .info, message: "Downloading HLS media"))
            await onProgressEvent?(.init(
                kind: .hlsSegment,
                phase: .downloading,
                progress: 0.82,
                formatID: format.formatID,
                message: "Starting HLS download"
            ))
            return try await hlsDownloader.download(
                jobID: jobID,
                format: format,
                tweetID: request.tweetID,
                title: entry.title,
                destinationDirectory: destinationDirectory,
                onProgressEvent: onProgressEvent,
                onTraceEvent: onTraceEvent
            )
        }
    }

    func cancelAndClean(jobID: UUID) async {
        await fileDownloader.cancelAndClean(jobID: jobID)
        await hlsDownloader.cancelAndClean(jobID: jobID)
    }

    private func resolveEntryAndFormat(
        request: TweetRequest,
        initialMode: TwitterAPISelection,
        preference: FormatSelectionPreference,
        onProgressEvent: (@Sendable (DownloadProgressEvent) async -> Void)?,
        onTraceEvent: (@Sendable (DownloadTraceEvent) async -> Void)?
    ) async throws -> (TweetMediaInfo, MediaFormat) {
        var modes = [initialMode, TwitterAPISelection.legacy, .syndication]
        modes = modes.reduce(into: []) { result, mode in
            if !result.contains(mode) {
                result.append(mode)
            }
        }

        let isLoggedIn = await apiClient.isLoggedIn()
        var recoverableError: Error?
        for mode in modes {
            var didReturnPayload = false
            do {
                await onTraceEvent?(.init(kind: .info, message: "Trying \(mode.rawValue) tweet source"))
                await onProgressEvent?(.init(
                    kind: .phase,
                    phase: .fetchingTweet,
                    progress: 0.2,
                    message: "Fetching tweet"
                ))
                let status = try await apiClient.fetchStatus(tweetID: request.tweetID, mode: mode)
                didReturnPayload = true

                await onTraceEvent?(.init(kind: .success, message: "\(mode.rawValue) returned tweet payload"))
                await onProgressEvent?(.init(
                    kind: .phase,
                    phase: .extractingMedia,
                    progress: 0.45,
                    message: "Extracting media"
                ))
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
                await onProgressEvent?(.init(
                    kind: .phase,
                    phase: .selectingFormat,
                    progress: 0.65,
                    message: "Selecting format"
                ))
                if let fallbackMessage = Self.formatPreferenceFallbackMessage(
                    formats: entry.formats,
                    preference: preference
                ) {
                    await onTraceEvent?(.init(kind: .warning, message: fallbackMessage))
                }
                let format = try selector.selectBest(from: entry.formats, preference: preference)
                await onTraceEvent?(.init(kind: .success, message: "Selected format \(format.formatID)"))
                return (entry, format)
            } catch {
                guard Self.shouldTryNextMode(
                    after: error,
                    isLoggedIn: isLoggedIn,
                    didReturnPayload: didReturnPayload
                ) else {
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

    private static func formatPreferenceFallbackMessage(
        formats: [MediaFormat],
        preference: FormatSelectionPreference
    ) -> String? {
        guard !formats.isEmpty else {
            return nil
        }

        switch preference {
        case .preferHLS where !formats.contains(where: \.isHLS):
            return "HLS stream was requested, but no HLS format was available. Falling back to best available format."
        case .preferMP4Direct where !formats.contains(where: { !$0.isHLS }):
            return "MP4 file was requested, but no direct MP4 format was available. Falling back to best available format."
        case let .exactFormatID(id) where !formats.contains(where: { $0.formatID == id || $0.id == id }):
            return "Format \(id) was requested, but it was not available. Falling back to best available format."
        default:
            return nil
        }
    }

    static func shouldTryNextMode(
        after error: Error,
        isLoggedIn: Bool = false,
        didReturnPayload: Bool = false
    ) -> Bool {
        guard let saveXError = error as? SaveXError else {
            return false
        }

        switch saveXError {
        case .noVideoFound, .noFormatsFound, .videoUnavailable, .mediaNotVideo:
            return !(isLoggedIn && didReturnPayload)
        case let .apiError(_, statusCode?):
            return statusCode == 404 || statusCode == 429
        default:
            return false
        }
    }
}
