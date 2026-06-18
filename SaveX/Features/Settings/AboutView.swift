import SwiftUI

struct AboutView: View {
    private let xProfileURL = URL(string: "https://x.com/INP1458")!
    private let gitHubProfileURL = URL(string: "https://github.com/INP146/SaveX")!

    private var version: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private var versionText: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version, build) {
        case (.some(let version), .some(let build)) where !version.isEmpty && !build.isEmpty:
            return "Version \(version) (\(build))"
        case (.some(let version), _) where !version.isEmpty:
            return "Version \(version)"
        default:
            return "Version unavailable"
        }
    }

    var body: some View {
        ZStack {
            SaveXBackground()

            StablePageScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GlassPanel {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack(spacing: 14) {
                                Image(.appIconSmall)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 64, height: 64)
                                    .clipShape(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Save𝕏")
                                        .font(.title2.weight(.regular))
                                    Text(versionText)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Text("A focused utility for saving Twitter/X videos locally.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            VStack(spacing: 0) {
                                AboutInfoRow(
                                    title: "Kernel",
                                    value: (SaveXKernelCompatibility.kernelVersion),
                                    icon: .system("cpu")
                                )

                                Divider()
                                    .opacity(0.45)

                                Link(destination: xProfileURL) {
                                    AboutInfoRow(
                                        title: "Twitter", value: "@INP1458", icon: .asset(.brandX))
                                }
                                .buttonStyle(.plain)

                                Divider()
                                    .opacity(0.45)

                                Link(destination: gitHubProfileURL) {
                                    AboutInfoRow(
                                        title: "GitHub", value: "INP146/SaveX",
                                        icon: .asset(.brandGitHub)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(.white.opacity(0.05))
                            )
                        }
                    }
                }
                .padding(.top, 12)
            }
        }
        .saveXNavigationChrome()
        .navigationTitle("About")
    }
}

private struct AboutInfoRow: View {
    enum Icon {
        case system(String)
        case asset(ImageResource)
    }

    let title: String
    let value: String
    let icon: Icon

    var body: some View {
        HStack(spacing: 12) {
            iconView
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)

            Text(title)
                .font(.subheadline.weight(.semibold))

            Spacer(minLength: 12)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .system(let name):
            Image(systemName: name)
                .font(.subheadline.weight(.semibold))
        case .asset(let resource):
            Image(resource)
                .resizable()
                .scaledToFit()
        }
    }
}

#Preview("About") {
    NavigationStack {
        AboutView()
    }
}
