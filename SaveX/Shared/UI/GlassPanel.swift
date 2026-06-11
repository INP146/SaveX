import SwiftUI

struct GlassPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
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
