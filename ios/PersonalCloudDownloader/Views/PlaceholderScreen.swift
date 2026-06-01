import SwiftUI

/// Minimal placeholder used by every tab until real screens are built.
struct PlaceholderScreen: View {
    let title: String
    let description: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text(title)
                    .font(.largeTitle)
                    .fontWeight(.semibold)

                Text(description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
        }
    }
}

#Preview {
    PlaceholderScreen(title: "Home", description: "Placeholder description.")
}
