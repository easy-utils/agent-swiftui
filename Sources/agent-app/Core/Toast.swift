import SwiftUI

// ToastCenter — a tiny global transient-message presenter (the SwiftUI
// counterpart of flutter's `showToast` / webui's toast store). Any screen calls
// `showToast(_:)`; ShellView renders the banner.

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    @Published var message: String?
    private var task: Task<Void, Never>?

    func show(_ text: String) {
        message = text
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}

@MainActor
func showToast(_ text: String) {
    ToastCenter.shared.show(text)
}

struct ToastOverlay: View {
    @Environment(\.appColors) private var p
    @ObservedObject var center = ToastCenter.shared

    var body: some View {
        if let message = center.message {
            VStack {
                Spacer()
                Text(message)
                    .appFont(.meta)
                    .foregroundStyle(p.foreground)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.sm)
                    .background(p.popover, in: Capsule())
                    .overlay(Capsule().stroke(p.border))
                    .padding(.bottom, AppSpacing.xl)
            }
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }
}
