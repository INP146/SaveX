import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var cookieStore: TwitterCookieStore

    @AppStorage("SaveX.defaultDownloadRoute") private var defaultRouteRaw = QualityPreset.best
        .rawValue
    @State private var cookieDraft = ""

    var body: some View {
        NavigationStack {
            ZStack {
                SaveXBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header

                        GlassPanel {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Download policy")
                                    .font(.headline)

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
                            }
                        }

                        GlassPanel {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    Text("Twitter/X cookie")
                                        .font(.headline)
                                    Spacer()
                                    StatusPill(
                                        cookieStore.hasCookie ? "Enabled" : "Guest",
                                        systemImage: cookieStore.hasCookie
                                            ? "person.crop.circle.badge.checkmark"
                                            : "person.crop.circle")
                                }

                                Text(
                                    "Advanced: paste a Cookie header from an account you control. It stays on this device and is sent only to Twitter/X requests."
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)

                                TextEditor(text: $cookieDraft)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(.footnote.monospaced())
                                    .frame(minHeight: 110)
                                    .padding(10)
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
                                    }
                                    .buttonStyle(.glass)

                                    Button(role: .destructive) {
                                        cookieStore.clear()
                                        cookieDraft = ""
                                    } label: {
                                        Label("Clear", systemImage: "trash")
                                    }
                                    .buttonStyle(.glass)

                                    Button {
                                        cookieStore.update(cookieHeader: cookieDraft)
                                    } label: {
                                        Label("Save", systemImage: "checkmark.circle.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.glassProminent)
                                    .disabled(
                                        cookieDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                            .isEmpty)
                                }

                                SettingRow(
                                    title: "auth_token",
                                    value: cookieStore.cookieValue(named: "auth_token") == nil
                                        ? "Missing" : "Present")
                                SettingRow(
                                    title: "ct0",
                                    value: cookieStore.cookieValue(named: "ct0") == nil
                                        ? "Missing" : "Present")
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .toolbarTitleDisplayMode(.inline)
            .onAppear {
                cookieDraft = cookieStore.currentCookieHeader()
            }
        }
    }

    private var header: some View {
        Text("Settings")
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .padding(.top, 12)
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
}

private struct SettingRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
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
