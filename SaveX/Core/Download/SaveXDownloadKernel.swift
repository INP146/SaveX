import Foundation
@preconcurrency import AVFoundation

enum DownloadExecutionPlan: Sendable {
    case singleFile(MediaFormat)
    case hls(MediaFormat)
}

struct DownloadedAsset: Codable, Sendable {
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

enum DownloadFileNaming {
    static func uniqueDestinationURL(
        in directory: URL,
        baseName: String,
        ext: String,
        fileExists: (String) -> Bool
    ) -> URL {
        var candidate = directory.appendingPathComponent("\(baseName).\(ext)", isDirectory: false)
        var index = 2
        while fileExists(candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(index).\(ext)", isDirectory: false)
            index += 1
        }
        return candidate
    }

    static func makeFilename(tweetID: String, title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_"))
        let sanitizedScalars = title.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character(" ") }
        let sanitized = String(sanitizedScalars)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = sanitized.isEmpty ? "tweet-\(tweetID)" : sanitized
        return cleanedTitle(prefix, limit: 60).replacingOccurrences(of: " ", with: "-")
    }

    static func fileExtension(for format: MediaFormat, mimeType: String?) -> String {
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

protocol HLSMediaExporting: Sendable {
    func exportMP4(from sourceURL: URL, to destinationURL: URL) async throws
}

struct AVFoundationHLSMediaExporter: HLSMediaExporting {
    func exportMP4(from sourceURL: URL, to destinationURL: URL) async throws {
        let cancellationBox = HLSExportCancellationBox()
        try await withTaskCancellationHandler {
            let asset = AVURLAsset(url: sourceURL)
            guard let exportSession = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetPassthrough
            ) else {
                throw SaveXError.hlsExportFailed("AVFoundation could not create a passthrough export session")
            }
            cancellationBox.set(exportSession)
            guard exportSession.supportedFileTypes.contains(.mp4) else {
                throw SaveXError.hlsExportFailed("AVFoundation does not support MP4 export for this HLS media")
            }

            exportSession.outputURL = destinationURL
            exportSession.outputFileType = .mp4
            exportSession.shouldOptimizeForNetworkUse = true

            do {
                try Task.checkCancellation()
                try await exportSession.export(to: destinationURL, as: .mp4)
                try Task.checkCancellation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let reason = error.localizedDescription
                throw SaveXError.hlsExportFailed(reason)
            }
        } onCancel: {
            cancellationBox.cancel()
        }
    }
}

private final class HLSExportCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var exportSession: AVAssetExportSession?

    func set(_ exportSession: AVAssetExportSession) {
        lock.lock()
        self.exportSession = exportSession
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let exportSession = exportSession
        lock.unlock()
        exportSession?.cancelExport()
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

            if line.hasPrefix("#EXT-X-MAP:") {
                throw SaveXError.unsupportedHLS("fMP4 HLS playlists with EXT-X-MAP are not supported yet")
            }

            if line.hasPrefix("#EXT-X-BYTERANGE:") {
                throw SaveXError.unsupportedHLS("Byte-range HLS playlists are not supported yet")
            }

            if line == "#EXT-X-DISCONTINUITY" {
                throw SaveXError.unsupportedHLS("HLS discontinuities are not supported yet")
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

struct HTTPResumeState: Codable, Sendable {
    let jobID: UUID
    let format: MediaFormat
    let tweetID: String
    let title: String
    let destinationDirectoryPath: String
    var resumeDataFileName: String?
    var partialFileName: String?
    var downloadedBytes: Int64?
    var totalBytes: Int64?
    var updatedAt: Date
}

final class HTTPResumeStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let lock = NSLock()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func state(jobID: UUID) -> HTTPResumeState? {
        lock.lock()
        defer { lock.unlock() }
        return loadState(jobID: jobID)
    }

    func resumeData(jobID: UUID) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let state = loadState(jobID: jobID),
              let fileName = state.resumeDataFileName else {
            return nil
        }
        return try? Data(contentsOf: resumeDataDirectory.appendingPathComponent(fileName, isDirectory: false))
    }

    func partialURL(jobID: UUID) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let state = loadState(jobID: jobID),
              let fileName = state.partialFileName else {
            return nil
        }
        let url = partialDirectory.appendingPathComponent(fileName, isDirectory: false)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func saveResumeData(
        _ data: Data,
        jobID: UUID,
        format: MediaFormat,
        tweetID: String,
        title: String,
        destinationDirectory: URL,
        totalBytes: Int64?
    ) {
        lock.lock()
        defer { lock.unlock() }

        do {
            try fileManager.createDirectory(at: resumeDataDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: partialDirectory, withIntermediateDirectories: true)

            let resumeFileName = "\(jobID.uuidString).resume"
            let resumeURL = resumeDataDirectory.appendingPathComponent(resumeFileName, isDirectory: false)
            try data.write(to: resumeURL, options: .atomic)

            var partialFileName = loadState(jobID: jobID)?.partialFileName
            if let sourcePartialURL = sourcePartialURL(fromResumeData: data) {
                let destinationFileName = "\(jobID.uuidString).partial"
                let destinationURL = partialDirectory.appendingPathComponent(destinationFileName, isDirectory: false)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try? fileManager.removeItem(at: destinationURL)
                }
                try? fileManager.copyItem(at: sourcePartialURL, to: destinationURL)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    partialFileName = destinationFileName
                }
            }

            let partialBytes = partialFileName.flatMap { fileName -> Int64? in
                let url = partialDirectory.appendingPathComponent(fileName, isDirectory: false)
                return (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            }

            saveState(HTTPResumeState(
                jobID: jobID,
                format: format,
                tweetID: tweetID,
                title: title,
                destinationDirectoryPath: destinationDirectory.path,
                resumeDataFileName: resumeFileName,
                partialFileName: partialFileName,
                downloadedBytes: partialBytes ?? resumeBytesReceived(fromResumeData: data),
                totalBytes: totalBytes,
                updatedAt: Date()
            ))
        } catch {
            assertionFailure("Failed to persist resume data: \(error.localizedDescription)")
        }
    }

    func clear(jobID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let state = loadState(jobID: jobID) else {
            return
        }
        if let resumeDataFileName = state.resumeDataFileName {
            try? fileManager.removeItem(at: resumeDataDirectory.appendingPathComponent(resumeDataFileName, isDirectory: false))
        }
        if let partialFileName = state.partialFileName {
            try? fileManager.removeItem(at: partialDirectory.appendingPathComponent(partialFileName, isDirectory: false))
        }
        try? fileManager.removeItem(at: stateURL(jobID: jobID))
    }

