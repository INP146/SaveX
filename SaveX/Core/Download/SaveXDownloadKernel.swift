import Foundation

enum DownloadExecutionPlan: Sendable {
    case singleFile(MediaFormat)
    case hls(MediaFormat)
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
        if format.isHLS {
            return .hls(format)
        }
        guard format.transport == .http || format.transport == .https else {
            throw SaveXError.notImplemented("Unsupported transport: \(format.transport.rawValue)")
        }
        return .singleFile(format)
    }
}

struct HLSVariant: Sendable {
    let url: URL
    let bandwidth: Int?
    let averageBandwidth: Int?
    let codecs: String?
    let width: Int?
    let height: Int?
}

struct HLSSegment: Sendable {
    let url: URL
    let duration: Double?
    let title: String?
}

struct HLSMediaPlaylist: Sendable {
    let targetDuration: Double?
    let segments: [HLSSegment]
    let hasEndList: Bool
}

enum HLSManifest: Sendable {
    case master(variants: [HLSVariant])
    case media(HLSMediaPlaylist)
}

struct HLSManifestParser {
    func parse(_ data: Data, baseURL: URL) throws -> HLSManifest {
        guard let source = String(data: data, encoding: .utf8) else {
            throw SaveXError.invalidResponse("HLS manifest was not UTF-8 text")
        }
        return try parse(source, baseURL: baseURL)
    }

    func parse(_ source: String, baseURL: URL) throws -> HLSManifest {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.first == "#EXTM3U" else {
            throw SaveXError.invalidResponse("HLS manifest is missing #EXTM3U")
        }

        try rejectUnsupportedLowLatencyTags(in: lines)

        let hasStreamInf = lines.contains { $0.hasPrefix("#EXT-X-STREAM-INF:") }
        return hasStreamInf
            ? try parseMaster(lines: lines, baseURL: baseURL)
            : try parseMedia(lines: lines, baseURL: baseURL)
    }

    private func parseMaster(lines: [String], baseURL: URL) throws -> HLSManifest {
        var variants: [HLSVariant] = []
        var pendingAttributes: [String: String]?

        for line in lines.dropFirst() {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingAttributes = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                continue
            }

            guard !line.hasPrefix("#"), let attributes = pendingAttributes else {
                continue
            }

            variants.append(HLSVariant(
                url: try resolveURL(line, relativeTo: baseURL),
                bandwidth: attributes["BANDWIDTH"].flatMap(Int.init),
                averageBandwidth: attributes["AVERAGE-BANDWIDTH"].flatMap(Int.init),
                codecs: attributes["CODECS"],
                width: parseResolution(attributes["RESOLUTION"])?.width,
                height: parseResolution(attributes["RESOLUTION"])?.height
            ))
            pendingAttributes = nil
        }

        guard !variants.isEmpty else {
            throw SaveXError.invalidResponse("HLS master playlist contained no variants")
        }
        return .master(variants: variants)
    }

    private func parseMedia(lines: [String], baseURL: URL) throws -> HLSManifest {
        var segments: [HLSSegment] = []
        var pendingDuration: Double?
        var pendingTitle: String?
        var targetDuration: Double?
        var hasEndList = false

        for line in lines.dropFirst() {
            if line.hasPrefix("#EXT-X-KEY:") {
                let attributes = parseAttributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                let method = attributes["METHOD"]?.uppercased() ?? ""
                if method != "NONE" {
                    throw SaveXError.unsupportedHLS("Encrypted media segments are not supported yet")
                }
                continue
            }

            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count))
                continue
            }

            if line.hasPrefix("#EXTINF:") {
                let payload = String(line.dropFirst("#EXTINF:".count))
                let pieces = payload.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                pendingDuration = pieces.first.flatMap { Double($0) }
                pendingTitle = pieces.count > 1 ? String(pieces[1]) : nil
                continue
            }

            if line == "#EXT-X-ENDLIST" {
                hasEndList = true
                continue
            }

            guard !line.hasPrefix("#") else {
                continue
            }

            segments.append(HLSSegment(
                url: try resolveURL(line, relativeTo: baseURL),
                duration: pendingDuration,
                title: pendingTitle
            ))
            pendingDuration = nil
            pendingTitle = nil
        }

        guard !segments.isEmpty else {
            throw SaveXError.invalidResponse("HLS media playlist contained no segments")
        }
        guard hasEndList else {
            throw SaveXError.unsupportedHLS("Live playlists are not supported yet")
        }

        return .media(HLSMediaPlaylist(
            targetDuration: targetDuration,
            segments: segments,
            hasEndList: hasEndList
        ))
    }

    private func rejectUnsupportedLowLatencyTags(in lines: [String]) throws {
        let unsupportedTags = [
            "#EXT-X-PART",
            "#EXT-X-SERVER-CONTROL",
            "#EXT-X-PRELOAD-HINT",
        ]
        if let tag = lines.first(where: { line in unsupportedTags.contains { line.hasPrefix($0) } }) {
            throw SaveXError.unsupportedHLS("Low-latency tag \(tag.split(separator: ":").first ?? Substring(tag)) is not supported yet")
        }
    }

    private func parseAttributes(_ string: String) -> [String: String] {
        var attributes: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var insideQuotes = false

        func commit() {
            let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedKey.isEmpty else {
                key = ""
                value = ""
                readingKey = true
                return
            }
            attributes[normalizedKey] = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            key = ""
            value = ""
            readingKey = true
        }

        for character in string {
            if readingKey {
                if character == "=" {
                    readingKey = false
                } else {
                    key.append(character)
                }
            } else {
                if character == "\"" {
                    insideQuotes.toggle()
                    value.append(character)
                } else if character == "," && !insideQuotes {
                    commit()
                } else {
                    value.append(character)
                }
            }
        }
        commit()
        return attributes
    }

    private func parseResolution(_ value: String?) -> (width: Int, height: Int)? {
        guard let value else {
            return nil
        }
        let pieces = value.lowercased().split(separator: "x", maxSplits: 1)
        guard pieces.count == 2,
              let width = Int(pieces[0]),
              let height = Int(pieces[1]) else {
            return nil
        }
        return (width, height)
    }

    private func resolveURL(_ value: String, relativeTo baseURL: URL) throws -> URL {
        guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL else {
            throw SaveXError.invalidURL(value)
        }
        return url
    }
}

