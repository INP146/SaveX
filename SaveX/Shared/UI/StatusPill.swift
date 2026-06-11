import SwiftUI

struct StatusPill: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glassEffect(.clear.interactive(), in: Capsule())
    }
}

#Preview("Status Pill") {
    ZStack {
        SaveXBackground()
        StatusPill("Resolving", systemImage: "magnifyingglass")
    }
}
