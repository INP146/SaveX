import SwiftUI

struct HomeView: View {
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("SaveX")
                    .font(.largeTitle.bold())

                Text("Save videos from X.")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    Label("Architecture scaffold created", systemImage: "checkmark.circle.fill")
                    Label("Home feature moved to Features/Home", systemImage: "square.stack.3d.up.fill")
                    Label("App entry moved to App/", systemImage: "shippingbox.fill")
                }
                .font(.body)
                .symbolRenderingMode(.hierarchical)

                Spacer()
            }
            .padding(24)
            .navigationTitle("Home")
        }
    }
}

#Preview {
    HomeView()
}
