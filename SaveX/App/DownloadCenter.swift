import Combine
import Foundation

struct DownloadLogEntry: Identifiable, Sendable {
    enum Kind: Sendable {
        case info
        case success
        case warning
        case error
    }

    let id: UUID
    let jobID: UUID?
    let createdAt: Date
    let kind: Kind
    let title: String
    let message: String
    let tweetID: String?

    init(
        id: UUID = UUID(),
        jobID: UUID? = nil,
        createdAt: Date = Date(),
        kind: Kind,
        title: String,
        message: String,
        tweetID: String? = nil
    ) {
        self.id = id
        self.jobID = jobID
        self.createdAt = createdAt
        self.kind = kind
        self.title = title
        self.message = message
        self.tweetID = tweetID
    }
}

struct DownloadBanner: Sendable {
    enum Kind: Sendable {
        case info
        case success
        case error
    }

    let text: String
    let kind: Kind
}

struct LocalLibraryItem: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let createdAt: Date
    let sourceTweetID: String
    let sourceURLString: String
    let title: String
    let formatID: String
    let fileName: String
    let fileSize: Int64
    let responseMimeType: String?

    var sourceURL: URL? {
        URL(string: sourceURLString)
    }
}

struct DownloadJobRecord: Codable, Sendable {
    let job: DownloadJob
    let preference: FormatSelectionPreference
    let updatedAt: Date

    init(
        job: DownloadJob,
        preference: FormatSelectionPreference,
        updatedAt: Date = Date()
    ) {
        self.job = job
        self.preference = preference
        self.updatedAt = updatedAt
    }
}

struct DownloadJobStore {
    private let fileManager: FileManager
    private let recordsURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.recordsURL = Self.recordsURL(fileManager: fileManager)
    }

    func load() -> [DownloadJobRecord] {
        guard let data = try? Data(contentsOf: recordsURL),
              let records = try? JSONDecoder.saveXLibraryDecoder.decode([DownloadJobRecord].self, from: data) else {
            return []
        }
        return records.sorted { $0.updatedAt > $1.updatedAt }
    }

    func upsert(_ record: DownloadJobRecord) {
        var records = load()
        records.removeAll { $0.job.id == record.job.id }
        records.insert(record, at: 0)
        save(records)
    }

    func remove(jobID: UUID) {
        var records = load()
        records.removeAll { $0.job.id == jobID }
        save(records)
    }

    private func save(_ records: [DownloadJobRecord]) {
        do {
            try fileManager.createDirectory(at: recordsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.saveXLibraryEncoder.encode(records)
            try data.write(to: recordsURL, options: .atomic)
        } catch {
            assertionFailure("Failed to persist download jobs: \(error.localizedDescription)")
        }
    }

    private static func recordsURL(fileManager: FileManager) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("SaveX", isDirectory: true)
            .appendingPathComponent("jobs.json", isDirectory: false)
    }
}

@MainActor
final class DownloadCenter: ObservableObject {
    @Published private(set) var jobs: [DownloadJob]
    @Published private(set) var banner: DownloadBanner
    @Published private(set) var logs: [DownloadLogEntry]
    @Published private(set) var libraryItems: [LocalLibraryItem]

    private let container: AppContainer
    private let fileManager: FileManager
    private let jobStore: DownloadJobStore
    private let shouldPersistJobs: Bool
    private var jobPreferences: [UUID: FormatSelectionPreference]
    private var downloadTasks: [UUID: Task<Void, Never>] = [:]
    private var lastProgressPersistenceAt: [UUID: Date] = [:]
    private static let progressPersistenceInterval: TimeInterval = 10

    init(
        container: AppContainer,
        jobs: [DownloadJob] = [],
        banner: DownloadBanner = DownloadBanner(text: "Local kernel ready", kind: .info),
        logs: [DownloadLogEntry] = [],
        libraryItems: [LocalLibraryItem] = [],
        loadPersistedLibrary: Bool = true,
        loadPersistedJobs: Bool = true,
        fileManager: FileManager = .default
    ) {
        let jobStore = DownloadJobStore(fileManager: fileManager)
        let restoredRecords = loadPersistedJobs ? jobStore.load() : []
        let restoredJobs = restoredRecords.map { Self.restoredJob(from: $0.job) }

        self.container = container
        self.jobs = jobs.isEmpty && loadPersistedJobs ? restoredJobs : jobs
        self.banner = banner
        self.logs = logs
        self.fileManager = fileManager
        self.jobStore = jobStore
        self.shouldPersistJobs = loadPersistedJobs
        self.jobPreferences = Dictionary(uniqueKeysWithValues: restoredRecords.map { ($0.job.id, $0.preference) })
        self.libraryItems = loadPersistedLibrary
            ? Self.loadLibraryItems(fileManager: fileManager)
            : libraryItems

        BackgroundHTTPDownloadCoordinator.shared.setDetachedCompletionHandler { [weak self] jobID, asset in
            Task {
                await self?.handleDetachedBackgroundCompletion(jobID: jobID, asset: asset)
            }
        }
    }

