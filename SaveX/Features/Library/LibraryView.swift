import AVFoundation
import AVKit
import SwiftUI

struct LibraryView: View {
    @ObservedObject var downloadCenter: DownloadCenter
    @AppStorage(SaveXStorageKey.libraryLayout) private var layoutRaw = LibraryLayout.cards.rawValue
    @State private var selectedItem: LocalLibraryItem?
    @State private var detailItem: LocalLibraryItem?
    @State private var pendingLayout: LibraryLayout?
    @State private var layoutTransitionTask: Task<Void, Never>?

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
                            libraryContent
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
            .onDisappear {
                layoutTransitionTask?.cancel()
                layoutTransitionTask = nil
                pendingLayout = nil
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Library")
                .font(.system(size: 34, weight: .bold, design: .rounded))

            Spacer()

            Picker("Layout", selection: layoutSelection) {
                ForEach(LibraryLayout.allCases, id: \.self) { layout in
                    Label(layout.accessibilityLabel, systemImage: layout.systemImage)
                        .labelStyle(.iconOnly)
                        .tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 128, height: 42)
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private var libraryContent: some View {
        switch activeLayout {
        case .cards:
            ForEach(downloadCenter.libraryItems) { item in
                LibraryRow(
                    fileURL: downloadCenter.fileURL(for: item),
                    play: { selectedItem = item },
                    showDetails: { detailItem = item },
                    delete: { downloadCenter.deleteLibraryItem(item) }
                )
            }
        case .grid:
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 156), spacing: 12, alignment: .top)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(downloadCenter.libraryItems) { item in
                    LibraryGridTile(
                        fileURL: downloadCenter.fileURL(for: item),
                        play: { selectedItem = item },
                        showDetails: { detailItem = item },
                        delete: { downloadCenter.deleteLibraryItem(item) }
                    )
                }
            }
        case .list:
            VStack(spacing: 12) {
                ForEach(downloadCenter.libraryItems) { item in
                    LibraryListRow(
                        title: item.title,
                        fileURL: downloadCenter.fileURL(for: item),
                        play: { selectedItem = item },
                        showDetails: { detailItem = item },
                        delete: { downloadCenter.deleteLibraryItem(item) }
                    )
                }
            }
        }
    }

    private var activeLayout: LibraryLayout {
        LibraryLayout(rawValue: layoutRaw) ?? .cards
    }

    private var layoutSelection: Binding<LibraryLayout> {
        Binding {
            pendingLayout ?? activeLayout
        } set: { newLayout in
            requestLayoutChange(to: newLayout)
        }
    }

    private func requestLayoutChange(to newLayout: LibraryLayout) {
        guard newLayout != activeLayout else {
            layoutTransitionTask?.cancel()
            layoutTransitionTask = nil
            pendingLayout = nil
            return
        }

        layoutTransitionTask?.cancel()
        pendingLayout = newLayout

        let fileURLs = downloadCenter.libraryItems.map { item in
            downloadCenter.fileURL(for: item)
        }

        guard !fileURLs.isEmpty else {
            layoutRaw = newLayout.rawValue
            pendingLayout = nil
            layoutTransitionTask = nil
            return
        }

        layoutTransitionTask = Task {
            await LibraryCoverGenerator.preload(fileURLs: fileURLs)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard pendingLayout == newLayout else { return }
                layoutRaw = newLayout.rawValue
                pendingLayout = nil
                layoutTransitionTask = nil
            }
        }
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

private enum LibraryLayout: String, CaseIterable {
    case cards
    case grid
    case list

    var systemImage: String {
        switch self {
        case .cards:
            return "rectangle.stack"
        case .grid:
            return "square.grid.2x2"
        case .list:
            return "list.bullet"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .cards:
            return "Card layout"
        case .grid:
            return "Grid layout"
        case .list:
            return "List layout"
        }
    }
}

private struct LibraryRow: View {
    let fileURL: URL
    let play: () -> Void
    let showDetails: () -> Void
    let delete: () -> Void

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                LibraryCoverView(fileURL: fileURL)

                LibraryActionsView(
                    fileURL: fileURL,
                    playStyle: .expanded,
                    play: play,
                    showDetails: showDetails,
                    delete: delete
                )
            }
        }
    }
}

private struct LibraryGridTile: View {
    let fileURL: URL
    let play: () -> Void
    let showDetails: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            LibraryCoverView(fileURL: fileURL, mode: .fill(aspectRatio: 1))

            LibraryActionsView(
                fileURL: fileURL,
                playStyle: .splitIcon,
                iconDiameter: 30,
                buttonSpacing: 8,
                iconGroupSpacing: 3,
                play: play,
                showDetails: showDetails,
                delete: delete
            )
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .top)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

private struct LibraryListRow: View {
    let title: String
    let fileURL: URL
    let play: () -> Void
    let showDetails: () -> Void
    let delete: () -> Void

    var body: some View {
        GlassPanel {
            HStack(spacing: 12) {
                LibraryCoverView(fileURL: fileURL, mode: .fill(aspectRatio: 16 / 9))
                    .frame(width: 112, height: 63)

                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    LibraryActionsView(
                        fileURL: fileURL,
                        playStyle: .icon,
                        iconDiameter: 38,
                        iconGroupSpacing: 5,
                        play: play,
                        showDetails: showDetails,
                        delete: delete
                    )
                }
            }
        }
    }
}

