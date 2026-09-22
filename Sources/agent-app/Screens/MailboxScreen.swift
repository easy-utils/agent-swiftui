import SwiftUI

// MailboxScreen — the session's deferred-message list. NEWEST-FIRST, paged
// backward for infinite scroll, each entry classified by (msgType, source).

struct MailboxScreen: View {
    @Environment(\.appColors) private var p
    @Bindable var store: AppStore

    @State private var entries: [MailboxEntry] = []
    @State private var hasMore = false
    @State private var loading = true
    @State private var loadingMore = false
    @State private var error = ""

    private let pageSize = 30

    /// (msgType, source) → icon + localized label + accent. `source` is an open
    /// string: user | session:{name} | system:{name} | other.
    private func metaOf(_ type: String, _ source: String) -> (LucideIconName, String, Color, String) {
        if type == "interrupt" { return (AppIcons.stop, t("mailboxInterrupt"), p.destructive, "") }
        if type != "trigger" { return (AppIcons.bolt, t("mailboxEvent"), p.warning, "") }
        if source == "user" { return (AppIcons.user, t("mailboxPrompt"), p.primary, "") }
        if source.hasPrefix("session:") {
            return (AppIcons.chat, t("mailboxFromSession"),
                    Color(red: 0x02/255, green: 0x84/255, blue: 0xC7/255),
                    String(source.dropFirst("session:".count)))
        }
        if source.hasPrefix("system:") {
            return (AppIcons.bolt, t("mailboxFromSystem"),
                    Color(red: 0x7C/255, green: 0x3A/255, blue: 0xED/255),
                    String(source.dropFirst("system:".count)))
        }
        return (AppIcons.bolt, t("mailboxPrompt"), p.primary, source)
    }

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
                    LazyVStack(spacing: AppSpacing.sm) {
                        ForEach(entries) { e in
                            let meta = metaOf(e.msgType, e.source)
                            let consumed = e.consumedAt != nil
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    AppIcon(meta.0).frame(width: 12, height: 12).foregroundStyle(meta.2)
                                    Text(meta.1).appFont(.micro).fontWeight(.semibold).foregroundStyle(meta.2)
                                    if !meta.3.isEmpty {
                                        Text("· \(meta.3)").appFont(.micro).foregroundStyle(meta.2.opacity(0.8))
                                    }
                                    Spacer()
                                    Text(consumed ? t("consumed") : t("pending"))
                                        .appFont(.micro)
                                        .foregroundStyle(consumed ? p.success : p.mutedForeground)
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
                            .onAppear {
                                if e.id == entries.last?.id { loadMore() }
                            }
                        }
                        if hasMore || loadingMore {
                            ProgressView().padding(AppSpacing.md)
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
                let page = try await store.api.mailbox(sid, limit: pageSize)
                entries = page.entries
                hasMore = page.hasMore
                error = ""
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    private func loadMore() {
        guard hasMore, !loadingMore, let sid = store.activeSessionId, let oldest = entries.last?.id else { return }
        loadingMore = true
        Task {
            if let page = try? await store.api.mailbox(sid, before: oldest, limit: pageSize) {
                entries.append(contentsOf: page.entries)
                hasMore = page.hasMore
            }
            loadingMore = false
        }
    }
}