    var activeCount: Int {
        jobs.filter { !$0.phase.isTerminal }.count
    }

    var completedCount: Int {
        libraryItems.count
    }

    var savedBytes: Int64 {
        libraryItems.reduce(into: Int64.zero) { partialResult, item in
            partialResult += item.fileSize
        }
    }

    var hasJobs: Bool {
        !jobs.isEmpty
    }

    func prepareCapabilities() async {
        await consumeDetachedBackgroundCompletions()
        await observeRestoredBackgroundTasks()
        await restartInterruptedBackgroundFailures()

        let networkResult = await container.networkPermissionRequester.requestAccess()
        banner = DownloadBanner(
            text: networkResult.isReady ? "Network access ready" : "Allow network access to download videos",
            kind: networkResult.isReady ? .info : .error
        )
        appendLog(
            kind: networkResult.isReady ? .success : .warning,
            title: "Network capability",
            message: networkResult.message,
            tweetID: nil
        )

        let isAllowed = await container.photoLibraryWriter.requestAddOnlyAccess()
        banner = DownloadBanner(
            text: isAllowed ? "Photos access ready" : "Allow Photos access to save videos to your album",
            kind: isAllowed ? .info : .error
        )
        appendLog(
            kind: isAllowed ? .success : .warning,
            title: "Photos capability",
            message: isAllowed ? "Add-only Photos access is ready" : "Photos access was not granted",
            tweetID: nil
        )
    }

    private func observeRestoredBackgroundTasks() async {
        let restoredJobIDs = Set(jobs.filter { $0.phase == .waitingForSystem }.map(\.id))
        let attachedJobIDs = await BackgroundHTTPDownloadCoordinator.shared.observeRestoredTasks(jobIDs: restoredJobIDs) { [weak self] jobID, event in
            await self?.applyProgressEvent(jobID: jobID, event: event)
        }

        for jobID in restoredJobIDs.subtracting(attachedJobIDs) {
            guard let job = jobs.first(where: { $0.id == jobID }) else {
                continue
            }
            await BackgroundHTTPDownloadCoordinator.shared.cancel(jobID: jobID)
            restartJobAfterCleanup(
                job,
                progressMessage: "Restarting after app interruption",
                logKind: .warning,
                logTitle: "Background task restarted",
                logMessage: "iOS no longer has the previous background download task, so SaveX is starting it again."
            )
            appendLog(
                kind: .warning,
                title: "Background task missing",
                message: "The previous background download task was not registered with iOS on launch.",
                jobID: jobID,
                tweetID: job.request.tweetID
            )
        }
    }

    private func restartInterruptedBackgroundFailures() async {
        let interruptedJobs = jobs.filter(Self.isInterruptedBackgroundFailure)
        for job in interruptedJobs {
            await BackgroundHTTPDownloadCoordinator.shared.cancel(jobID: job.id)
            restartJobAfterCleanup(
                job,
                progressMessage: "Restarting interrupted download",
                logKind: .warning,
                logTitle: "Interrupted job restarted",
                logMessage: "A previous launch marked this job failed because the iOS background task was missing, so SaveX is starting it again."
            )
        }
    }

    private func consumeDetachedBackgroundCompletions() async {
        let completions = BackgroundHTTPDownloadCoordinator.shared.pendingDetachedCompletions()
        for (jobID, asset) in completions {
            await handleDetachedBackgroundCompletion(jobID: jobID, asset: asset)
        }
    }

