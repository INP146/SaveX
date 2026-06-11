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
                                JobRow(job: job)
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
                }
                .font(.caption)
                .foregroundStyle(job.phase == .failed ? .red : .secondary)
            }
        }
    }

    private var titleText: String {
        job.displayTitle ?? job.outputFilename ?? "Tweet \(job.request.tweetID)"
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
        return detailForPhase
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
        case .ready:
            return "ready"
        case .completed:
            return job.outputFilename ?? "saved"
        case .failed:
            return "kernel error"
        }
    }
}

#Preview("Jobs") {
    JobsView(downloadCenter: .preview)
}
