import SwiftUI

struct SaveXBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(.systemBackground),
                Color.blue.opacity(0.16),
                Color.green.opacity(0.12),
                Color(.secondarySystemBackground)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .backgroundExtensionEffect()
    }
}

#Preview("Background") {
    SaveXBackground()
}