    private func loadState(jobID: UUID) -> HTTPResumeState? {
        let url = stateURL(jobID: jobID)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HTTPResumeState.self, from: data)
    }

    private func saveState(_ state: HTTPResumeState) {
        do {
            try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: stateURL(jobID: state.jobID), options: .atomic)
        } catch {
            assertionFailure("Failed to persist resume state: \(error.localizedDescription)")
        }
    }

    private func sourcePartialURL(fromResumeData data: Data) -> URL? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        if let path = plist["NSURLSessionResumeInfoLocalPath"] as? String {
            let url = URL(fileURLWithPath: path, isDirectory: false)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        if let tempFileName = plist["NSURLSessionResumeInfoTempFileName"] as? String {
            let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent(tempFileName, isDirectory: false)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        return nil
    }

    private func resumeBytesReceived(fromResumeData data: Data) -> Int64? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return (plist["NSURLSessionResumeBytesReceived"] as? NSNumber)?.int64Value
            ?? (plist["NSURLSessionResumeInfoBytesReceived"] as? NSNumber)?.int64Value
    }

    private func stateURL(jobID: UUID) -> URL {
        stateDirectory.appendingPathComponent("\(jobID.uuidString).json", isDirectory: false)
    }

    private var stateDirectory: URL {
        rootDirectory.appendingPathComponent("HTTPResumeState", isDirectory: true)
    }

    private var resumeDataDirectory: URL {
        rootDirectory.appendingPathComponent("ResumeData", isDirectory: true)
    }

    private var partialDirectory: URL {
        rootDirectory.appendingPathComponent("PartialHTTP", isDirectory: true)
    }

    private var rootDirectory: URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return applicationSupport.appendingPathComponent("SaveX", isDirectory: true)
    }
}

struct HLSResumeState: Codable, Sendable {
    let jobID: UUID
    let formatID: String
    let manifestURL: URL
    let segmentURLs: [URL]
    var completedSegmentIndices: [Int]
    var updatedAt: Date
}

final class HLSResumeStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let lock = NSLock()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func workingDirectory(jobID: UUID) -> URL {
        rootDirectory.appendingPathComponent(jobID.uuidString, isDirectory: true)
    }

    func state(jobID: UUID) -> HLSResumeState? {
        lock.lock()
        defer { lock.unlock() }
        return loadState(jobID: jobID)
    }

    func prepareState(jobID: UUID, format: MediaFormat, segments: [HLSSegment]) {
        lock.lock()
        defer { lock.unlock() }

        let segmentURLs = segments.map(\.url)
        if let existing = loadState(jobID: jobID),
           existing.formatID == format.formatID,
           existing.manifestURL == format.url,
           existing.segmentURLs == segmentURLs {
            return
        }

        try? fileManager.removeItem(at: workingDirectory(jobID: jobID))
        saveState(HLSResumeState(
            jobID: jobID,
            formatID: format.formatID,
            manifestURL: format.url,
            segmentURLs: segmentURLs,
            completedSegmentIndices: [],
            updatedAt: Date()
        ))
    }

    func markCompleted(index: Int, jobID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard var state = loadState(jobID: jobID) else {
            return
        }
        if !state.completedSegmentIndices.contains(index) {
            state.completedSegmentIndices.append(index)
            state.completedSegmentIndices.sort()
        }
        state.updatedAt = Date()
        saveState(state)
    }

    func clear(jobID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: workingDirectory(jobID: jobID))
        try? fileManager.removeItem(at: stateURL(jobID: jobID))
    }

    private func loadState(jobID: UUID) -> HLSResumeState? {
        guard let data = try? Data(contentsOf: stateURL(jobID: jobID)) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HLSResumeState.self, from: data)
    }

    private func saveState(_ state: HLSResumeState) {
        do {
            try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: stateURL(jobID: state.jobID), options: .atomic)
        } catch {
            assertionFailure("Failed to persist HLS resume state: \(error.localizedDescription)")
        }
    }

    private func stateURL(jobID: UUID) -> URL {
        stateDirectory.appendingPathComponent("\(jobID.uuidString).json", isDirectory: false)
    }

    private var stateDirectory: URL {
        rootDirectory.appendingPathComponent("State", isDirectory: true)
    }

    private var rootDirectory: URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("SaveX", isDirectory: true)
            .appendingPathComponent("HLSJobs", isDirectory: true)
    }
}

