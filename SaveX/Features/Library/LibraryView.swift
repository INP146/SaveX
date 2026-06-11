import AVKit
import SwiftUI

struct LibraryView: View {
    @ObservedObject var downloadCenter: DownloadCenter
    @State private var selectedItem: LocalLibraryItem?

    var body: some View {
        NavigationStack {
            ZStack {
                SaveXBackground()

                ScrollView {
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
                                    delete: { downloadCenter.deleteLibraryItem(item) }
                                )
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                Button {
                    downloadCenter.reloadLibrary()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Reload library")
            }
            .sheet(item: $selectedItem) { item in
                LibraryPlayerView(url: downloadCenter.fileURL(for: item), title: item.title)
            }
        }
    }

    private var header: some View {
        Text("Library")
            .font(.system(size: 34, weight: .bold, design: .rounded))
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
    let delete: () -> Void

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.headline)
                            .lineLimit(2)

                        Text(item.sourceURL?.host() ?? "local file")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    StatusPill(item.formatID, systemImage: "film")
                }

                HStack {
                    Label(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file), systemImage: "internaldrive")
                    Spacer()
                    Text(item.createdAt, style: .date)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button(action: play) {
                        Label("Play", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!FileManager.default.fileExists(atPath: fileURL.path))

                    ShareLink(item: fileURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.glass)
                    .disabled(!FileManager.default.fileExists(atPath: fileURL.path))

                    Button(role: .destructive, action: delete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Delete")
                }
            }
        }
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
