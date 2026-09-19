import SwiftUI

// Shared startup / loading surface.
//
// One visual contract across all four clients (Flutter, WebUI, Compose,
// SwiftUI): a centered rounded square MARK (each client's own two-letter
// mark), the app title, and a ring.
//
// SwiftUI mark is AS / amber #d97706. Keep in sync with the other clients.

struct LoadingScreen: View {
    @Environment(\.appColors) private var colors

    var body: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0xd9 / 255, green: 0x77 / 255, blue: 0x06 / 255))
                .frame(width: 40, height: 40)
                .overlay(
                    Text("AS")
                        .appFont(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                )
            Text(t("appTitle"))
                .appFont(.body)
                .foregroundStyle(colors.foreground)
            ProgressView()
                .controlSize(.small)
                .tint(colors.mutedForeground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.background)
    }
}
