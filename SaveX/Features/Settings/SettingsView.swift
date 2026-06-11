import SwiftUI

struct SettingsView: View {
    @State private var preferMP4 = true
    @State private var allowCellular = false
    @State private var keepOriginalFilenames = true

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

                                Toggle("Prefer MP4 direct links", isOn: $preferMP4)
                                Toggle("Allow cellular downloads", isOn: $allowCellular)
                                Toggle("Keep source filenames", isOn: $keepOriginalFilenames)
                            }
                        }

                        GlassPanel {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Local engine")
                                    .font(.headline)

                                SettingRow(title: "Extractor", value: "Twitter/X")
                                SettingRow(title: "Selector", value: "Best compatible")
                                SettingRow(title: "Downloader", value: "MP4 first")
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
        Text("Settings")
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .padding(.top, 12)
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

#Preview("Settings") {
    SettingsView()
}
