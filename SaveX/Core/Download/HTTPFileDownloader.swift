import Foundation

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

    func cancelAndClean(jobID: UUID) async {
        await backgroundCoordinator?.cancel(jobID: jobID)
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
