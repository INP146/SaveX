import Foundation

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

    func cancelAndClean(jobID: UUID) {
        resumeStore.clear(jobID: jobID)
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
