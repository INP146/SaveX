import SwiftUI
import UIKit

struct GlassPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

enum SaveXPageLayout {
    static let pagePadding: CGFloat = 20

    static var standardInsets: EdgeInsets {
        EdgeInsets(
            top: pagePadding,
            leading: pagePadding,
            bottom: pagePadding,
            trailing: pagePadding
        )
    }
}

struct StablePageScrollView<Content: View>: View {
    @ViewBuilder let content: Content
    let contentInsets: EdgeInsets
    @State private var layoutRevision = 0

    init(
        contentInsets: EdgeInsets = SaveXPageLayout.standardInsets,
        @ViewBuilder content: () -> Content
    ) {
        self.contentInsets = contentInsets
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .padding(contentInsets)
                    .frame(width: proxy.size.width, alignment: .topLeading)
                    .id(layoutRevision)
                    .task {
                        guard layoutRevision == 0 else { return }
                        await Task.yield()
                        layoutRevision = 1
                    }
            }
        }
    }
}

private enum SaveXGlassButtonMetrics {
    static let height: CGFloat = 30
    static let compactWidth: CGFloat = 76
    static let iconDiameter: CGFloat = 42
}

extension View {
    func saveXGlassLabel(expands: Bool = false, minWidth: CGFloat = SaveXGlassButtonMetrics.compactWidth) -> some View {
        frame(
            minWidth: expands ? nil : minWidth,
            maxWidth: expands ? .infinity : nil,
            minHeight: SaveXGlassButtonMetrics.height
        )
    }

    func saveXGlassIcon(diameter: CGFloat = SaveXGlassButtonMetrics.iconDiameter) -> some View {
        font(.headline)
            .frame(width: diameter, height: diameter)
            .glassEffect(.regular.interactive(), in: Circle())
            .contentShape(Circle())
    }

    func saveXGlassProminentIcon(diameter: CGFloat = SaveXGlassButtonMetrics.iconDiameter) -> some View {
        modifier(SaveXGlassProminentIconStyle(diameter: diameter))
    }

    func saveXGlassIconButton() -> some View {
        buttonStyle(.plain)
            .contentShape(Circle())
    }

    func saveXNavigationChrome() -> some View {
        toolbarTitleDisplayMode(.inline)
    }

    func saveXKeyboardDismissOverlay() -> some View {
        modifier(SaveXKeyboardDismissOverlay())
    }
}

private struct SaveXGlassProminentIconStyle: ViewModifier {
    let diameter: CGFloat
    @Environment(\.saveXTheme) private var theme

    func body(content: Content) -> some View {
        content
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(theme.palette.accent))
            .glassEffect(.regular.interactive(), in: Circle())
            .contentShape(Circle())
    }
}

private struct SaveXKeyboardDismissOverlay: ViewModifier {
    @State private var isKeyboardVisible = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if isKeyboardVisible {
                    Button {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil,
                            from: nil,
                            for: nil
                        )
                    } label: {
                        Label("Done", systemImage: "keyboard.chevron.compact.down")
                    }
                    .buttonStyle(.glass)
                    .padding(.trailing, 16)
                    .padding(.bottom, 8)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
                let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                let screenHeight = activeScreenHeight
                withKeyboardAnimation(notification) {
                    isKeyboardVisible = endFrame.map { $0.minY < screenHeight } ?? false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
                withKeyboardAnimation(notification) {
                    isKeyboardVisible = false
                }
            }
    }

    private func withKeyboardAnimation(_ notification: Notification, _ update: @escaping () -> Void) {
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval
        withAnimation(.easeOut(duration: duration ?? 0.25)) {
            update()
        }
    }

    private var activeScreenHeight: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds.height }
            .first ?? 0
    }
}

#Preview("Glass Panel") {
    ZStack {
        SaveXBackground()
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text("Preview")
                    .font(.headline)
                Text("Liquid Glass panel")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