actor HLSMediaDownloader {
    private let session: URLSession
    private let manifestLoader: HLSManifestLoader
    private let exporter: any HLSMediaExporting
    private let fileManager: FileManager
    private let resumeStore: HLSResumeStore

    init(
        session: URLSession = .shared,
        manifestLoader: HLSManifestLoader? = nil,
        exporter: any HLSMediaExporting = AVFoundationHLSMediaExporter(),
        fileManager: FileManager = .default,
        resumeStore: HLSResumeStore? = nil
    ) {
        self.session = session
        self.manifestLoader = manifestLoader ?? HLSManifestLoader(session: session)
        self.exporter = exporter
        self.fileManager = fileManager
        self.resumeStore = resumeStore ?? HLSResumeStore(fileManager: fileManager)
    }

    func download(
        jobID: UUID? = nil,
        format: MediaFormat,
        tweetID: String,
        title: String,
        destinationDirectory: URL,
        onProgressEvent: (@Sendable (DownloadProgressEvent) async -> Void)? = nil,
        onTraceEvent: (@Sendable (DownloadTraceEvent) async -> Void)? = nil
    ) async throws -> DownloadedAsset {
        try ensureDirectoryExists(destinationDirectory)

        let initialManifest = try await manifestLoader.load(url: format.url, headers: format.httpHeaders)
        let playlist = try await resolveMediaPlaylist(
            from: initialManifest,
            headers: format.httpHeaders
        )

        await onProgressEvent?(.init(
            kind: .hlsSegment,
            phase: .downloading,
            progress: 0.82,
            formatID: format.formatID,
            downloadedBytes: 0,
            completedSegmentCount: 0,
            totalSegmentCount: playlist.segments.count,
            message: "\(playlist.segments.count) HLS segments"
        ))

        let baseName = makeFilename(tweetID: tweetID, title: title)
        let workingDirectory = jobID.map { resumeStore.workingDirectory(jobID: $0) }
            ?? destinationDirectory.appendingPathComponent(".savex-hls-\(UUID().uuidString)", isDirectory: true)

        if let jobID {
            resumeStore.prepareState(jobID: jobID, format: format, segments: playlist.segments)
        }
        try ensureDirectoryExists(workingDirectory)

        var shouldCleanWorkingDirectory = jobID == nil
        defer {
            if shouldCleanWorkingDirectory {
                try? fileManager.removeItem(at: workingDirectory)
            }
        }

        await onTraceEvent?(.init(kind: .info, message: "Assembling HLS segments"))
        var downloadedBytes: Int64 = 0
        let assembledURL = workingDirectory.appendingPathComponent("\(baseName).ts", isDirectory: false)
        if fileManager.fileExists(atPath: assembledURL.path) {
            try? fileManager.removeItem(at: assembledURL)
        }
        fileManager.createFile(atPath: assembledURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: assembledURL)
        defer {
            try? outputHandle.close()
        }

        let completedIndices = jobID
            .flatMap { resumeStore.state(jobID: $0)?.completedSegmentIndices }
            .map(Set.init) ?? []

        for (index, segment) in playlist.segments.enumerated() {
            try Task.checkCancellation()
            let segmentURL = workingDirectory.appendingPathComponent(
                String(format: "segment-%05d.ts", index),
                isDirectory: false
            )

            let data: Data
            if completedIndices.contains(index),
               fileManager.fileExists(atPath: segmentURL.path) {
                data = try Data(contentsOf: segmentURL)
                await onTraceEvent?(.init(kind: .info, message: "Reusing HLS segment \(index + 1)"))
            } else {
                data = try await downloadSegment(segment.url, headers: format.httpHeaders)
                try data.write(to: segmentURL, options: .atomic)
                if let jobID {
                    resumeStore.markCompleted(index: index, jobID: jobID)
                }
            }

            try outputHandle.write(contentsOf: data)
            downloadedBytes += Int64(data.count)

            let completedSegments = index + 1
            let segmentProgress = Double(completedSegments) / Double(playlist.segments.count)
            await onProgressEvent?(.init(
                kind: .hlsSegment,
                phase: .downloading,
                progress: 0.82 + (segmentProgress * 0.12),
                formatID: format.formatID,
                downloadedBytes: downloadedBytes,
                completedSegmentCount: completedSegments,
                totalSegmentCount: playlist.segments.count,
                message: "Downloaded segment \(completedSegments) of \(playlist.segments.count)"
            ))
        }

        try Task.checkCancellation()
        let destinationURL = uniqueDestinationURL(
            in: destinationDirectory,
            baseName: baseName,
            ext: "mp4"
        )
        await onTraceEvent?(.init(kind: .info, message: "Exporting HLS media to MP4"))
        await onProgressEvent?(.init(
            kind: .export,
            phase: .exportingMedia,
            progress: 0.96,
            formatID: format.formatID,
            downloadedBytes: downloadedBytes,
            completedSegmentCount: playlist.segments.count,
            totalSegmentCount: playlist.segments.count,
            message: "Exporting HLS media to MP4"
        ))
        do {
            try await exporter.exportMP4(from: assembledURL, to: destinationURL)
            try Task.checkCancellation()
        } catch {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.removeItem(at: destinationURL)
            }
            throw error
        }

        let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if let jobID {
            resumeStore.clear(jobID: jobID)
        }
        shouldCleanWorkingDirectory = true
        return DownloadedAsset(
            sourceTweetID: tweetID,
            format: format,
            localFileURL: destinationURL,
            fileSize: fileSize,
            responseMimeType: "video/mp4"
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
        DownloadFileNaming.uniqueDestinationURL(in: directory, baseName: baseName, ext: ext) { path in
            fileManager.fileExists(atPath: path)
        }
    }

    private func makeFilename(tweetID: String, title: String) -> String {
        DownloadFileNaming.makeFilename(tweetID: tweetID, title: title)
    }
}

