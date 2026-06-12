import SwiftUI

struct JobsView: View {
    @ObservedObject var downloadCenter: DownloadCenter

    var body: some View {
        NavigationStack {
            ZStack {
                SaveXBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header

                        if downloadCenter.jobs.isEmpty {
                            emptyState
                        } else {
                            ForEach(downloadCenter.jobs) { job in
                                JobRow(
                                    job: job,
                                    pause: { downloadCenter.pauseJob(job) },
                                    resume: { downloadCenter.resumeJob(job) },
                                    retry: { downloadCenter.retryJob(job) },
                                    delete: { downloadCenter.deleteJob(job) }
                                )
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .toolbarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        Text("Jobs")
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .padding(.top, 12)
    }

    private var emptyState: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text("No jobs yet")
                    .font(.headline)

                Text("Queue a public X/Twitter post from Home and the local Swift kernel will show live phases here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct JobRow: View {
    let job: DownloadJob
    let pause: () -> Void
    let resume: () -> Void
    let retry: () -> Void
    let delete: () -> Void

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(titleText)
                            .font(.headline)
                            .lineLimit(2)

                        Text(job.request.sourceURL.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    StatusPill(statusText, systemImage: statusSymbol)
                }

                ProgressView(value: job.progress)
                    .tint(tintColor)

                HStack {
                    Label(formatText, systemImage: "film")
                    Spacer()
                    Text(detailText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(job.phase == .failed ? .red : .secondary)

                HStack(spacing: 10) {
                    if canPause {
                        Button(action: pause) {
                            Label("Pause", systemImage: "pause.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }

                    if job.phase == .paused {
                        Button(action: resume) {
                            Label("Continue", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }

                    if job.phase == .failed {
                        Button(action: retry) {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }

                    Button(role: .destructive, action: delete) {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
                .font(.caption.weight(.semibold))
            }
        }
    }

    private var titleText: String {
        job.displayTitle ?? job.outputFilename ?? "Tweet \(job.request.tweetID)"
    }

    private var canPause: Bool {
        switch job.phase {
        case .queued, .validatingURL, .fetchingGuestToken, .fetchingTweet, .normalizingTweet, .extractingMedia, .selectingFormat, .preparingDownload, .downloading, .waitingForSystem:
            return true
        default:
            return false
        }
    }

    private var statusText: String {
        switch job.phase {
        case .idle:
            return "Idle"
        case .queued:
            return "Queued"
        case .validatingURL:
            return "Validating"
        case .fetchingGuestToken:
            return "Auth"
        case .fetchingTweet:
            return "Resolving"
        case .normalizingTweet:
            return "Normalizing"
        case .extractingMedia:
            return "Extracting"
        case .selectingFormat:
            return "Selecting"
        case .preparingDownload:
            return "Planning"
        case .downloading:
            return "Downloading"
        case .waitingForSystem:
            return "Waiting"
        case .paused:
            return "Paused"
        case .exportingMedia:
            return "Exporting"
        case .savingToPhotos:
            return "Saving"
        case .ready:
            return "Ready"
        case .completed:
            return "Saved"
        case .failed:
            return "Failed"
        }
    }

    private var statusSymbol: String {
        switch job.phase {
        case .idle, .queued:
            return "clock"
        case .validatingURL, .fetchingGuestToken, .fetchingTweet, .normalizingTweet, .extractingMedia, .selectingFormat, .preparingDownload:
            return "gearshape.2"
        case .downloading:
            return "arrow.down.circle"
        case .waitingForSystem:
            return "clock.arrow.circlepath"
        case .paused:
            return "pause.circle"
        case .exportingMedia:
            return "square.and.arrow.up"
        case .savingToPhotos:
            return "photo"
        case .ready:
            return "checkmark.circle"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var tintColor: Color {
        switch job.phase {
        case .completed:
            return .green
        case .failed:
            return .red
        case .downloading:
            return .blue
        case .waitingForSystem, .paused:
            return .orange
        case .exportingMedia, .savingToPhotos:
            return .purple
        default:
            return .orange
        }
    }

    private var formatText: String {
        job.selectedFormatID ?? "Auto"
    }

    private var detailText: String {
        if let errorMessage = job.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        if let savedFileSize = job.savedFileSize {
            return ByteCountFormatter.string(fromByteCount: savedFileSize, countStyle: .file)
        }
        if let segmentText {
            return segmentText
        }
        if let transferText {
            return transferText
        }
        if let progressMessage = job.progressMessage, !progressMessage.isEmpty {
            return progressMessage
        }
        return detailForPhase
    }

    private var transferText: String? {
        guard let downloadedBytes = job.downloadedBytes else {
            return nil
        }

        var pieces: [String] = []
        if let totalBytes = job.totalBytes, totalBytes > 0 {
            pieces.append("\(byteText(downloadedBytes)) / \(byteText(totalBytes))")
        } else {
            pieces.append(byteText(downloadedBytes))
        }

        if let speedBytesPerSecond = job.speedBytesPerSecond, speedBytesPerSecond > 0 {
            pieces.append("\(byteText(Int64(speedBytesPerSecond)))/s")
        }

        if let etaSeconds = job.etaSeconds, etaSeconds.isFinite, etaSeconds > 0 {
            pieces.append("\(etaText(etaSeconds)) left")
        }

        return pieces.joined(separator: " - ")
    }

    private var segmentText: String? {
        guard let completed = job.completedSegmentCount,
              let total = job.totalSegmentCount,
              total > 0 else {
            return nil
        }
        return "\(completed) / \(total) segments"
    }

    private var detailForPhase: String {
        switch job.phase {
        case .idle:
            return "waiting"
        case .queued:
            return "queued"
        case .validatingURL:
            return "url parser"
        case .fetchingGuestToken:
            return "guest token"
        case .fetchingTweet:
            return "graphql"
        case .normalizingTweet:
            return "tweet payload"
        case .extractingMedia:
            return "media graph"
        case .selectingFormat:
            return "yt-dlp sort"
        case .preparingDownload:
            return "single file"
        case .downloading:
            return "downloading"
        case .waitingForSystem:
            return "background session"
        case .paused:
            return "paused"
        case .exportingMedia:
            return "exporting"
        case .savingToPhotos:
            return "photos"
        case .ready:
            return "ready"
        case .completed:
            return job.outputFilename ?? "saved"
        case .failed:
            return "kernel error"
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func etaText(_ seconds: TimeInterval) -> String {
        let rounded = max(Int(seconds.rounded(.up)), 1)
        if rounded < 60 {
            return "\(rounded)s"
        }
        let minutes = rounded / 60
        let remainingSeconds = rounded % 60
        if minutes < 60 {
            return remainingSeconds == 0 ? "\(minutes)m" : "\(minutes)m \(remainingSeconds)s"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }
}

#Preview("Jobs") {
    JobsView(downloadCenter: .preview)
}