actor HLSManifestLoader {
    private let session: URLSession
    private let parser: HLSManifestParser

    init(session: URLSession = .shared, parser: HLSManifestParser = HLSManifestParser()) {
        self.session = session
        self.parser = parser
    }

    func load(url: URL, headers: [String: String] = [:]) async throws -> HLSManifest {
        var request = URLRequest(url: url)
        for (header, value) in headers {
            request.setValue(value, forHTTPHeaderField: header)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SaveXError.invalidResponse("HLS manifest response was not HTTP")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SaveXError.apiError(
                HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
                statusCode: httpResponse.statusCode
            )
        }
        return try parser.parse(data, baseURL: url)
    }
}

actor HLSMediaDownloader {
    private let session: URLSession
    private let manifestLoader: HLSManifestLoader
    private let fileManager: FileManager

    init(
        session: URLSession = .shared,
        manifestLoader: HLSManifestLoader? = nil,
        fileManager: FileManager = .default
    ) {
        self.session = session
        self.manifestLoader = manifestLoader ?? HLSManifestLoader(session: session)
        self.fileManager = fileManager
    }

    func download(
        format: MediaFormat,
        tweetID: String,
        title: String,
        destinationDirectory: URL
    ) async throws -> DownloadedAsset {
        try ensureDirectoryExists(destinationDirectory)

        let initialManifest = try await manifestLoader.load(url: format.url, headers: format.httpHeaders)
        let playlist = try await resolveMediaPlaylist(
            from: initialManifest,
            headers: format.httpHeaders
        )

        let destinationURL = uniqueDestinationURL(
            in: destinationDirectory,
            baseName: makeFilename(tweetID: tweetID, title: title),
            ext: "ts"
        )
        let workingDirectory = destinationDirectory
            .appendingPathComponent(".savex-hls-\(UUID().uuidString)", isDirectory: true)
        try ensureDirectoryExists(workingDirectory)
        defer {
            try? fileManager.removeItem(at: workingDirectory)
        }

        fileManager.createFile(atPath: destinationURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? outputHandle.close()
        }

        for (index, segment) in playlist.segments.enumerated() {
            let data = try await downloadSegment(segment.url, headers: format.httpHeaders)
            let segmentURL = workingDirectory.appendingPathComponent(
                String(format: "segment-%05d.ts", index),
                isDirectory: false
            )
            try data.write(to: segmentURL, options: .atomic)
            try outputHandle.write(contentsOf: data)
        }

        let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return DownloadedAsset(
            sourceTweetID: tweetID,
            format: format,
            localFileURL: destinationURL,
            fileSize: fileSize,
            responseMimeType: "video/MP2T"
        )
    }

    private func resolveMediaPlaylist(
        from manifest: HLSManifest,
        headers: [String: String]
    ) async throws -> HLSMediaPlaylist {
        switch manifest {
        case let .media(playlist):
            return playlist
        case let .master(variants):
            guard let selected = variants.sorted(by: isBetterVariant).first else {
                throw SaveXError.invalidResponse("HLS master playlist contained no variants")
            }
            let selectedManifest = try await manifestLoader.load(url: selected.url, headers: headers)
            guard case let .media(playlist) = selectedManifest else {
                throw SaveXError.unsupportedHLS("Nested master playlists are not supported yet")
            }
            return playlist
        }
    }

    private func isBetterVariant(_ lhs: HLSVariant, _ rhs: HLSVariant) -> Bool {
        let lhsPixels = (lhs.width ?? 0) * (lhs.height ?? 0)
        let rhsPixels = (rhs.width ?? 0) * (rhs.height ?? 0)
        if lhsPixels != rhsPixels {
            return lhsPixels > rhsPixels
        }
        return (lhs.averageBandwidth ?? lhs.bandwidth ?? 0) > (rhs.averageBandwidth ?? rhs.bandwidth ?? 0)
    }

    private func downloadSegment(_ url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        for (header, value) in headers {
            request.setValue(value, forHTTPHeaderField: header)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SaveXError.invalidResponse("HLS segment response was not HTTP")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SaveXError.apiError(
                HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
                statusCode: httpResponse.statusCode
            )
        }
        return data
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
        case let .hls(format):
            await onTraceEvent?(.init(kind: .info, message: "Downloading HLS media"))
            await onPhaseChange?(.downloading, 0.9, format.formatID)
            return try await hlsDownloader.download(
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