final class BackgroundHTTPDownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundHTTPDownloadCoordinator()
    static let sessionIdentifier = "com.savex.background.http-file"

    private struct TaskMetadata: Codable {
        let taskIdentifier: Int
        let jobID: UUID
        let format: MediaFormat
        let tweetID: String
        let title: String
        let destinationDirectoryPath: String
    }

    private struct DetachedCompletion: Codable {
        let jobID: UUID
        let asset: DownloadedAsset
    }

    private struct ActiveDownload {
        let continuation: CheckedContinuation<DownloadedAsset, Error>
        let jobID: UUID?
        let format: MediaFormat
        let tweetID: String
        let title: String
        let destinationDirectory: URL
        let onProgressEvent: (@Sendable (DownloadProgressEvent) async -> Void)?
        let startedAt: Date
        let didUseResumeData: Bool
        var lastProgressAt: Date
    }

    private struct RestoredTaskObserver {
        let jobID: UUID
        let onProgressEvent: (@Sendable (DownloadProgressEvent) async -> Void)?
        let startedAt: Date
        var lastProgressAt: Date
    }

    private let fileManager: FileManager
    private let resumeStore: HTTPResumeStore
    private let rangeFallbackSession: URLSession
    private let lock = NSLock()
    private var activeDownloads: [Int: ActiveDownload] = [:]
    private var restoredTaskObservers: [UUID: RestoredTaskObserver] = [:]
    private var completedDownloads: [Int: Result<DownloadedAsset, Error>] = [:]
    private var backgroundCompletionHandlers: [String: () -> Void] = [:]
    private var detachedCompletionHandler: (@Sendable (UUID, DownloadedAsset) -> Void)?
    private var pausingJobIDs: Set<UUID> = []

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(
        fileManager: FileManager = .default,
        resumeStore: HTTPResumeStore? = nil,
        rangeFallbackSession: URLSession = .shared
    ) {
        self.fileManager = fileManager
        self.resumeStore = resumeStore ?? HTTPResumeStore(fileManager: fileManager)
        self.rangeFallbackSession = rangeFallbackSession
        super.init()
    }

    func setBackgroundCompletionHandler(_ completionHandler: @escaping () -> Void, for identifier: String) {
        guard identifier == Self.sessionIdentifier else {
            completionHandler()
            return
        }
        lock.lock()
        backgroundCompletionHandlers[identifier] = completionHandler
        lock.unlock()
        _ = session
    }

    func observeRestoredTasks(
        jobIDs: Set<UUID>,
        onProgressEvent: (@Sendable (UUID, DownloadProgressEvent) async -> Void)? = nil
    ) async -> Set<UUID> {
        guard !jobIDs.isEmpty else {
            _ = session
            return []
        }

        registerRestoredObservers(jobIDs: jobIDs, onProgressEvent: onProgressEvent)

        let tasks = await session.allTasks
        let metadataList = loadMetadata()
        var attachedPairs: [(TaskMetadata, URLSessionTask)] = []

        for metadata in metadataList where jobIDs.contains(metadata.jobID) {
            if let task = tasks.first(where: { taskMatchesMetadata($0, metadata: metadata) }) {
                if task.taskIdentifier != metadata.taskIdentifier {
                    replaceMetadataTaskIdentifier(
                        jobID: metadata.jobID,
                        oldTaskIdentifier: metadata.taskIdentifier,
                        newTaskIdentifier: task.taskIdentifier
                    )
                }
                attachedPairs.append((metadata, task))
            }
        }

        let attachedJobIDs = Set(attachedPairs.map(\.0.jobID))

        for (metadata, task) in attachedPairs {
            await emitRestoredProgress(
                metadata: metadata,
                downloadedBytes: task.countOfBytesReceived,
                totalBytes: task.countOfBytesExpectedToReceive,
                force: true
            )
        }
        return attachedJobIDs
    }

    func cancel(jobID: UUID) async {
        let tasks = await session.allTasks
        let metadataList = loadMetadata().filter { $0.jobID == jobID }

        for task in tasks where taskMatchesJob(task, jobID: jobID, metadataList: metadataList) {
            task.cancel()
        }

        for metadata in metadataList {
            removeMetadata(taskIdentifier: metadata.taskIdentifier)
        }
        acknowledgeDetachedCompletion(jobID: jobID)
        removeRestoredObserver(jobID: jobID)
        resumeStore.clear(jobID: jobID)
    }

    func pause(jobID: UUID) async -> Bool {
        let tasks = await session.allTasks
        let metadataList = loadMetadata().filter { $0.jobID == jobID }
        let matchedTasks = tasks.compactMap { task -> URLSessionDownloadTask? in
            guard taskMatchesJob(task, jobID: jobID, metadataList: metadataList) else {
                return nil
            }
            return task as? URLSessionDownloadTask
        }

        guard !matchedTasks.isEmpty else {
            return false
        }

        markPausing(jobID: jobID)

        for task in matchedTasks {
            let resumeData = await cancelByProducingResumeData(task)
            let metadata = metadata(for: task, metadataList: metadataList)
            if let resumeData,
               let metadata {
                resumeStore.saveResumeData(
                    resumeData,
                    jobID: jobID,
                    format: metadata.format,
                    tweetID: metadata.tweetID,
                    title: metadata.title,
                    destinationDirectory: URL(fileURLWithPath: metadata.destinationDirectoryPath, isDirectory: true),
                    totalBytes: normalizedTotalBytes(task.countOfBytesExpectedToReceive, fallback: metadata.format.fileSizeApprox)
                )
            }
            if let metadata {
                removeMetadata(taskIdentifier: metadata.taskIdentifier)
            } else {
                removeMetadata(taskIdentifier: task.taskIdentifier)
            }
        }

        return true
    }

    private func cancelByProducingResumeData(_ task: URLSessionDownloadTask) async -> Data? {
        await withCheckedContinuation { continuation in
            task.cancel(byProducingResumeData: { resumeData in
                continuation.resume(returning: resumeData)
            })
        }
    }

    private func markPausing(jobID: UUID) {
        lock.lock()
        pausingJobIDs.insert(jobID)
        lock.unlock()
    }

    func setDetachedCompletionHandler(_ handler: (@Sendable (UUID, DownloadedAsset) -> Void)?) {
        lock.lock()
        detachedCompletionHandler = handler
        lock.unlock()
        _ = session
    }

    func pendingDetachedCompletions() -> [(UUID, DownloadedAsset)] {
        lock.lock()
        let completions = loadDetachedCompletions()
        lock.unlock()
        return completions.map { ($0.jobID, $0.asset) }
    }

    func acknowledgeDetachedCompletion(jobID: UUID) {
        lock.lock()
        var completions = loadDetachedCompletions()
        completions.removeAll { $0.jobID == jobID }
        saveDetachedCompletions(completions)
        lock.unlock()
    }

    func download(
        jobID: UUID?,
        format: MediaFormat,
        tweetID: String,
        title: String,
        destinationDirectory: URL,
        onProgressEvent: (@Sendable (DownloadProgressEvent) async -> Void)? = nil
    ) async throws -> DownloadedAsset {
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        var request = URLRequest(url: format.url)
        for (header, value) in format.httpHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }

        let storedResumeData = jobID.flatMap { resumeStore.resumeData(jobID: $0) }

        return try await withCheckedThrowingContinuation { continuation in
            let task = storedResumeData
                .map { session.downloadTask(withResumeData: $0) }
                ?? session.downloadTask(with: request)
            task.taskDescription = jobID?.uuidString
            let activeDownload = ActiveDownload(
                continuation: continuation,
                jobID: jobID,
                format: format,
                tweetID: tweetID,
                title: title,
                destinationDirectory: destinationDirectory,
                onProgressEvent: onProgressEvent,
                startedAt: Date(),
                didUseResumeData: storedResumeData != nil,
                lastProgressAt: Date(timeIntervalSince1970: 0)
            )

            lock.lock()
            activeDownloads[task.taskIdentifier] = activeDownload
            lock.unlock()

            if let jobID {
                upsertMetadata(TaskMetadata(
                    taskIdentifier: task.taskIdentifier,
                    jobID: jobID,
                    format: format,
                    tweetID: tweetID,
                    title: title,
                    destinationDirectoryPath: destinationDirectory.path
                ))
            }

            Task {
                await onProgressEvent?(.init(
                    kind: .fileTransfer,
                    phase: .waitingForSystem,
                    progress: 0.82,
                    formatID: format.formatID,
                    totalBytes: format.fileSizeApprox.map(Int64.init),
                    message: storedResumeData == nil ? "Background download queued" : "Resuming background download"
                ))
            }
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskIdentifier = downloadTask.taskIdentifier
        let now = Date()

        lock.lock()
        if var activeDownload = activeDownloads[taskIdentifier] {
            guard now.timeIntervalSince(activeDownload.lastProgressAt) >= 0.25 else {
                lock.unlock()
                return
            }
            activeDownload.lastProgressAt = now
            activeDownloads[taskIdentifier] = activeDownload
            lock.unlock()

            scheduleProgress(
                format: activeDownload.format,
                downloadedBytes: totalBytesWritten,
                totalBytes: normalizedTotalBytes(totalBytesExpectedToWrite, fallback: activeDownload.format.fileSizeApprox),
                startedAt: activeDownload.startedAt,
                onProgressEvent: activeDownload.onProgressEvent,
                message: "Background download"
            )
            return
        }
        lock.unlock()

        guard let metadata = metadata(for: downloadTask) else {
            return
        }
        Task {
            await self.emitRestoredProgress(
                metadata: metadata,
                downloadedBytes: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite,
                force: false
            )
        }
    }

    private func emitRestoredProgress(
        metadata: TaskMetadata,
        downloadedBytes: Int64,
        totalBytes: Int64,
        force: Bool
    ) async {
        guard let observer = restoredObserverForProgress(jobID: metadata.jobID, force: force) else {
            return
        }

        await emitProgress(
            format: metadata.format,
            downloadedBytes: downloadedBytes,
            totalBytes: normalizedTotalBytes(totalBytes, fallback: metadata.format.fileSizeApprox),
            startedAt: observer.startedAt,
            onProgressEvent: observer.onProgressEvent,
            message: "Background download"
        )
    }

    private func registerRestoredObservers(
        jobIDs: Set<UUID>,
        onProgressEvent: (@Sendable (UUID, DownloadProgressEvent) async -> Void)?
    ) {
        lock.lock()
        for jobID in jobIDs {
            restoredTaskObservers[jobID] = RestoredTaskObserver(
                jobID: jobID,
                onProgressEvent: { event in
                    await onProgressEvent?(jobID, event)
                },
                startedAt: Date(),
                lastProgressAt: Date(timeIntervalSince1970: 0)
            )
        }
        lock.unlock()
    }

    private func removeRestoredObserver(jobID: UUID) {
        lock.lock()
        restoredTaskObservers.removeValue(forKey: jobID)
        lock.unlock()
    }

    private func restoredObserverForProgress(jobID: UUID, force: Bool) -> RestoredTaskObserver? {
        let now = Date()

        lock.lock()
        defer {
            lock.unlock()
        }

        guard var observer = restoredTaskObservers[jobID] else {
            return nil
        }
        guard force || now.timeIntervalSince(observer.lastProgressAt) >= 0.25 else {
            return nil
        }
        observer.lastProgressAt = now
        restoredTaskObservers[jobID] = observer
        return observer
    }

    private func scheduleProgress(
        format: MediaFormat,
        downloadedBytes: Int64,
        totalBytes: Int64?,
        startedAt: Date,
        onProgressEvent: (@Sendable (DownloadProgressEvent) async -> Void)?,
        message: String
    ) {
        Task {
            await emitProgress(
                format: format,
                downloadedBytes: downloadedBytes,
                totalBytes: totalBytes,
                startedAt: startedAt,
                onProgressEvent: onProgressEvent,
                message: message
            )
        }
    }

    private func emitProgress(
        format: MediaFormat,
        downloadedBytes: Int64,
        totalBytes: Int64?,
        startedAt: Date,
        onProgressEvent: (@Sendable (DownloadProgressEvent) async -> Void)?,
        message: String
    ) async {
        let transferFraction: Double
        if let totalBytes, totalBytes > 0 {
            transferFraction = min(Double(downloadedBytes) / Double(totalBytes), 1)
        } else {
            transferFraction = 0
        }

        let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
        let speed = Double(downloadedBytes) / elapsed
        let eta: TimeInterval?
        if let totalBytes, totalBytes > downloadedBytes, speed > 0 {
            eta = Double(totalBytes - downloadedBytes) / speed
        } else {
            eta = nil
        }

        await onProgressEvent?(.init(
            kind: .fileTransfer,
            phase: .downloading,
            progress: 0.82 + (transferFraction * 0.14),
            formatID: format.formatID,
            downloadedBytes: downloadedBytes,
            totalBytes: totalBytes,
            speedBytesPerSecond: speed,
            etaSeconds: eta,
            message: message
        ))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskIdentifier = downloadTask.taskIdentifier

        lock.lock()
        let activeDownload = activeDownloads[taskIdentifier]
        lock.unlock()

        guard let activeDownload else {
            finishDetachedDownload(downloadTask: downloadTask, location: location)
            return
        }

        let result: Result<DownloadedAsset, Error>
        do {
            guard let httpResponse = downloadTask.response as? HTTPURLResponse else {
                throw SaveXError.invalidResponse("Download response was not HTTP")
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw SaveXError.apiError(
                    HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
                    statusCode: httpResponse.statusCode
                )
            }

            let destinationURL = uniqueDestinationURL(
                in: activeDownload.destinationDirectory,
                baseName: makeFilename(tweetID: activeDownload.tweetID, title: activeDownload.title),
                ext: fileExtension(for: activeDownload.format, mimeType: httpResponse.mimeType)
            )
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: location, to: destinationURL)

            let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
            let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            if let jobID = activeDownload.jobID {
                resumeStore.clear(jobID: jobID)
            }
            result = .success(DownloadedAsset(
                sourceTweetID: activeDownload.tweetID,
                format: activeDownload.format,
                localFileURL: destinationURL,
                fileSize: fileSize,
                responseMimeType: httpResponse.mimeType
            ))
        } catch {
            result = .failure(error)
        }

        lock.lock()
        completedDownloads[taskIdentifier] = result
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let taskIdentifier = task.taskIdentifier

        lock.lock()
        let activeDownload = activeDownloads.removeValue(forKey: taskIdentifier)
        let completedDownload = completedDownloads.removeValue(forKey: taskIdentifier)
        lock.unlock()

        guard let activeDownload else {
            if error != nil {
                if let metadata = metadata(for: task) {
                    removeMetadata(taskIdentifier: metadata.taskIdentifier)
                } else {
                    removeMetadata(taskIdentifier: taskIdentifier)
                }
            }
            return
        }
        removeMetadata(taskIdentifier: taskIdentifier)

        if let error {
            if let jobID = activeDownload.jobID,
               let resumeData = Self.resumeData(from: error) {
                resumeStore.saveResumeData(
                    resumeData,
                    jobID: jobID,
                    format: activeDownload.format,
                    tweetID: activeDownload.tweetID,
                    title: activeDownload.title,
                    destinationDirectory: activeDownload.destinationDirectory,
                    totalBytes: normalizedTotalBytes(task.countOfBytesExpectedToReceive, fallback: activeDownload.format.fileSizeApprox)
                )
            }
            if let jobID = activeDownload.jobID,
               removePausingJobID(jobID) {
                activeDownload.continuation.resume(throwing: SaveXError.downloadPaused)
                return
            }
            if activeDownload.didUseResumeData {
                Task {
                    do {
                        let asset = try await self.downloadUsingRangeFallback(activeDownload: activeDownload)
                        activeDownload.continuation.resume(returning: asset)
                    } catch {
                        activeDownload.continuation.resume(throwing: error)
                    }
                }
                return
            }
            activeDownload.continuation.resume(throwing: error)
            return
        }

        switch completedDownload {
        case let .success(asset):
            activeDownload.continuation.resume(returning: asset)
        case let .failure(error):
            activeDownload.continuation.resume(throwing: error)
        case .none:
            activeDownload.continuation.resume(throwing: SaveXError.invalidResponse("Background download finished without a file"))
        }
    }

    private func downloadUsingRangeFallback(activeDownload: ActiveDownload) async throws -> DownloadedAsset {
        let jobID = activeDownload.jobID
        let state = jobID.flatMap { resumeStore.state(jobID: $0) }
        let storedPartialURL = jobID.flatMap { resumeStore.partialURL(jobID: $0) }
        let partialURL = storedPartialURL ?? activeDownload.destinationDirectory
            .appendingPathComponent(".savex-range-\(UUID().uuidString).partial", isDirectory: false)

        try fileManager.createDirectory(at: partialURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var existingBytes = (try? fileManager.attributesOfItem(atPath: partialURL.path)[.size] as? NSNumber)?.int64Value ?? 0

        var request = URLRequest(url: activeDownload.format.url)
        for (header, value) in activeDownload.format.httpHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        if existingBytes > 0 {
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }

        await activeDownload.onProgressEvent?(.init(
            kind: .fileTransfer,
            phase: .downloading,
            progress: 0.82,
            formatID: activeDownload.format.formatID,
            downloadedBytes: existingBytes,
            totalBytes: state?.totalBytes,
            message: existingBytes > 0 ? "Resume data failed; using HTTP Range" : "Resume data failed; restarting file download"
        ))

        let (bytes, response) = try await rangeFallbackSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SaveXError.invalidResponse("Range fallback response was not HTTP")
        }

        switch httpResponse.statusCode {
        case 200..<300:
            break
        default:
            throw SaveXError.apiError(
                HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
                statusCode: httpResponse.statusCode
            )
        }

        if existingBytes > 0, httpResponse.statusCode == 206 {
            let contentRange = parsedContentRange(httpResponse.value(forHTTPHeaderField: "Content-Range"))
            if isValidRangeResponse(contentRange, expectedStart: existingBytes, expectedTotal: state?.totalBytes) {
                // Keep the existing partial file and append the requested suffix.
            } else if contentRange?.start == 0 {
                try? fileManager.removeItem(at: partialURL)
                fileManager.createFile(atPath: partialURL.path, contents: nil)
                existingBytes = 0
            } else {
                throw SaveXError.invalidResponse("Range fallback returned an unexpected Content-Range")
            }
        } else if existingBytes > 0 {
            try? fileManager.removeItem(at: partialURL)
            fileManager.createFile(atPath: partialURL.path, contents: nil)
            existingBytes = 0
        } else if !fileManager.fileExists(atPath: partialURL.path) {
            fileManager.createFile(atPath: partialURL.path, contents: nil)
        }

        let totalBytes = totalBytesForRangeResponse(httpResponse, alreadyDownloaded: existingBytes)
            ?? state?.totalBytes
            ?? activeDownload.format.fileSizeApprox.map(Int64.init)
        let outputHandle = try FileHandle(forWritingTo: partialURL)
        defer {
            try? outputHandle.close()
        }
        try outputHandle.seekToEnd()

        var downloadedBytes = existingBytes
        var buffer: [UInt8] = []
        buffer.reserveCapacity(64 * 1024)
        let startedAt = Date()
        var lastProgressAt = Date(timeIntervalSince1970: 0)

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try outputHandle.write(contentsOf: Data(buffer))
                downloadedBytes += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                await emitProgressIfNeeded(
                    activeDownload: activeDownload,
                    downloadedBytes: downloadedBytes,
                    totalBytes: totalBytes,
                    startedAt: startedAt,
                    lastProgressAt: &lastProgressAt,
                    force: false,
                    message: "HTTP Range fallback"
                )
            }
        }

        if !buffer.isEmpty {
            try outputHandle.write(contentsOf: Data(buffer))
            downloadedBytes += Int64(buffer.count)
        }
        try outputHandle.close()

        await emitProgressIfNeeded(
            activeDownload: activeDownload,
            downloadedBytes: downloadedBytes,
            totalBytes: totalBytes ?? downloadedBytes,
            startedAt: startedAt,
            lastProgressAt: &lastProgressAt,
            force: true,
            message: "HTTP Range fallback complete"
        )

        let destinationURL = uniqueDestinationURL(
            in: activeDownload.destinationDirectory,
            baseName: makeFilename(tweetID: activeDownload.tweetID, title: activeDownload.title),
            ext: fileExtension(for: activeDownload.format, mimeType: httpResponse.mimeType)
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: partialURL, to: destinationURL)

        if let jobID {
            resumeStore.clear(jobID: jobID)
        }

        let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return DownloadedAsset(
            sourceTweetID: activeDownload.tweetID,
            format: activeDownload.format,
            localFileURL: destinationURL,
            fileSize: fileSize,
            responseMimeType: httpResponse.mimeType
        )
    }

    private func emitProgressIfNeeded(
        activeDownload: ActiveDownload,
        downloadedBytes: Int64,
        totalBytes: Int64?,
        startedAt: Date,
        lastProgressAt: inout Date,
        force: Bool,
        message: String
    ) async {
        let now = Date()
        guard force || now.timeIntervalSince(lastProgressAt) >= 0.25 else {
            return
        }
        lastProgressAt = now
        await emitProgress(
            format: activeDownload.format,
            downloadedBytes: downloadedBytes,
            totalBytes: totalBytes,
            startedAt: startedAt,
            onProgressEvent: activeDownload.onProgressEvent,
            message: message
        )
    }

    private func totalBytesForRangeResponse(_ response: HTTPURLResponse, alreadyDownloaded: Int64) -> Int64? {
        if let range = parsedContentRange(response.value(forHTTPHeaderField: "Content-Range")) {
            return range.total
        }
        if response.expectedContentLength > 0 {
            return alreadyDownloaded + response.expectedContentLength
        }
        return nil
    }

    private func isValidRangeResponse(
        _ range: (start: Int64, end: Int64, total: Int64)?,
        expectedStart: Int64,
        expectedTotal: Int64?
    ) -> Bool {
        guard let range else {
            return false
        }
        guard range.start == expectedStart else {
            return false
        }
        if let expectedTotal, range.total != expectedTotal {
            return false
        }
        return range.end >= range.start
    }

    private func parsedContentRange(_ value: String?) -> (start: Int64, end: Int64, total: Int64)? {
        guard let value else {
            return nil
        }
        let pattern = #"^bytes\s+(\d+)-(\d+)/(\d+)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)),
              let startRange = Range(match.range(at: 1), in: value),
              let endRange = Range(match.range(at: 2), in: value),
              let totalRange = Range(match.range(at: 3), in: value),
              let start = Int64(value[startRange]),
              let end = Int64(value[endRange]),
              let total = Int64(value[totalRange]) else {
            return nil
        }
        return (start, end, total)
    }

    private func removePausingJobID(_ jobID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pausingJobIDs.remove(jobID) != nil
    }

    private static func resumeData(from error: Error) -> Data? {
        let nsError = error as NSError
        return nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let completionHandler = backgroundCompletionHandlers.removeValue(forKey: session.configuration.identifier ?? "")
        lock.unlock()
        completionHandler?()
    }

    private func finishDetachedDownload(downloadTask: URLSessionDownloadTask, location: URL) {
        guard let metadata = metadata(for: downloadTask) else {
            return
        }

        do {
            guard let httpResponse = downloadTask.response as? HTTPURLResponse else {
                throw SaveXError.invalidResponse("Download response was not HTTP")
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw SaveXError.apiError(
                    HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
                    statusCode: httpResponse.statusCode
                )
            }

            let destinationDirectory = URL(fileURLWithPath: metadata.destinationDirectoryPath, isDirectory: true)
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            let destinationURL = uniqueDestinationURL(
                in: destinationDirectory,
                baseName: makeFilename(tweetID: metadata.tweetID, title: metadata.title),
                ext: fileExtension(for: metadata.format, mimeType: httpResponse.mimeType)
            )
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: location, to: destinationURL)

            let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
            let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let asset = DownloadedAsset(
                sourceTweetID: metadata.tweetID,
                format: metadata.format,
                localFileURL: destinationURL,
                fileSize: fileSize,
                responseMimeType: httpResponse.mimeType
            )
            resumeStore.clear(jobID: metadata.jobID)
            appendDetachedCompletion(DetachedCompletion(jobID: metadata.jobID, asset: asset))
            notifyDetachedCompletion(jobID: metadata.jobID, asset: asset)
            removeMetadata(taskIdentifier: metadata.taskIdentifier)
        } catch {
            removeMetadata(taskIdentifier: metadata.taskIdentifier)
        }
    }

    private func normalizedTotalBytes(_ totalBytes: Int64, fallback: Int?) -> Int64? {
        if totalBytes > 0 {
            return totalBytes
        }
        if let fallback, fallback > 0 {
            return Int64(fallback)
        }
        return nil
    }

    private func notifyDetachedCompletion(jobID: UUID, asset: DownloadedAsset) {
        lock.lock()
        let handler = detachedCompletionHandler
        lock.unlock()
        handler?(jobID, asset)
    }

    private func upsertMetadata(_ metadata: TaskMetadata) {
        lock.lock()
        var metadataList = loadMetadata()
        metadataList.removeAll { $0.taskIdentifier == metadata.taskIdentifier }
        metadataList.removeAll { $0.jobID == metadata.jobID }
        metadataList.append(metadata)
        saveMetadata(metadataList)
        lock.unlock()
    }

    private func replaceMetadataTaskIdentifier(
        jobID: UUID,
        oldTaskIdentifier: Int,
        newTaskIdentifier: Int
    ) {
        lock.lock()
        var metadataList = loadMetadata()
        guard let index = metadataList.firstIndex(where: { $0.jobID == jobID || $0.taskIdentifier == oldTaskIdentifier }) else {
            lock.unlock()
            return
        }
        let metadata = metadataList[index]
        metadataList.removeAll { $0.jobID == metadata.jobID || $0.taskIdentifier == oldTaskIdentifier || $0.taskIdentifier == newTaskIdentifier }
        metadataList.append(TaskMetadata(
            taskIdentifier: newTaskIdentifier,
            jobID: metadata.jobID,
            format: metadata.format,
            tweetID: metadata.tweetID,
            title: metadata.title,
            destinationDirectoryPath: metadata.destinationDirectoryPath
        ))
        saveMetadata(metadataList)
        lock.unlock()
    }

    private func metadata(for task: URLSessionTask) -> TaskMetadata? {
        lock.lock()
        let metadata = metadata(for: task, metadataList: loadMetadata())
        lock.unlock()
        return metadata
    }

    private func metadata(for task: URLSessionTask, metadataList: [TaskMetadata]) -> TaskMetadata? {
        if let jobID = jobID(from: task.taskDescription),
           let metadata = metadataList.first(where: { $0.jobID == jobID }) {
            return metadata
        }
        return metadataList.first { $0.taskIdentifier == task.taskIdentifier }
    }

    private func taskMatchesJob(
        _ task: URLSessionTask,
        jobID: UUID,
        metadataList: [TaskMetadata]
    ) -> Bool {
        if task.taskDescription == jobID.uuidString {
            return true
        }
        return metadataList.contains { $0.jobID == jobID && $0.taskIdentifier == task.taskIdentifier }
    }

    private func taskMatchesMetadata(_ task: URLSessionTask, metadata: TaskMetadata) -> Bool {
        task.taskDescription == metadata.jobID.uuidString || task.taskIdentifier == metadata.taskIdentifier
    }

    private func jobID(from taskDescription: String?) -> UUID? {
        guard let taskDescription else {
            return nil
        }
        return UUID(uuidString: taskDescription)
    }

    private func removeMetadata(taskIdentifier: Int) {
        lock.lock()
        var metadataList = loadMetadata()
        metadataList.removeAll { $0.taskIdentifier == taskIdentifier }
        saveMetadata(metadataList)
        lock.unlock()
    }

    private func appendDetachedCompletion(_ completion: DetachedCompletion) {
        lock.lock()
        var completions = loadDetachedCompletions()
        completions.removeAll { $0.jobID == completion.jobID }
        completions.append(completion)
        saveDetachedCompletions(completions)
        lock.unlock()
    }

    private func loadMetadata() -> [TaskMetadata] {
        load([TaskMetadata].self, from: metadataURL) ?? []
    }

    private func saveMetadata(_ metadata: [TaskMetadata]) {
        save(metadata, to: metadataURL)
    }

    private func loadDetachedCompletions() -> [DetachedCompletion] {
        load([DetachedCompletion].self, from: detachedCompletionsURL) ?? []
    }

    private func saveDetachedCompletions(_ completions: [DetachedCompletion]) {
        save(completions, to: detachedCompletionsURL)
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            assertionFailure("Failed to persist background download state: \(error.localizedDescription)")
        }
    }

    private var metadataURL: URL {
        stateDirectory.appendingPathComponent("background-http-tasks.json", isDirectory: false)
    }

    private var detachedCompletionsURL: URL {
        stateDirectory.appendingPathComponent("background-http-completions.json", isDirectory: false)
    }

    private var stateDirectory: URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return applicationSupport.appendingPathComponent("SaveX", isDirectory: true)
    }

    private func uniqueDestinationURL(in directory: URL, baseName: String, ext: String) -> URL {
        DownloadFileNaming.uniqueDestinationURL(in: directory, baseName: baseName, ext: ext) { path in
            fileManager.fileExists(atPath: path)
        }
    }

    private func makeFilename(tweetID: String, title: String) -> String {
        DownloadFileNaming.makeFilename(tweetID: tweetID, title: title)
    }

    private func fileExtension(for format: MediaFormat, mimeType: String?) -> String {
        DownloadFileNaming.fileExtension(for: format, mimeType: mimeType)
    }
}

