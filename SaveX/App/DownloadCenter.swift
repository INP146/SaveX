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

@MainActor
final class DownloadCenter: ObservableObject {
    @Published private(set) var jobs: [DownloadJob]
    @Published private(set) var banner: DownloadBanner
    @Published private(set) var logs: [DownloadLogEntry]

    private let container: AppContainer
    private let fileManager: FileManager

    init(
        container: AppContainer,
        jobs: [DownloadJob] = [],
        banner: DownloadBanner = DownloadBanner(text: "Local kernel ready", kind: .info),
        logs: [DownloadLogEntry] = [],
        fileManager: FileManager = .default
    ) {
        self.container = container
        self.jobs = jobs
        self.banner = banner
        self.logs = logs
        self.fileManager = fileManager
    }

    var activeCount: Int {
        jobs.filter { !$0.phase.isTerminal }.count
    }

    var completedCount: Int {
        jobs.filter { $0.phase == .completed }.count
    }

    var savedBytes: Int64 {
        jobs.reduce(into: Int64.zero) { partialResult, job in
            partialResult += job.savedFileSize ?? 0
        }
    }

    var hasJobs: Bool {
        !jobs.isEmpty
    }

    func prepareCapabilities() async {
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
            banner = DownloadBanner(text: "Queued tweet \(request.tweetID)", kind: .info)
            appendLog(
                kind: .info,
                title: "Queued",
                message: "Preference: \(preference.logLabel). URL parsed successfully.",
                jobID: job.id,
                tweetID: request.tweetID
            )

            Task {
                await runDownload(jobID: job.id, request: request, preference: preference)
            }
            return true
        } catch {
            banner = DownloadBanner(text: error.localizedDescription, kind: .error)
            appendLog(kind: .error, title: "URL parse failed", message: error.localizedDescription, tweetID: nil)
            return false
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
                request: request,
                preference: preference,
                destinationDirectory: downloadsDirectory
            ) { [weak self] phase, progress, formatID in
                await self?.applyProgress(
                    jobID: jobID,
                    phase: phase,
                    progress: progress,
                    formatID: formatID
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

            updateJob(id: jobID) { job in
                job.phase = .completed
                job.progress = 1
                job.displayTitle = asset.localFileURL.deletingPathExtension().lastPathComponent
                job.selectedFormatID = asset.format.formatID
                job.outputFilename = asset.localFileURL.lastPathComponent
                job.localFileURL = asset.localFileURL
                job.savedFileSize = asset.fileSize
                job.errorMessage = nil
            }
            do {
                try await container.photoLibraryWriter.saveVideoToLibrary(at: asset.localFileURL)
                banner = DownloadBanner(text: "Saved \(asset.localFileURL.lastPathComponent) to Photos", kind: .success)
                appendLog(kind: .success, title: "Saved to Photos", message: asset.localFileURL.lastPathComponent, jobID: jobID, tweetID: request.tweetID)
            } catch {
                banner = DownloadBanner(
                    text: "Downloaded \(asset.localFileURL.lastPathComponent), but Photos save failed: \(error.localizedDescription)",
                    kind: .error
                )
                appendLog(kind: .warning, title: "Photos save failed", message: error.localizedDescription, jobID: jobID, tweetID: request.tweetID)
            }
        } catch {
            updateJob(id: jobID) { job in
                job.phase = .failed
                job.progress = min(job.progress, 0.96)
                job.errorMessage = error.localizedDescription
            }
            banner = DownloadBanner(text: error.localizedDescription, kind: .error)
            appendLog(kind: .error, title: "Failed", message: error.localizedDescription, jobID: jobID, tweetID: request.tweetID)
        }
    }

    private func applyProgress(
        jobID: UUID,
        phase: DownloadJobPhase,
        progress: Double,
        formatID: String?
    ) {
        updateJob(id: jobID) { job in
            job.phase = phase
            job.progress = progress
            if let formatID {
                job.selectedFormatID = formatID
            }
        }
    }

    private func updateJob(id: UUID, mutate: (inout DownloadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutate(&jobs[index])
    }

    func clearLogs() {
        logs.removeAll()
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

    private var downloadsDirectory: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return documents
            .appendingPathComponent("SaveX", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
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
            ]
        )
    }
}
