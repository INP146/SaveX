import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var cookieStore: TwitterCookieStore

    @AppStorage(SaveXStorageKey.defaultDownloadRoute) private var defaultRouteRaw = QualityPreset
        .best
        .rawValue
    @AppStorage(SaveXStorageKey.savesDownloadsToLibrary) private var savesDownloadsToLibrary = true
    @AppStorage(SaveXStorageKey.savesDownloadsToPhotos) private var savesDownloadsToPhotos = true
    @AppStorage(SaveXStorageKey.downloadsAllTweetVideosByDefault) private var downloadsAllTweetVideosByDefault = false
    @State private var cookieDraft = ""
    @State private var cookieValidationMessage = ""
    @State private var showsCookieValidationAlert = false

    var body: some View {
        NavigationStack {
            ZStack {
                SaveXBackground()

                StablePageScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header

                        aboutPanel

                        preferencesPanel

                        GlassPanel {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    Text("Twitter/X session")
                                        .font(.headline)
                                    Spacer()
                                    StatusPill(
                                        cookieStore.hasCookie ? "Cookie enabled" : "Guest",
                                        systemImage: cookieStore.hasCookie
                                            ? "person.crop.circle.badge.checkmark"
                                            : "person.crop.circle")
                                }

                                if cookieStore.hasCookie {
                                    Text(
                                        "Cookie is stored in Keychain and will be sent only to Twitter/X requests."
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                    Button(role: .destructive) {
                                        cookieStore.clear()
                                        cookieDraft = ""
                                    } label: {
                                        Label("Clear", systemImage: "trash")
                                            .saveXGlassLabel(expands: true)
                                    }
                                    .buttonStyle(.glass)
                                } else {
                                    Text(
                                        "Advanced: paste a Cookie header from an account you control. SaveX stores it in Keychain and sends it only to Twitter/X requests."
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                    ZStack(alignment: .topLeading) {
                                        TextEditor(text: $cookieDraft)
                                            .textInputAutocapitalization(.never)
                                            .autocorrectionDisabled()
                                            .font(.footnote.monospaced())
                                            .frame(minHeight: 110)
                                            .padding(10)
                                            .scrollContentBackground(.hidden)

                                        if cookieDraft.isEmpty {
                                            Text("Paste Cookie: auth_token=...; ct0=...; ...")
                                                .font(.footnote.monospaced())
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 15)
                                                .padding(.vertical, 18)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                    .background(
                                        .thinMaterial,
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                                    HStack(spacing: 12) {
                                        Button {
                                            if let clipboard = UIPasteboard.general.string?
                                                .trimmingCharacters(in: .whitespacesAndNewlines),
                                                !clipboard.isEmpty
                                            {
                                                cookieDraft = clipboard
                                            }
                                        } label: {
                                            Label("Paste", systemImage: "doc.on.clipboard")
                                                .saveXGlassLabel()
                                        }
                                        .buttonStyle(.glass)

                                        Button {
                                            saveCookieDraft()
                                        } label: {
                                            Label("Save", systemImage: "checkmark.circle.fill")
                                                .saveXGlassLabel(expands: true)
                                        }
                                        .buttonStyle(.glassProminent)
                                        .disabled(
                                            cookieDraft.trimmingCharacters(
                                                in: .whitespacesAndNewlines
                                            )
                                            .isEmpty)
                                    }
                                    .frame(maxWidth: .infinity)
                                }

                                if let error = cookieStore.lastStorageError {
                                    Label(error, systemImage: "lock.trianglebadge.exclamationmark")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
            }
            .saveXNavigationChrome()
            .onAppear {
                normalizeSaveDestinations()
                cookieDraft = ""
            }
            .alert("Cookie cannot be saved", isPresented: $showsCookieValidationAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(cookieValidationMessage)
            }
        }
    }

    private var header: some View {
        Text("Settings")
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .padding(.top, 12)
    }

    private var preferencesPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 16) {

                VStack(alignment: .leading, spacing: 10) {
                    Text("Download policy")
                        .font(.subheadline.weight(.semibold))

                    Picker("Default route", selection: defaultRouteBinding) {
                        ForEach(QualityPreset.allCases) { quality in
                            Text(quality.label)
                                .tag(quality)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(defaultRoute.helpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    preferenceToggle(
                        title: "Download all tweet videos",
                        subtitle: "When a tweet has multiple videos, queue every video instead of asking.",
                        systemImage: "square.stack.3d.down.right.fill",
                        isOn: $downloadsAllTweetVideosByDefault
                    )
                }

                Divider()
                    .opacity(0.45)

                VStack(alignment: .leading, spacing: 12) {
                    preferenceToggle(
                        title: "Save to Library",
                        subtitle: "Keep a local copy in SaveX Library.",
                        systemImage: "books.vertical.fill",
                        isOn: saveToLibraryBinding
                    )

                    preferenceToggle(
                        title: "Save to Photos",
                        subtitle: "Add completed videos to your photo album.",
                        systemImage: "photo.on.rectangle.angled",
                        isOn: saveToPhotosBinding
                    )
                }
            }
        }
    }

    private var aboutPanel: some View {
        GlassPanel {
            NavigationLink {
                AboutView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "info.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("About SaveX")
                            .font(.subheadline.weight(.semibold))
                        Text("Version and app information.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var defaultRoute: QualityPreset {
        QualityPreset(rawValue: defaultRouteRaw) ?? .best
    }

    private var defaultRouteBinding: Binding<QualityPreset> {
        Binding(
            get: { defaultRoute },
            set: { defaultRouteRaw = $0.rawValue }
        )
    }

    private var saveToLibraryBinding: Binding<Bool> {
        Binding(
            get: { savesDownloadsToLibrary },
            set: { newValue in
                if newValue {
                    savesDownloadsToLibrary = true
                } else if savesDownloadsToPhotos {
                    savesDownloadsToLibrary = false
                } else {
                    savesDownloadsToLibrary = false
                    savesDownloadsToPhotos = true
                }
            }
        )
    }

    private var saveToPhotosBinding: Binding<Bool> {
        Binding(
            get: { savesDownloadsToPhotos },
            set: { newValue in
                if newValue {
                    savesDownloadsToPhotos = true
                } else if savesDownloadsToLibrary {
                    savesDownloadsToPhotos = false
                } else {
                    savesDownloadsToPhotos = false
                    savesDownloadsToLibrary = true
                }
            }
        )
    }

    private func preferenceToggle(
        title: String,
        subtitle: String,
        systemImage: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func normalizeSaveDestinations() {
        if !savesDownloadsToLibrary && !savesDownloadsToPhotos {
            savesDownloadsToLibrary = true
        }
    }

    private func saveCookieDraft() {
        let jar = TwitterCookieJar(rawHeader: cookieDraft)
        let blockingIssues = jar.validationIssues.filter { issue in
            issue != .malformedCookiePair
        }

        guard blockingIssues.isEmpty else {
            cookieValidationMessage =
                blockingIssues
                .map(\.label)
                .joined(separator: "\n")
            showsCookieValidationAlert = true
            return
        }

        cookieStore.update(cookieHeader: jar.header)
        cookieDraft = ""
    }
}

enum QualityPreset: String, CaseIterable, Identifiable {
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
            return "Automatically pick the best compatible route."
        case .mp4:
            return "Prefer a single MP4 file when Twitter/X exposes one."
        case .hls:
            return "Prefer the streamed playlist route when available."
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

#Preview("Settings") {
    SettingsView(cookieStore: TwitterCookieStore())
}
