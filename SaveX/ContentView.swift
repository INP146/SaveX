import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("SaveX")
                    .font(.largeTitle.bold())

                Text("Save videos from X.")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    Label("SwiftUI scaffold created", systemImage: "checkmark.circle.fill")
                    Label("Bundle ID: com.savex", systemImage: "shippingbox.fill")
                    Label("Deployment target: iOS 26.0", systemImage: "iphone")
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
    ContentView()
}
