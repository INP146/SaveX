import Foundation

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
        let onFailure: (@Sendable (UUID, Error) async -> Void)?
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
        onProgressEvent: (@Sendable (UUID, DownloadProgressEvent) async -> Void)? = nil,
        onFailure: (@Sendable (UUID, Error) async -> Void)? = nil
    ) async -> Set<UUID> {
        guard !jobIDs.isEmpty else {
            _ = session
            return []
        }

        registerRestoredObservers(
            jobIDs: jobIDs,
            onProgressEvent: onProgressEvent,
            onFailure: onFailure
        )

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

        for metadata in metadataList {
            removeMetadata(taskIdentifier: metadata.taskIdentifier)
        }
        acknowledgeDetachedCompletion(jobID: jobID)
        removeRestoredObserver(jobID: jobID)
        _ = removePausingJobID(jobID)
        resumeStore.clear(jobID: jobID)

        for task in tasks where taskMatchesJob(task, jobID: jobID, metadataList: metadataList) {
            task.cancel()
        }
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
        onProgressEvent: (@Sendable (UUID, DownloadProgressEvent) async -> Void)?,
        onFailure: (@Sendable (UUID, Error) async -> Void)?
    ) {
        lock.lock()
        for jobID in jobIDs {
            restoredTaskObservers[jobID] = RestoredTaskObserver(
                jobID: jobID,
                onProgressEvent: { event in
                    await onProgressEvent?(jobID, event)
                },
                onFailure: onFailure,
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

    private func takeRestoredObserver(jobID: UUID) -> RestoredTaskObserver? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return restoredTaskObservers.removeValue(forKey: jobID)
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
            if let error {
                handleRestoredTaskCompletionError(error, task: task, taskIdentifier: taskIdentifier)
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

    private func handleRestoredTaskCompletionError(
        _ error: Error,
        task: URLSessionTask,
        taskIdentifier: Int
    ) {
        guard let metadata = metadata(for: task) else {
            removeMetadata(taskIdentifier: taskIdentifier)
            return
        }

        if let resumeData = Self.resumeData(from: error) {
            resumeStore.saveResumeData(
                resumeData,
                jobID: metadata.jobID,
                format: metadata.format,
                tweetID: metadata.tweetID,
                title: metadata.title,
                destinationDirectory: URL(fileURLWithPath: metadata.destinationDirectoryPath, isDirectory: true),
                totalBytes: normalizedTotalBytes(task.countOfBytesExpectedToReceive, fallback: metadata.format.fileSizeApprox)
            )
        }

        removeMetadata(taskIdentifier: metadata.taskIdentifier)

        if removePausingJobID(metadata.jobID) {
            return
        }

        guard let observer = takeRestoredObserver(jobID: metadata.jobID) else {
            return
        }

        Task {
            await observer.onFailure?(metadata.jobID, error)
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
