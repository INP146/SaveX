import AVKit
import SwiftUI
import UIKit

struct HomeView: View {
    @ObservedObject var downloadCenter: DownloadCenter

    @State private var tweetURL = ""
    @AppStorage(SaveXStorageKey.defaultDownloadRoute) private var preferredQualityRaw = QualityPreset.best
        .rawValue
    @AppStorage(SaveXStorageKey.downloadsAllTweetVideosByDefault) private var downloadsAllTweetVideosByDefault = false

    var body: some View {
        NavigationStack {
            ZStack {
                SaveXBackground()

                GeometryReader { proxy in
                    VStack(spacing: 32) {
                        header
                        inputPanel
                    }
                    .padding(.horizontal, 20)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
                    .offset(y: -proxy.size.height * 0.02)
                }
            }
            .saveXNavigationChrome()
            .sheet(item: $downloadCenter.pendingTwitterMediaSelection) { selection in
                TwitterMediaSelectionView(
                    selection: selection,
                    onSelect: { candidate in
                        downloadCenter.confirmTwitterMediaSelection(candidate: candidate)
                    },
                    onQueueAll: {
                        downloadCenter.confirmAllTwitterMediaSelection()
                    },
                    onCancel: {
                        downloadCenter.cancelTwitterMediaSelection()
                    }
                )
            }
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            Text("Save𝕏")
                .font(.system(size: 42, weight: .regular))
        }
        .frame(maxWidth: .infinity)
    }

    private var preferredQuality: QualityPreset {
        QualityPreset(rawValue: preferredQualityRaw) ?? .best
    }

    private var inputPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 16) {

                TextField("Type post URL here", text: $tweetURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .padding(14)
                    .background(
                        .thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                HStack(spacing: 12) {
                    Button {
                        if let clipboard = UIPasteboard.general.string?
                            .trimmingCharacters(in: .whitespacesAndNewlines), !clipboard.isEmpty
                        {
                            tweetURL = clipboard
                        }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                            .saveXGlassLabel()
                    }
                    .buttonStyle(.glass)

                    Button {
                        let didStartQueue = downloadCenter.enqueue(
                            rawURL: tweetURL,
                            preference: preferredQuality.selectionPreference
                        )
                        if didStartQueue {
                            tweetURL = ""
                        }
                    } label: {
                        if downloadCenter.isResolvingMediaSelection {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Checking")
                            }
                            .saveXGlassLabel(expands: true)
                        } else {
                            Label(
                                downloadsAllTweetVideosByDefault ? "Queue" : "Resolve",
                                systemImage: downloadsAllTweetVideosByDefault ? "arrow.down.circle.fill" : "magnifyingglass"
                            )
                            .saveXGlassLabel(expands: true)
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(
                        tweetURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || downloadCenter.isResolvingMediaSelection
                    )
                }

            }
        }
    }
}

private struct TwitterMediaSelectionView: View {
    let selection: TwitterMediaSelection
    let onSelect: (ResolvedDownload) -> Void
    let onQueueAll: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                SaveXBackground()

                StablePageScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Choose a video")
                                .font(.headline)
                            Text("This tweet has multiple videos. Pick one to queue, or queue them all.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)

                        ForEach(selection.candidates) { candidate in
                            TwitterVideoPreviewCard(
                                candidate: candidate,
                                title: videoTitle(for: candidate),
                                subtitle: videoSubtitle(for: candidate),
                                onQueue: {
                                    onSelect(candidate)
                                }
                            )
                        }

                        Button {
                            onQueueAll()
                        } label: {
                            Label("Queue All", systemImage: "square.stack.3d.down.right.fill")
                                .saveXGlassLabel(expands: true)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                }
            }
            .saveXNavigationChrome()
            .navigationTitle("Tweet Videos")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
            }
        }
    }

    private func videoTitle(for candidate: ResolvedDownload) -> String {
        if let sourceMediaIndex = candidate.entry.sourceMediaIndex {
            return "Video \(sourceMediaIndex)"
        }
        return candidate.entry.title
    }

    private func videoSubtitle(for candidate: ResolvedDownload) -> String {
        var details: [String] = []
        if let width = candidate.format.width, let height = candidate.format.height, width > 0, height > 0 {
            details.append("\(width)×\(height)")
        }
        if let bitrate = candidate.format.bitrate, bitrate > 0 {
            details.append("\(bitrate / 1000) kbps")
        }
        details.append(candidate.format.transport.rawValue.uppercased())
        return details.joined(separator: " · ")
    }
}

private struct TwitterVideoPreviewCard: View {
    let candidate: ResolvedDownload
    let title: String
    let subtitle: String
    let onQueue: () -> Void

    @State private var player: AVPlayer

    init(
        candidate: ResolvedDownload,
        title: String,
        subtitle: String,
        onQueue: @escaping () -> Void
    ) {
        self.candidate = candidate
        self.title = title
        self.subtitle = subtitle
        self.onQueue = onQueue
        let player = AVPlayer(url: candidate.format.url)
        player.isMuted = true
        _player = State(initialValue: player)
    }

    private var previewAspectRatio: CGFloat {
        if let width = candidate.format.width,
           let height = candidate.format.height,
           width > 0,
           height > 0 {
            return CGFloat(width) / CGFloat(height)
        }
        if let thumbnail = candidate.entry.thumbnails.first,
           let width = thumbnail.width,
           let height = thumbnail.height,
           width > 0,
           height > 0 {
            return CGFloat(width) / CGFloat(height)
        }
        return 16.0 / 9.0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VideoPlayer(player: player)
                .aspectRatio(previewAspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onDisappear {
                    player.pause()
                }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    player.pause()
                    onQueue()
                } label: {
                    Label("Queue", systemImage: "arrow.down.circle.fill")
                        .saveXGlassLabel()
                }
                .buttonStyle(.glass)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

#Preview("Home") {
    HomeView(downloadCenter: .preview)
}
