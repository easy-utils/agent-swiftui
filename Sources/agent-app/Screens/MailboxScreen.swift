import SwiftUI

// MailboxScreen — the session's deferred-message list.

struct MailboxScreen: View {
    @Environment(\.appColors) private var p
    @Bindable var store: AppStore

    @State private var entries: [MailboxEntry] = []
    @State private var loading = true
    @State private var error = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.sm) {
                Button {
                    store.popPage()
                } label: {
                    AppIcon(AppIcons.back).foregroundStyle(p.foreground)
                }
                Text(t("mailbox")).appFont(.body).fontWeight(.semibold).foregroundStyle(p.foreground)
                Spacer()
            }
            .padding(.horizontal, AppSpacing.sm)
            .frame(height: 48)
            Divider().overlay(p.border)
            if loading {
                Spacer()
                ProgressView()
                Spacer()
            } else if !error.isEmpty {
                Text(error).appFont(.meta).foregroundStyle(p.destructive).padding()
                Spacer()
            } else if entries.isEmpty {
                Spacer()
                Text(t("noMessages")).appFont(.meta).foregroundStyle(p.mutedForeground)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: AppSpacing.sm) {
                        ForEach(entries) { e in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(e.msgType).appFont(.meta).fontWeight(.semibold).foregroundStyle(p.foreground)
                                    Text(e.status)
                                        .appFont(.micro)
                                        .foregroundStyle(e.status == "consumed" ? p.success : p.warning)
                                    Spacer()
                                    Text(e.createdAt).appFont(.micro).foregroundStyle(p.mutedForeground)
                                }
                                if !e.payload.isEmpty {
                                    Text(String(e.payload.prefix(400)))
                                        .appMonoFont(.micro)
                                        .foregroundStyle(p.mutedForeground)
                                }
                            }
                            .padding(AppSpacing.md)
                            .background(p.card, in: RoundedRectangle(cornerRadius: AppRadius.md))
                            .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(p.border.opacity(0.6)))
                        }
                    }
                    .padding(AppSpacing.lg)
                }
            }
        }
        .background(p.background)
        .task(id: store.activeSessionId) {
            guard let sid = store.activeSessionId else { return }
            do {
                entries = try await store.api.mailbox(sid)
                error = ""
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}
