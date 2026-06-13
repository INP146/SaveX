import SwiftUI
import UIKit

struct HomeView: View {
    @ObservedObject var downloadCenter: DownloadCenter

    @State private var tweetURL = ""
    @AppStorage("SaveX.defaultDownloadRoute") private var preferredQualityRaw = QualityPreset.best
        .rawValue

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
                        let didQueue = downloadCenter.enqueue(
                            rawURL: tweetURL,
                            preference: preferredQuality.selectionPreference
                        )
                        if didQueue {
                            tweetURL = ""
                        }
                    } label: {
                        Label("Queue", systemImage: "arrow.down.circle.fill")
                            .saveXGlassLabel(expands: true)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(tweetURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

            }
        }
    }
}

#Preview("Home") {
    HomeView(downloadCenter: .preview)
}
