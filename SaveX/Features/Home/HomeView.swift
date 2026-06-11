import SwiftUI
import UIKit

struct HomeView: View {
    @ObservedObject var downloadCenter: DownloadCenter

    @State private var tweetURL = ""
    @State private var preferredQuality = QualityPreset.best

    var body: some View {
        NavigationStack {
            ZStack {
                SaveXBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        inputPanel
                        quickStats
                        recentPanel
                    }
                    .padding(20)
                }
            }
            .toolbarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SaveX")
                .font(.system(size: 34, weight: .bold, design: .rounded))
        }
        .padding(.top, 12)
    }

    private var inputPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 16) {
                Text("New download")
                    .font(.headline)

                TextField("Type post URL here", text: $tweetURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .padding(14)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                Picker("Download route", selection: $preferredQuality) {
                    ForEach(QualityPreset.allCases) { quality in
                        Text(quality.label)
                            .tag(quality)
                    }
                }
                .pickerStyle(.segmented)

                Text(preferredQuality.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button {
                        if let clipboard = UIPasteboard.general.string?
                            .trimmingCharacters(in: .whitespacesAndNewlines), !clipboard.isEmpty {
                            tweetURL = clipboard
                        }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.glass)

                    Button {
                        let didQueue = downloadCenter.enqueue(
                            rawURL: tweetURL,
                            preference: preferredQuality.selectionPreference
                        )
                        if didQueue {
                            tweetURL = ""
                        }
                    } label: {
                        Label("Queue", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(tweetURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                messageRow
            }
        }
    }

    private var quickStats: some View {
        HStack(spacing: 12) {
            MetricTile(title: "Active", value: "\(downloadCenter.activeCount)", symbol: "bolt.horizontal.circle")
            MetricTile(title: "Saved", value: "\(downloadCenter.completedCount)", symbol: "checkmark.circle")
            MetricTile(title: "Space", value: ByteCountFormatter.string(fromByteCount: downloadCenter.savedBytes, countStyle: .file), symbol: "internaldrive")
        }
    }

    private var recentPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Pipeline")
                        .font(.headline)
                    Spacer()
                    StatusPill(SaveXKernelCompatibility.ytDLPVersion, systemImage: "hammer")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label("Twitter URL parser", systemImage: "link")
                    Label("GraphQL + legacy API config", systemImage: "network")
                    Label("Format selector aligned to yt-dlp", systemImage: "list.number")
                    Label("MP4 direct and basic HLS download wired", systemImage: "arrow.down.circle")
                    Label(downloadCenter.hasJobs ? "Jobs list synced with live kernel state" : "Queue a public tweet to start the local kernel", systemImage: "sparkle.magnifyingglass")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var messageRow: some View {
        HStack(spacing: 8) {
            Image(systemName: messageSymbol)
                .foregroundStyle(messageColor)
            Text(downloadCenter.banner.text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(messageColor)
                .lineLimit(2)
        }
    }

    private var messageColor: Color {
        switch downloadCenter.banner.kind {
        case .info:
            return .secondary
        case .success:
            return .green
        case .error:
            return .red
        }
    }

    private var messageSymbol: String {
        switch downloadCenter.banner.kind {
        case .info:
            return "bolt.horizontal.circle"
        case .success:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.blue)

            Text(value)
                .font(.title2.bold())

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private enum QualityPreset: String, CaseIterable, Identifiable {
    case best
    case mp4
    case hls

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .best:
            return "Auto"
        case .mp4:
            return "MP4 File"
        case .hls:
            return "HLS Stream"
        }
    }

    var helpText: String {
        switch self {
        case .best:
            return "Automatically picks the best compatible download route."
        case .mp4:
            return "Prefers a single MP4 file when Twitter/X exposes one."
        case .hls:
            return "Prefers the streamed playlist route when available."
        }
    }

    var selectionPreference: FormatSelectionPreference {
        switch self {
        case .best:
            return .ytDLPCompatible
        case .mp4:
            return .preferMP4Direct
        case .hls:
            return .preferHLS
        }
    }
}

#Preview("Home") {
    HomeView(downloadCenter: .preview)
}