    private func handleDetachedBackgroundCompletion(jobID: UUID, asset: DownloadedAsset) async {
        guard let job = jobs.first(where: { $0.id == jobID }) else {
            let didRecord = recordRecoveredLibraryItem(asset: asset)
            let didDiscard = didRecord ? false : discardRecoveredAsset(asset)
            banner = DownloadBanner(
                text: didRecord
                    ? "Recovered background download \(asset.localFileURL.lastPathComponent)"
                    : didDiscard
                        ? "Background download recovery failed; discarded \(asset.localFileURL.lastPathComponent)"
                        : "Background download recovery failed, and cleanup failed",
                kind: didRecord ? .success : .error
            )
            appendLog(
                kind: didRecord ? .warning : .error,
                title: didRecord
                    ? "Recovered orphan download"
                    : didDiscard
                        ? "Discarded orphan download"
                        : "Orphan cleanup failed",
                message: asset.localFileURL.lastPathComponent,
                jobID: jobID,
                tweetID: asset.sourceTweetID
            )
            BackgroundHTTPDownloadCoordinator.shared.acknowledgeDetachedCompletion(jobID: jobID)
            return
        }

        guard recordLibraryItem(asset: asset, request: job.request) else {
            updateJob(id: jobID) { job in
                applyDownloadedAsset(asset, to: &job)
                job.phase = .ready
                job.progress = 1
                job.errorMessage = "Library save failed"
                job.progressMessage = "Downloaded, but Library save failed"
            }
            banner = DownloadBanner(
                text: "Downloaded \(asset.localFileURL.lastPathComponent), but Library save failed",
                kind: .error
            )
            appendLog(
                kind: .warning,
                title: "Background Library save failed",
                message: asset.localFileURL.lastPathComponent,
                jobID: jobID,
                tweetID: job.request.tweetID
            )
            return
        }

        updateJob(id: jobID) { job in
            job.phase = .completed
            job.progress = 1
            job.displayTitle = asset.localFileURL.deletingPathExtension().lastPathComponent
            job.selectedFormatID = asset.format.formatID
            job.outputFilename = asset.localFileURL.lastPathComponent
            job.localFileURL = asset.localFileURL
            job.savedFileSize = asset.fileSize
            job.downloadedBytes = asset.fileSize
            job.totalBytes = asset.fileSize
            job.speedBytesPerSecond = nil
            job.etaSeconds = nil
            job.progressMessage = nil
            job.errorMessage = nil
        }

        do {
            try await container.photoLibraryWriter.saveVideoToLibrary(at: asset.localFileURL)
            banner = DownloadBanner(text: "Saved \(asset.localFileURL.lastPathComponent) to Photos", kind: .success)
            appendLog(kind: .success, title: "Background download saved", message: asset.localFileURL.lastPathComponent, jobID: jobID, tweetID: job.request.tweetID)
        } catch {
            banner = DownloadBanner(
                text: "Downloaded \(asset.localFileURL.lastPathComponent), but Photos save failed: \(error.localizedDescription)",
                kind: .error
            )
            appendLog(kind: .warning, title: "Background Photos save failed", message: error.localizedDescription, jobID: jobID, tweetID: job.request.tweetID)
        }

        BackgroundHTTPDownloadCoordinator.shared.acknowledgeDetachedCompletion(jobID: jobID)
    }