private struct LibraryActionsView: View {
    enum PlayStyle {
        case expanded
        case icon
        case splitIcon
    }

    let fileURL: URL
    let playStyle: PlayStyle
    var iconDiameter: CGFloat = 42
    var buttonSpacing: CGFloat = 12
    var iconGroupSpacing: CGFloat = 6
    let play: () -> Void
    let showDetails: () -> Void
    let delete: () -> Void

    @ViewBuilder
    var body: some View {
        switch playStyle {
        case .expanded:
            HStack(spacing: buttonSpacing) {
                playButton

                HStack(spacing: iconGroupSpacing) {
                    shareButton
                    detailsButton
                    deleteButton
                }
            }
            .frame(maxWidth: .infinity)
        case .icon:
            HStack(spacing: iconGroupSpacing) {
                playButton
                shareButton
                detailsButton
                deleteButton
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .splitIcon:
            HStack(spacing: buttonSpacing) {
                playButton

                Spacer(minLength: 0)

                HStack(spacing: iconGroupSpacing) {
                    shareButton
                    detailsButton
                    deleteButton
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var playButton: some View {
        switch playStyle {
        case .expanded:
            Button(action: play) {
                Label("Play", systemImage: "play.circle.fill")
                    .saveXGlassLabel(expands: true)
            }
            .buttonStyle(.glassProminent)
            .disabled(!fileExists)
        case .icon, .splitIcon:
            Button(action: play) {
                Image(systemName: "play.circle.fill")
                    .saveXGlassProminentIcon(diameter: iconDiameter)
            }
            .saveXGlassIconButton()
            .disabled(!fileExists)
            .accessibilityLabel("Play")
        }
    }

    private var shareButton: some View {
        ShareLink(item: fileURL) {
            Image(systemName: "square.and.arrow.up")
                .saveXGlassIcon(diameter: iconDiameter)
        }
        .saveXGlassIconButton()
        .disabled(!fileExists)
        .accessibilityLabel("Share")
    }

    private var detailsButton: some View {
        Button(action: showDetails) {
            Image(systemName: "info.circle")
                .saveXGlassIcon(diameter: iconDiameter)
        }
        .saveXGlassIconButton()
        .accessibilityLabel("Details")
    }

    private var deleteButton: some View {
        Button(role: .destructive, action: delete) {
            Image(systemName: "trash")
                .saveXGlassIcon(diameter: iconDiameter)
        }
        .saveXGlassIconButton()
        .accessibilityLabel("Delete")
    }

    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
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
    enum Mode {
        case original
        case fill(aspectRatio: CGFloat)
    }

    let fileURL: URL
    var mode: Mode = .original
    @State private var coverImage: CGImage?
    @State private var didAttemptLoad = false

    init(fileURL: URL, mode: Mode = .original) {
        self.fileURL = fileURL
        self.mode = mode
        let cachedCoverImage = LibraryCoverGenerator.cachedCoverImage(for: fileURL)
        _coverImage = State(initialValue: cachedCoverImage)
        _didAttemptLoad = State(initialValue: cachedCoverImage != nil)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let coverImage {
                    Image(decorative: coverImage, scale: 1, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    Rectangle()
                        .fill(.thinMaterial)
                        .overlay {
                            Image(systemName: placeholderSymbol)
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(targetAspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task(id: fileURL) {
            if let cachedCoverImage = LibraryCoverGenerator.cachedCoverImage(for: fileURL) {
                coverImage = cachedCoverImage
                didAttemptLoad = true
                return
            }

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

    private var contentMode: ContentMode {
        switch mode {
        case .original:
            return .fit
        case .fill:
            return .fill
        }
    }

    private var targetAspectRatio: CGFloat {
        switch mode {
        case .original:
            return coverImage.map { CGFloat($0.width) / CGFloat($0.height) } ?? 16 / 9
        case .fill(let aspectRatio):
            return aspectRatio
        }
    }
}

private enum LibraryCoverGenerator {
    private static let cache = NSCache<NSString, CGImage>()

    static func cachedCoverImage(for fileURL: URL) -> CGImage? {
        cache.object(forKey: cacheKey(for: fileURL))
    }

    static func preload(fileURLs: [URL]) async {
        await withTaskGroup(of: Void.self) { group in
            for fileURL in fileURLs where FileManager.default.fileExists(atPath: fileURL.path) {
                group.addTask {
                    _ = await coverImage(for: fileURL)
                }
            }
        }
    }

    static func coverImage(for fileURL: URL) async -> CGImage? {
        let cacheKey = cacheKey(for: fileURL)
        if let cachedCoverImage = cache.object(forKey: cacheKey) {
            return cachedCoverImage
        }

        let generatedCoverImage = await Task.detached(priority: .utility) {
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

        if let generatedCoverImage {
            cache.setObject(generatedCoverImage, forKey: cacheKey)
        }
        return generatedCoverImage
    }

    private static func cacheKey(for fileURL: URL) -> NSString {
        let standardizedURL = fileURL.standardizedFileURL
        let values = try? standardizedURL.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey
        ])
        let modifiedAt = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let fileSize = values?.fileSize ?? 0
        return "\(standardizedURL.path)|\(fileSize)|\(modifiedAt)" as NSString
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
