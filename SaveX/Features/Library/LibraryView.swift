import AVFoundation
import AVKit
import SwiftUI

struct LibraryView: View {
    @ObservedObject var downloadCenter: DownloadCenter
    @State private var selectedItem: LocalLibraryItem?
    @State private var detailItem: LocalLibraryItem?

    var body: some View {
        NavigationStack {
            ZStack {
                SaveXBackground()

                StablePageScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header

                        if downloadCenter.libraryItems.isEmpty {
                            emptyState
                        } else {
                            ForEach(downloadCenter.libraryItems) { item in
                                LibraryRow(
                                    item: item,
                                    fileURL: downloadCenter.fileURL(for: item),
                                    play: { selectedItem = item },
                                    showDetails: { detailItem = item },
                                    delete: { downloadCenter.deleteLibraryItem(item) }
                                )
                            }
                        }
                    }
                }
            }
            .saveXNavigationChrome()
            .sheet(item: $selectedItem) { item in
                LibraryPlayerView(url: downloadCenter.fileURL(for: item), title: item.title)
            }
            .sheet(item: $detailItem) { item in
                LibraryDetailView(item: item, fileURL: downloadCenter.fileURL(for: item))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Library")
                .font(.system(size: 34, weight: .bold, design: .rounded))

            Spacer()

            Button {
                downloadCenter.reloadLibrary()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .saveXGlassIcon()
            }
            .saveXGlassIconButton()
            .accessibilityLabel("Reload library")
        }
        .padding(.top, 12)
    }

    private var emptyState: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text("No saved files")
                    .font(.headline)

                Text("Completed downloads stay here even if Photos saving fails.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LibraryRow: View {
    let item: LocalLibraryItem
    let fileURL: URL
    let play: () -> Void
    let showDetails: () -> Void
    let delete: () -> Void

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                LibraryCoverView(fileURL: fileURL)

                HStack(spacing: 12) {
                    Button(action: play) {
                        Label("Play", systemImage: "play.circle.fill")
                            .saveXGlassLabel(expands: true)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!FileManager.default.fileExists(atPath: fileURL.path))

                    HStack(spacing: 6) {
                        ShareLink(item: fileURL) {
                            Image(systemName: "square.and.arrow.up")
                                .saveXGlassIcon()
                        }
                        .saveXGlassIconButton()
                        .disabled(!FileManager.default.fileExists(atPath: fileURL.path))
                        .accessibilityLabel("Share")

                        Button(action: showDetails) {
                            Image(systemName: "info.circle")
                                .saveXGlassIcon()
                        }
                        .saveXGlassIconButton()
                        .accessibilityLabel("Details")

                        Button(role: .destructive, action: delete) {
                            Image(systemName: "trash")
                                .saveXGlassIcon()
                        }
                        .saveXGlassIconButton()
                        .accessibilityLabel("Delete")
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct LibraryDetailView: View {
    let item: LocalLibraryItem
    let fileURL: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                SaveXBackground()

                StablePageScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        LibraryCoverView(fileURL: fileURL)

                        detailsCard
                    }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }

    private var displayFormat: String {
        if item.formatID.hasPrefix("http-"),
           let bitrate = Int(item.formatID.replacingOccurrences(of: "http-", with: "")) {
            return "MP4 · \(bitrateText(bitrate))"
        }
        if item.formatID == "hls" || item.formatID.hasPrefix("hls") {
            return "HLS"
        }
        return item.formatID
    }

    private var detailsCard: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 0) {
                detailRow(title: "Title", value: item.title, systemImage: "text.quote")
                detailDivider
                detailRow(title: "Source", value: item.sourceURL?.absoluteString ?? "local file", systemImage: "link")
                detailDivider
                detailRow(title: "Format", value: displayFormat, systemImage: "film")
                detailDivider
                detailRow(title: "File", value: item.fileName, systemImage: "doc")
                detailDivider
                detailRow(title: "Size", value: ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file), systemImage: "internaldrive")
                detailDivider
                detailRow(title: "Saved", value: item.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                detailDivider
                detailRow(title: "Tweet ID", value: item.sourceTweetID, systemImage: "number")

                if let responseMimeType = item.responseMimeType, !responseMimeType.isEmpty {
                    detailDivider
                    detailRow(title: "MIME", value: responseMimeType, systemImage: "tag")
                }
            }
        }
    }

    private var detailDivider: some View {
        Divider()
            .padding(.leading, 28)
            .padding(.vertical, 12)
    }

    private func detailRow(title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bitrateText(_ bitrate: Int) -> String {
        let megabits = Double(bitrate) / 1_000_000
        if megabits >= 1 {
            return "\(megabits.formatted(.number.precision(.fractionLength(2)))) Mbps"
        }
        let kilobits = Double(bitrate) / 1_000
        return "\(kilobits.formatted(.number.precision(.fractionLength(0)))) Kbps"
    }
}

private struct LibraryCoverView: View {
    let fileURL: URL
    @State private var coverImage: CGImage?
    @State private var didAttemptLoad = false

    var body: some View {
        ZStack {
            if let coverImage {
                Image(decorative: coverImage, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay {
                        Image(systemName: placeholderSymbol)
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task(id: fileURL) {
            coverImage = nil
            didAttemptLoad = false
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                didAttemptLoad = true
                return
            }
            let generatedCoverImage = await LibraryCoverGenerator.coverImage(for: fileURL)
            guard !Task.isCancelled else { return }
            coverImage = generatedCoverImage
            didAttemptLoad = true
        }
    }

    private var placeholderSymbol: String {
        didAttemptLoad ? "film.stack" : "photo"
    }
}

private enum LibraryCoverGenerator {
    static func coverImage(for fileURL: URL) async -> CGImage? {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: fileURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 900, height: 506)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            let context = LibraryCoverGenerationContext(generator: generator)

            return await withCheckedContinuation { continuation in
                context.generator.generateCGImageAsynchronously(
                    for: CMTime(seconds: 0.2, preferredTimescale: 600)
                ) { image, _, error in
                    _ = context
                    continuation.resume(returning: error == nil ? image : nil)
                }
            }
        }.value
    }
}

private final class LibraryCoverGenerationContext: @unchecked Sendable {
    let generator: AVAssetImageGenerator

    init(generator: AVAssetImageGenerator) {
        self.generator = generator
    }
}

private struct LibraryPlayerView: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer

    init(url: URL, title: String) {
        self.url = url
        self.title = title
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button("Done") {
                        player.pause()
                        dismiss()
                    }
                }
                .onAppear {
                    player.play()
                }
                .onDisappear {
                    player.pause()
                }
        }
    }
}

#Preview("Library") {
    LibraryView(downloadCenter: .preview)
}