    func retryJob(_ job: DownloadJob) {
        let preference = jobPreferences[job.id] ?? .ytDLPCompatible
        jobPreferences[job.id] = preference
        lastProgressPersistenceAt.removeValue(forKey: job.id)
        downloadTasks[job.id]?.cancel()
        downloadTasks.removeValue(forKey: job.id)

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await BackgroundHTTPDownloadCoordinator.shared.cancel(jobID: job.id)
            self.restartJobAfterCleanup(
                job,
                progressMessage: "Queued retry",
                logKind: .info,
                logTitle: "Retry queued",
                logMessage: "Retrying \(preference.logLabel) route."
            )
        }
    }

    func pauseJob(_ job: DownloadJob) {
        guard !job.phase.isTerminal, job.phase != .paused else {
            return
        }

        updateJob(id: job.id) { storedJob in
            storedJob.progressMessage = "Pausing"
            storedJob.speedBytesPerSecond = nil
            storedJob.etaSeconds = nil
        }
        appendLog(kind: .info, title: "Pause requested", message: "Requesting a resumable pause.", jobID: job.id, tweetID: job.request.tweetID)

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let didPauseBackgroundTask = await BackgroundHTTPDownloadCoordinator.shared.pause(jobID: job.id)
            if didPauseBackgroundTask {
                self.markJobPausedIfStillActive(jobID: job.id, request: job.request)
                return
            }
            self.downloadTasks[job.id]?.cancel()
        }
    }

    func resumeJob(_ job: DownloadJob) {
        guard job.phase == .paused else {
            return
        }
        let preference = jobPreferences[job.id] ?? .ytDLPCompatible
        jobPreferences[job.id] = preference
        updateJob(id: job.id) { storedJob in
            storedJob.phase = .queued
            storedJob.progressMessage = "Resuming"
            storedJob.errorMessage = nil
            storedJob.speedBytesPerSecond = nil
            storedJob.etaSeconds = nil
        }
        appendLog(kind: .info, title: "Resume queued", message: "Continuing \(preference.logLabel) route.", jobID: job.id, tweetID: job.request.tweetID)
        startDownloadTask(jobID: job.id, request: job.request, preference: preference)
    }

    private func restartJobAfterCleanup(
        _ job: DownloadJob,
        progressMessage: String,
        logKind: DownloadLogEntry.Kind,
        logTitle: String,
        logMessage: String
    ) {
        guard jobs.contains(where: { $0.id == job.id }) else {
            return
        }

        let preference = jobPreferences[job.id] ?? .ytDLPCompatible
        jobPreferences[job.id] = preference

        updateJob(id: job.id) { storedJob in
            storedJob.phase = .queued
            storedJob.progress = 0.08
            storedJob.displayTitle = "Tweet \(storedJob.request.tweetID)"
            storedJob.selectedFormatID = nil
            storedJob.outputFilename = nil
            storedJob.localFileURL = nil
            storedJob.savedFileSize = nil
            storedJob.errorMessage = nil
            storedJob.downloadedBytes = nil
            storedJob.totalBytes = nil
            storedJob.speedBytesPerSecond = nil
            storedJob.etaSeconds = nil
            storedJob.completedSegmentCount = nil
            storedJob.totalSegmentCount = nil
            storedJob.progressMessage = progressMessage
        }
        appendLog(
            kind: logKind,
            title: logTitle,
            message: logMessage,
            jobID: job.id,
            tweetID: job.request.tweetID
        )

        startDownloadTask(jobID: job.id, request: job.request, preference: preference)
    }

    private func isPausedJob(id: UUID) -> Bool {
        jobs.first(where: { $0.id == id })?.phase == .paused
    }

    private func markJobPausedIfStillActive(jobID: UUID, request: TweetRequest) {
        guard let job = jobs.first(where: { $0.id == jobID }),
              !job.phase.isTerminal,
              job.phase != .paused else {
            return
        }
        updateJob(id: jobID) { job in
            job.phase = .paused
            job.progressMessage = "Paused"
            job.speedBytesPerSecond = nil
            job.etaSeconds = nil
        }
        appendLog(kind: .info, title: "Paused", message: "Download can be continued later.", jobID: jobID, tweetID: request.tweetID)
    }

    func deleteJob(_ job: DownloadJob) {
        downloadTasks[job.id]?.cancel()
        downloadTasks.removeValue(forKey: job.id)
        jobs.removeAll { $0.id == job.id }
        jobPreferences.removeValue(forKey: job.id)
        lastProgressPersistenceAt.removeValue(forKey: job.id)
        if shouldPersistJobs {
            jobStore.remove(jobID: job.id)
        }
        appendLog(kind: .info, title: "Deleted job", message: "Removed job from Jobs.", jobID: job.id, tweetID: job.request.tweetID)

        Task {
            await BackgroundHTTPDownloadCoordinator.shared.cancel(jobID: job.id)
        }
    }

    @discardableResult
    func enqueue(rawURL: String, preference: FormatSelectionPreference) -> Bool {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            banner = DownloadBanner(text: "Paste a tweet URL first", kind: .error)
            appendLog(kind: .warning, title: "Queue rejected", message: "No URL was provided", tweetID: nil)
            return false
        }

        do {
            let request = try container.urlParser.parse(trimmed)
            let job = DownloadJob(
                request: request,
                phase: .queued,
                progress: 0.08,
                displayTitle: "Tweet \(request.tweetID)"
            )
            jobs.insert(job, at: 0)
            jobPreferences[job.id] = preference
            persistJob(job)
            banner = DownloadBanner(text: "Queued tweet \(request.tweetID)", kind: .info)
            appendLog(
                kind: .info,
                title: "Queued",
                message: "Preference: \(preference.logLabel). URL parsed successfully.",
                jobID: job.id,
                tweetID: request.tweetID
            )

            startDownloadTask(jobID: job.id, request: request, preference: preference)
            return true
        } catch {
            banner = DownloadBanner(text: error.localizedDescription, kind: .error)
            appendLog(kind: .error, title: "URL parse failed", message: error.localizedDescription, tweetID: nil)
            return false
        }
    }

    private func startDownloadTask(
        jobID: UUID,
        request: TweetRequest,
        preference: FormatSelectionPreference
    ) {
        downloadTasks[jobID]?.cancel()
        downloadTasks[jobID] = Task { @MainActor [weak self] in
            await self?.runDownload(jobID: jobID, request: request, preference: preference)
        }
    }

    private func runDownload(
        jobID: UUID,
        request: TweetRequest,
        preference: FormatSelectionPreference
    ) async {
        updateJob(id: jobID) { job in
            job.phase = .validatingURL
            job.progress = 0.12
        }
        appendLog(kind: .info, title: "Started", message: "Beginning tweet resolution", jobID: jobID, tweetID: request.tweetID)

        do {
            let asset = try await container.downloadEngine.download(
                jobID: jobID,
                request: request,
                preference: preference,
                destinationDirectory: downloadsDirectory
            ) { [weak self] event in
                await self?.applyProgressEvent(
                    jobID: jobID,
                    event: event
                )
            } onTraceEvent: { [weak self] event in
                await self?.appendLog(
                    kind: DownloadLogEntry.Kind(event.kind),
                    title: event.kind.title,
                    message: event.message,
                    jobID: jobID,
                    tweetID: request.tweetID
                )
            }
            guard jobs.contains(where: { $0.id == jobID }) else {
                return
            }

            guard recordLibraryItem(asset: asset, request: request) else {
                updateJob(id: jobID) { job in
                    applyDownloadedAsset(asset, to: &job)
                    job.phase = .ready
                    job.progress = 1
                    job.errorMessage = "Library save failed"
                    job.progressMessage = "Downloaded, but Library save failed"
                }
                banner = DownloadBanner(
                    text: "Downloaded \(asset.localFileURL.lastPathComponent), but Library save failed",
                    kind: .error
                )
                appendLog(
                    kind: .warning,
                    title: "Library save failed",
                    message: asset.localFileURL.lastPathComponent,
                    jobID: jobID,
                    tweetID: request.tweetID
                )
                downloadTasks.removeValue(forKey: jobID)
                return
            }

            updateJob(id: jobID) { job in
                applyDownloadedAsset(asset, to: &job)
                job.phase = .completed
                job.progress = 1
                if job.totalSegmentCount != nil {
                    job.completedSegmentCount = job.totalSegmentCount
                }
                job.progressMessage = nil
                job.errorMessage = nil
            }
            applyProgressEvent(
                jobID: jobID,
                event: DownloadProgressEvent(
                    kind: .photoSave,
                    phase: .savingToPhotos,
                    progress: 0.98,
                    formatID: asset.format.formatID,
                    downloadedBytes: asset.fileSize,
                    totalBytes: asset.fileSize,
                    message: "Saving to Photos"
                )
            )
            do {
                try await container.photoLibraryWriter.saveVideoToLibrary(at: asset.localFileURL)
                updateJob(id: jobID) { job in
                    job.phase = .completed
                    job.progress = 1
                    job.progressMessage = nil
                }
                banner = DownloadBanner(text: "Saved \(asset.localFileURL.lastPathComponent) to Photos", kind: .success)
                appendLog(kind: .success, title: "Saved to Photos", message: asset.localFileURL.lastPathComponent, jobID: jobID, tweetID: request.tweetID)
            } catch {
                updateJob(id: jobID) { job in
                    job.phase = .completed
                    job.progress = 1
                    job.progressMessage = nil
                }
                banner = DownloadBanner(
                    text: "Downloaded \(asset.localFileURL.lastPathComponent), but Photos save failed: \(error.localizedDescription)",
                    kind: .error
                )
                appendLog(kind: .warning, title: "Photos save failed", message: error.localizedDescription, jobID: jobID, tweetID: request.tweetID)
            }
            downloadTasks.removeValue(forKey: jobID)
        } catch {
            guard jobs.contains(where: { $0.id == jobID }) else {
                downloadTasks.removeValue(forKey: jobID)
                return
            }
            if Self.isPauseError(error) || isPausedJob(id: jobID) {
                downloadTasks.removeValue(forKey: jobID)
                markJobPausedIfStillActive(jobID: jobID, request: request)
                return
            }
            downloadTasks.removeValue(forKey: jobID)
            updateJob(id: jobID) { job in
                job.phase = .failed
                job.progress = min(job.progress, 0.96)
                job.errorMessage = error.localizedDescription
            }
            banner = DownloadBanner(text: error.localizedDescription, kind: .error)
            appendLog(kind: .error, title: "Failed", message: error.localizedDescription, jobID: jobID, tweetID: request.tweetID)
        }
    }

    private func applyProgressEvent(
        jobID: UUID,
        event: DownloadProgressEvent
    ) {
        updateJob(id: jobID, persist: shouldPersistProgressEvent(jobID: jobID, event: event)) { job in
            job.phase = event.phase
            job.progress = event.progress
            if let formatID = event.formatID {
                job.selectedFormatID = formatID
            }
            if let downloadedBytes = event.downloadedBytes {
                job.downloadedBytes = downloadedBytes
            }
            if let totalBytes = event.totalBytes {
                job.totalBytes = totalBytes
            }
            job.speedBytesPerSecond = event.speedBytesPerSecond
            job.etaSeconds = event.etaSeconds
            if let completedSegmentCount = event.completedSegmentCount {
                job.completedSegmentCount = completedSegmentCount
            }
            if let totalSegmentCount = event.totalSegmentCount {
                job.totalSegmentCount = totalSegmentCount
            }
            job.progressMessage = event.message
        }
    }

    private func updateJob(
        id: UUID,
        persist: Bool = true,
        mutate: (inout DownloadJob) -> Void
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutate(&jobs[index])
        if persist {
            persistJob(jobs[index])
        }
    }

    private func applyDownloadedAsset(_ asset: DownloadedAsset, to job: inout DownloadJob) {
        job.displayTitle = asset.localFileURL.deletingPathExtension().lastPathComponent
        job.selectedFormatID = asset.format.formatID
        job.outputFilename = asset.localFileURL.lastPathComponent
        job.localFileURL = asset.localFileURL
        job.savedFileSize = asset.fileSize
        job.downloadedBytes = asset.fileSize
        job.totalBytes = asset.fileSize
        job.speedBytesPerSecond = nil
        job.etaSeconds = nil
    }

    private func persistJob(_ job: DownloadJob) {
        guard shouldPersistJobs else {
            return
        }
        if job.phase == .completed {
            jobStore.remove(jobID: job.id)
            jobPreferences.removeValue(forKey: job.id)
            lastProgressPersistenceAt.removeValue(forKey: job.id)
            return
        }
        guard let preference = jobPreferences[job.id] else {
            return
        }
        jobStore.upsert(DownloadJobRecord(job: job, preference: preference))
    }

    private func shouldPersistProgressEvent(
        jobID: UUID,
        event: DownloadProgressEvent
    ) -> Bool {
        switch event.kind {
        case .phase, .export, .photoSave:
            lastProgressPersistenceAt[jobID] = Date()
            return true
        case .fileTransfer, .hlsSegment:
            if event.phase == .waitingForSystem {
                lastProgressPersistenceAt[jobID] = Date()
                return true
            }
            let now = Date()
            guard let last = lastProgressPersistenceAt[jobID],
                  now.timeIntervalSince(last) < Self.progressPersistenceInterval else {
                lastProgressPersistenceAt[jobID] = now
                return true
            }
            return false
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    func fileURL(for item: LocalLibraryItem) -> URL {
        downloadsDirectory.appendingPathComponent(item.fileName, isDirectory: false)
    }

    func deleteLibraryItem(_ item: LocalLibraryItem) {
        let url = fileURL(for: item)
        do {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            libraryItems.removeAll { $0.id == item.id }
            _ = persistLibraryItems()
            banner = DownloadBanner(text: "Deleted \(item.fileName)", kind: .info)
            appendLog(kind: .info, title: "Deleted local file", message: item.fileName, tweetID: item.sourceTweetID)
        } catch {
            banner = DownloadBanner(text: "Delete failed: \(error.localizedDescription)", kind: .error)
            appendLog(kind: .error, title: "Delete failed", message: error.localizedDescription, tweetID: item.sourceTweetID)
        }
    }

    func reloadLibrary() {
        libraryItems = Self.loadLibraryItems(fileManager: fileManager)
    }

    private func appendLog(
        kind: DownloadLogEntry.Kind,
        title: String,
        message: String,
        jobID: UUID? = nil,
        tweetID: String?
    ) {
        logs.insert(
            DownloadLogEntry(
                jobID: jobID,
                kind: kind,
                title: title,
                message: message,
                tweetID: tweetID
            ),
            at: 0
        )
        if logs.count > 300 {
            logs.removeLast(logs.count - 300)
        }
    }

    @discardableResult
    private func recordLibraryItem(asset: DownloadedAsset, request: TweetRequest) -> Bool {
        recordLibraryItem(LocalLibraryItem(
            id: UUID(),
            createdAt: Date(),
            sourceTweetID: request.tweetID,
            sourceURLString: request.sourceURL.absoluteString,
            title: asset.localFileURL.deletingPathExtension().lastPathComponent,
            formatID: asset.format.formatID,
            fileName: asset.localFileURL.lastPathComponent,
            fileSize: asset.fileSize,
            responseMimeType: asset.responseMimeType
        ))
    }

    @discardableResult
    private func recordRecoveredLibraryItem(asset: DownloadedAsset) -> Bool {
        recordLibraryItem(LocalLibraryItem(
            id: UUID(),
            createdAt: Date(),
            sourceTweetID: asset.sourceTweetID,
            sourceURLString: "",
            title: asset.localFileURL.deletingPathExtension().lastPathComponent,
            formatID: asset.format.formatID,
            fileName: asset.localFileURL.lastPathComponent,
            fileSize: asset.fileSize,
            responseMimeType: asset.responseMimeType
        ))
    }

    @discardableResult
    private func discardRecoveredAsset(_ asset: DownloadedAsset) -> Bool {
        do {
            if fileManager.fileExists(atPath: asset.localFileURL.path) {
                try fileManager.removeItem(at: asset.localFileURL)
            }
            return true
        } catch {
            appendLog(kind: .warning, title: "File cleanup failed", message: error.localizedDescription, tweetID: asset.sourceTweetID)
            return false
        }
    }

    @discardableResult
    private func recordLibraryItem(_ item: LocalLibraryItem) -> Bool {
        var updatedItems = libraryItems
        updatedItems.removeAll { $0.fileName == item.fileName }
        updatedItems.insert(item, at: 0)
        guard persistLibraryItems(updatedItems) else {
            return false
        }
        libraryItems = updatedItems
        return true
    }

    @discardableResult
    private func persistLibraryItems() -> Bool {
        persistLibraryItems(libraryItems)
    }

    @discardableResult
    private func persistLibraryItems(_ items: [LocalLibraryItem]) -> Bool {
        do {
            try fileManager.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder.saveXLibraryEncoder.encode(items)
            try data.write(to: libraryManifestURL, options: .atomic)
            return true
        } catch {
            appendLog(kind: .warning, title: "Library save failed", message: error.localizedDescription, tweetID: nil)
            return false
        }
    }

    private static func loadLibraryItems(fileManager: FileManager) -> [LocalLibraryItem] {
        let manifestURL = libraryManifestURL(fileManager: fileManager)
        guard let data = try? Data(contentsOf: manifestURL),
              let items = try? JSONDecoder.saveXLibraryDecoder.decode([LocalLibraryItem].self, from: data) else {
            return []
        }

        let downloads = downloadsDirectory(fileManager: fileManager)
        return items.filter { item in
            fileManager.fileExists(atPath: downloads.appendingPathComponent(item.fileName).path)
        }
    }

    private static func restoredJob(from storedJob: DownloadJob) -> DownloadJob {
        var job = storedJob
        guard !job.phase.isTerminal else {
            return job
        }
        if job.phase == .paused {
            job.progressMessage = "Paused"
            job.speedBytesPerSecond = nil
            job.etaSeconds = nil
            return job
        }
        job.phase = .waitingForSystem
        job.progressMessage = "Waiting for background session"
        job.speedBytesPerSecond = nil
        job.etaSeconds = nil
        return job
    }

    private static func isPauseError(_ error: Error) -> Bool {
        if case SaveXError.downloadPaused = error {
            return true
        }
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private static func isInterruptedBackgroundFailure(_ job: DownloadJob) -> Bool {
        guard job.phase == .failed,
              let errorMessage = job.errorMessage?.lowercased() else {
            return false
        }
        return errorMessage.contains("background download is no longer registered")
            || errorMessage.contains("background download task was missing")
    }

    private var downloadsDirectory: URL {
        Self.downloadsDirectory(fileManager: fileManager)
    }

    private var libraryDirectory: URL {
        Self.libraryDirectory(fileManager: fileManager)
    }

    private var libraryManifestURL: URL {
        Self.libraryManifestURL(fileManager: fileManager)
    }

    private static func downloadsDirectory(fileManager: FileManager) -> URL {
        documentsDirectory(fileManager: fileManager)
            .appendingPathComponent("SaveX", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    private static func libraryDirectory(fileManager: FileManager) -> URL {
        documentsDirectory(fileManager: fileManager)
            .appendingPathComponent("SaveX", isDirectory: true)
    }

    private static func documentsDirectory(fileManager: FileManager) -> URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return documents
    }

    private static func libraryManifestURL(fileManager: FileManager) -> URL {
        libraryDirectory(fileManager: fileManager)
            .appendingPathComponent("library.json", isDirectory: false)
    }
}

private extension DownloadTraceEvent.Kind {
    var title: String {
        switch self {
        case .info:
            return "Trace"
        case .success:
            return "Trace OK"
        case .warning:
            return "Fallback"
        case .error:
            return "Trace Error"
        }
    }
}

private extension DownloadLogEntry.Kind {
    init(_ traceKind: DownloadTraceEvent.Kind) {
        switch traceKind {
        case .info:
            self = .info
        case .success:
            self = .success
        case .warning:
            self = .warning
        case .error:
            self = .error
        }
    }
}

private extension FormatSelectionPreference {
    var logLabel: String {
        switch self {
        case .ytDLPCompatible:
            return "Best"
        case .preferMP4Direct:
            return "MP4"
        case .preferHLS:
            return "HLS"
        case let .exactFormatID(id):
            return id
        }
    }
}

extension DownloadCenter {
    static var preview: DownloadCenter {
        let jobs = [
            DownloadJob(
                request: TweetRequest(
                    sourceURL: URL(string: "https://x.com/example/status/181234567890")!,
                    tweetID: "181234567890",
                    screenName: "example",
                    selectedMediaIndex: nil
                ),
                phase: .fetchingTweet,
                progress: 0.28,
                displayTitle: "Tweet 181234567890"
            ),
            DownloadJob(
                request: TweetRequest(
                    sourceURL: URL(string: "https://x.com/demo/status/181234567891/video/1")!,
                    tweetID: "181234567891",
                    screenName: "demo",
                    selectedMediaIndex: 1
                ),
                phase: .downloading,
                progress: 0.84,
                displayTitle: "Tweet 181234567891",
                selectedFormatID: "http-2176000"
            ),
            DownloadJob(
                request: TweetRequest(
                    sourceURL: URL(string: "https://x.com/oshtru/status/1577855540407197696")!,
                    tweetID: "1577855540407197696",
                    screenName: "oshtru",
                    selectedMediaIndex: nil
                ),
                phase: .completed,
                progress: 1,
                displayTitle: "Oshtru-now-I-can-post-image-and-video-nice-update-3",
                selectedFormatID: "http-2176000",
                outputFilename: "Oshtru-now-I-can-post-image-and-video-nice-update-3.mp4",
                localFileURL: URL(fileURLWithPath: "/tmp/SaveXDownloads/Oshtru-now-I-can-post-image-and-video-nice-update-3.mp4"),
                savedFileSize: 1_787_622
            ),
        ]

        return DownloadCenter(
            container: AppContainer(),
            jobs: jobs,
            banner: DownloadBanner(text: "Saved Oshtru-now-I-can-post-image-and-video-nice-update-3.mp4", kind: .success),
            logs: [
                DownloadLogEntry(
                    kind: .info,
                    title: "Trace",
                    message: "Trying graphql tweet source",
                    tweetID: "1577855540407197696"
                ),
                DownloadLogEntry(
                    kind: .warning,
                    title: "Fallback",
                    message: "graphql failed: Twitter API error (404). Trying fallback.",
                    tweetID: "1577855540407197696"
                ),
                DownloadLogEntry(
                    kind: .success,
                    title: "Trace OK",
                    message: "syndication returned tweet payload",
                    tweetID: "1577855540407197696"
                ),
            ],
            libraryItems: [
                LocalLibraryItem(
                    id: UUID(),
                    createdAt: Date(),
                    sourceTweetID: "1577855540407197696",
                    sourceURLString: "https://twitter.com/oshtru/status/1577855540407197696",
                    title: "Oshtru-now-I-can-post-image-and-video-nice-update-3",
                    formatID: "http-2176000",
                    fileName: "Oshtru-now-I-can-post-image-and-video-nice-update-3.mp4",
                    fileSize: 1_787_622,
                    responseMimeType: "video/mp4"
                ),
            ],
            loadPersistedLibrary: false,
            loadPersistedJobs: false
        )
    }
}

private extension JSONEncoder {
    static var saveXLibraryEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var saveXLibraryDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