actor HTTPFileDownloader {
    private let session: URLSession?
    private let backgroundCoordinator: BackgroundHTTPDownloadCoordinator?
    private let fileManager: FileManager

    init(
        session: URLSession? = nil,
        backgroundCoordinator: BackgroundHTTPDownloadCoordinator? = .shared,
        fileManager: FileManager = .default
    ) {
        self.session = session
        self.backgroundCoordinator = backgroundCoordinator
        self.fileManager = fileManager
    }

    func download(
        jobID: UUID?,
        format: MediaFormat,
        tweetID: String,
        title: String,
        destinationDirectory: URL,
        onProgressEvent: (@Sendable (DownloadProgressEvent) async -> Void)? = nil
    ) async throws -> DownloadedAsset {
        if let backgroundCoordinator, session == nil {
            return try await backgroundCoordinator.download(
                jobID: jobID,
                format: format,
                tweetID: tweetID,
                title: title,
                destinationDirectory: destinationDirectory,
                onProgressEvent: onProgressEvent
            )
        }

        guard let session else {
            throw SaveXError.invalidResponse("No URLSession was available for file download")
        }
        try ensureDirectoryExists(destinationDirectory)

        var request = URLRequest(url: format.url)
        for (header, value) in format.httpHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SaveXError.invalidResponse("Download response was not HTTP")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SaveXError.apiError(
                HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
                statusCode: httpResponse.statusCode
            )
        }

        let expectedBytes = expectedContentLength(from: httpResponse, fallback: format.fileSizeApprox)
        let temporaryURL = destinationDirectory
            .appendingPathComponent(".savex-download-\(UUID().uuidString).tmp", isDirectory: false)
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }
        fileManager.createFile(atPath: temporaryURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: temporaryURL)
        var shouldCleanTemporaryFile = true
        defer {
            try? outputHandle.close()
            if shouldCleanTemporaryFile {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        var downloadedBytes: Int64 = 0
        var buffer: [UInt8] = []
        buffer.reserveCapacity(64 * 1024)
        let startedAt = Date()
        var lastProgressAt = Date(timeIntervalSince1970: 0)

        lastProgressAt = await emitFileProgress(
            downloadedBytes: downloadedBytes,
            totalBytes: expectedBytes,
            startedAt: startedAt,
            formatID: format.formatID,
            force: true,
            lastProgressAt: lastProgressAt,
            onProgressEvent: onProgressEvent
        )

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try outputHandle.write(contentsOf: Data(buffer))
                downloadedBytes += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                lastProgressAt = await emitFileProgress(
                    downloadedBytes: downloadedBytes,
                    totalBytes: expectedBytes,
                    startedAt: startedAt,
                    formatID: format.formatID,
                    force: false,
                    lastProgressAt: lastProgressAt,
                    onProgressEvent: onProgressEvent
                )
            }
        }

        if !buffer.isEmpty {
            try outputHandle.write(contentsOf: Data(buffer))
            downloadedBytes += Int64(buffer.count)
        }
        try outputHandle.close()

        lastProgressAt = await emitFileProgress(
            downloadedBytes: downloadedBytes,
            totalBytes: expectedBytes ?? downloadedBytes,
            startedAt: startedAt,
            formatID: format.formatID,
            force: true,
            lastProgressAt: lastProgressAt,
            onProgressEvent: onProgressEvent
        )

        let destinationURL = uniqueDestinationURL(
            in: destinationDirectory,
            baseName: makeFilename(tweetID: tweetID, title: title),
            ext: fileExtension(for: format, mimeType: httpResponse.mimeType)
        )

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        shouldCleanTemporaryFile = false

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
        DownloadFileNaming.uniqueDestinationURL(in: directory, baseName: baseName, ext: ext) { path in
            fileManager.fileExists(atPath: path)
        }
    }

    private func makeFilename(tweetID: String, title: String) -> String {
        DownloadFileNaming.makeFilename(tweetID: tweetID, title: title)
    }

    private func fileExtension(for format: MediaFormat, mimeType: String?) -> String {
        DownloadFileNaming.fileExtension(for: format, mimeType: mimeType)
    }

    private func expectedContentLength(from response: HTTPURLResponse, fallback: Int?) -> Int64? {
        if response.expectedContentLength > 0 {
            return response.expectedContentLength
        }
        if let fallback, fallback > 0 {
            return Int64(fallback)
        }
        return nil
    }

    private func emitFileProgress(
        downloadedBytes: Int64,
        totalBytes: Int64?,
        startedAt: Date,
        formatID: String,
        force: Bool,
        lastProgressAt: Date,
        onProgressEvent: (@Sendable (DownloadProgressEvent) async -> Void)?
    ) async -> Date {
        let now = Date()
        guard force || now.timeIntervalSince(lastProgressAt) >= 0.25 else {
            return lastProgressAt
        }

        let transferFraction: Double
        if let totalBytes, totalBytes > 0 {
            transferFraction = min(Double(downloadedBytes) / Double(totalBytes), 1)
        } else {
            transferFraction = 0
        }

        let elapsed = max(now.timeIntervalSince(startedAt), 0.001)
        let speed = Double(downloadedBytes) / elapsed
        let eta: TimeInterval?
        if let totalBytes, totalBytes > downloadedBytes, speed > 0 {
            eta = Double(totalBytes - downloadedBytes) / speed
        } else {
            eta = nil
        }

        await onProgressEvent?(.init(
            kind: .fileTransfer,
            phase: .downloading,
            progress: 0.82 + (transferFraction * 0.14),
            formatID: formatID,
            downloadedBytes: downloadedBytes,
            totalBytes: totalBytes,
            speedBytesPerSecond: speed,
            etaSeconds: eta,
            message: "Downloading file"
        ))
        return now
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

        var recoverableError: Error?
        for mode in modes {
            do {
                await onTraceEvent?(.init(kind: .info, message: "Trying \(mode.rawValue) tweet source"))
                await onProgressEvent?(.init(
                    kind: .phase,
                    phase: .fetchingTweet,
                    progress: 0.2,
                    message: "Fetching tweet"
                ))
                let status = try await apiClient.fetchStatus(tweetID: request.tweetID, mode: mode)

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
