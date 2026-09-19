import SwiftUI

// SessionListScreen — port of flutter session_list_page.dart.

struct SessionListScreen: View {
    @Environment(\.appColors) private var p
    @Bindable var store: AppStore

    @State private var searching = false
    @State private var q = ""
    @State private var selectMode = false
    @State private var selected = Set<String>()
    @State private var createOpen = false
    @State private var actionsFor: Session?
    @State private var deleteConfirmFor: String?
    @State private var createName = ""
    /// Subsession tree: ids the user manually expanded (collapsed by default).
    @State private var expanded = Set<String>()

    private var filtered: [Session] {
        guard !q.isEmpty else { return store.sessions }
        return store.sessions.filter {
            $0.id.localizedCaseInsensitiveContains(q) ||
                $0.lastMessagePreview.localizedCaseInsensitiveContains(q) ||
                $0.sessionName.localizedCaseInsensitiveContains(q)
        }
    }

    /// Top-level sessions with subsessions (group == parent id) nested below
    /// when expanded; orphans are promoted so nothing disappears; flat while
    /// searching.
    private var display: [Session] {
        let sessions = filtered
        if searching { return sessions }
        let byId = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var childrenOf: [String: [Session]] = [:]
        var top: [Session] = []
        for s in sessions {
            if !s.group.isEmpty, byId[s.group] != nil {
                childrenOf[s.group, default: []].append(s)
            } else {
                top.append(s)
            }
        }
        var out: [Session] = []
        for s in top {
            out.append(s)
            if let kids = childrenOf[s.id], expanded.contains(s.id) { out.append(contentsOf: kids) }
        }
        return out
    }

    private func childCount(_ id: String) -> Int {
        filtered.filter { $0.group == id }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header(p)
            if !store.sessionError.isEmpty {
                Text("\(t("connectionError")) · \(store.sessionError)")
                    .appFont(.meta)
                    .foregroundStyle(p.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.vertical, AppSpacing.sm)
                    .background(p.destructive.opacity(0.1))
            }
            SectionLabel(t("recent"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppSpacing.lg)
                .padding(.vertical, AppSpacing.xs)
            if display.isEmpty {
                Spacer()
                Text(t("noSessions")).appFont(.meta).foregroundStyle(p.mutedForeground)
                Spacer()
            } else {
                // Flutter's ListView: rows own their padding/background, so no
                // list chrome (insets, separators, row backgrounds).
                List {
                    ForEach(display) { s in
                        let isChild = !searching && !s.group.isEmpty && filtered.contains { $0.id == s.group }
                        let kids = (isChild || searching) ? 0 : childCount(s.id)
                        SessionRow(
                            session: s,
                            active: s.id == store.activeSessionId,
                            unread: store.isUnread(s),
                            unreadCount: store.unreadCountFor(s),
                            selectMode: selectMode,
                            selected: selected.contains(s.id),
                            childCount: kids,
                            expanded: expanded.contains(s.id),
                            isChild: isChild,
                            onToggleExpand: kids > 0
                                ? { if expanded.contains(s.id) { expanded.remove(s.id) } else { expanded.insert(s.id) } }
                                : nil
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        // Platform-native swipe-to-delete (accepted divergence:
                        // the List already behaves natively; swipe goes through
                        // the SAME confirm dialog as the overflow menu).
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !selectMode {
                                Button(role: .destructive) {
                                    deleteConfirmFor = s.id
                                } label: {
                                    Label(t("delete"), systemImage: "trash")
                                }
                            }
                        }
                        .onTapGesture {
                            if selectMode {
                                if selected.contains(s.id) { selected.remove(s.id) } else { selected.insert(s.id) }
                            } else {
                                store.pickSession(s.id)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // Platform-native pull-to-refresh (the other clients have it:
                // flutter RefreshIndicator / webui custom pull).
                .refreshable { await store.refreshSessions() }
            }
        }
        .background(p.background)
        .task { await store.refreshSessions() }
        .sheet(isPresented: $createOpen) {
            inputSheet(
                title: t("newSession"),
                text: $createName,
                confirm: t("create")
            ) { name in
                guard !name.isEmpty else { return }
                Task {
                    _ = try? await store.api.createSession(["name": name])
                    await store.refreshSessions()
                }
            }
        }
        .confirmationDialog(
            deleteConfirmFor != nil ? t("deleteSession") : "",
            isPresented: Binding(get: { deleteConfirmFor != nil }, set: { if !$0 { deleteConfirmFor = nil } }),
            titleVisibility: .visible
        ) {
            Button(t("delete"), role: .destructive) {
                if let id = deleteConfirmFor {
                    Task { await store.deleteSession(id) }
                }
                deleteConfirmFor = nil
            }
        } message: {
            let label = deleteConfirmFor.flatMap { id in
                store.sessions.first { $0.id == id }
            }?.sessionName ?? deleteConfirmFor ?? ""
            Text(t("deleteSessionBody", label))
        }
        .confirmationDialog(
            actionsFor?.sessionName ?? "",
            isPresented: Binding(get: { actionsFor != nil }, set: { if !$0 { actionsFor = nil } }),
            titleVisibility: .visible
        ) {
            if let s = actionsFor {
                if store.isUnread(s) {
                    // label-only, matching the other three clients' action sheets
                    Button(t("markRead")) { store.markSessionRead(s.id) }
                }
                Button(t("deleteSession"), role: .destructive) { deleteConfirmFor = s.id }
            }
        }
    }

    @ViewBuilder
    private func header(_ p: AppColors.Palette) -> some View {
        HStack(spacing: AppSpacing.sm) {
            if selectMode {
                Button {
                    selectMode = false
                    selected = []
                } label: {
                    AppIcon(AppIcons.close).foregroundStyle(p.foreground)
                }
                Text(t("selectedCount", selected.count)).foregroundStyle(p.foreground)
                Spacer()
                Button {
                    selected = selected.count == display.count ? [] : Set(display.map { $0.id })
                } label: {
                    AppIcon(AppIcons.list).foregroundStyle(p.foreground)
                }
                Button {
                    guard !selected.isEmpty else { return }
                    let ids = Array(selected)
                    Task {
                        _ = await store.deleteSessions(ids)
                        selectMode = false
                        selected = []
                    }
                } label: {
                    AppIcon(AppIcons.delete)
                        .foregroundStyle(selected.isEmpty ? p.mutedForeground : p.destructive)
                }
            } else if searching {
                Button {
                    q = ""
                    searching = false
                } label: {
                    AppIcon(AppIcons.back).foregroundStyle(p.foreground)
                }
                TextField(t("searchHint"), text: $q)
                    .textFieldStyle(.plain)
                    .foregroundStyle(p.foreground)
            } else {
                Text(t("tabChat")).appFont(.body).fontWeight(.semibold).foregroundStyle(p.foreground)
                Spacer()
                Button {
                    searching = true
                } label: {
                    AppIcon(AppIcons.search).foregroundStyle(p.primary)
                }
                Button {
                    selectMode = true
                } label: {
                    AppIcon(AppIcons.list).foregroundStyle(p.primary)
                }
                Button {
                    createName = ""
                    createOpen = true
                } label: {
                    AppIcon(AppIcons.add).foregroundStyle(p.primary)
                }
            }
        }
        .padding(.horizontal, AppSpacing.sm)
        .frame(height: 48)
        Divider().overlay(p.border)
    }

    private func inputSheet(title: String, text: Binding<String>, confirm: String, onConfirm: @escaping (String) -> Void) -> some View {
        return VStack(spacing: AppSpacing.md) {
            Text(title).appFont(.body).fontWeight(.semibold).foregroundStyle(p.foreground)
            TextField("", text: text)
                .padding(10)
                .background(p.muted, in: RoundedRectangle(cornerRadius: AppRadius.md))
                .foregroundStyle(p.foreground)
            HStack {
                Button(t("cancel"), role: .cancel) {}
                Spacer()
                Button(confirm) {
                    onConfirm(text.wrappedValue.trimmingCharacters(in: .whitespaces))
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(AppSpacing.lg)
        .presentationDetents([.height(200)])
    }
}

struct SessionRow: View {
    @Environment(\.appColors) private var p
    let session: Session
    let active: Bool
    let unread: Bool
    let unreadCount: Int
    let selectMode: Bool
    let selected: Bool
    var childCount: Int = 0
    var expanded: Bool = false
    var isChild: Bool = false
    var onToggleExpand: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            if isChild {
                // 12 indent + 10 connector + 4 gap, matching Flutter.
                Spacer().frame(width: AppSpacing.md)
                Rectangle()
                    .fill(p.mutedForeground.opacity(0.35))
                    .frame(width: 2, height: 34)
                    .frame(width: 10)
                Spacer().frame(width: AppSpacing.sm - 4)
            }
            if selectMode {
                AppIcon(selected ? AppIcons.success : AppIcons.circle)
                    .font(.system(size: 24))
                    .foregroundStyle(selected ? p.primary : p.mutedForeground)
            } else {
                ChatAvatar(seed: session.id, size: 40)
            }
            Spacer().frame(width: AppSpacing.md)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Text(session.sessionName)
                        .appFont(.meta).fontWeight(.semibold)
                        .foregroundStyle(active ? p.primary : p.foreground)
                        .lineLimit(1)
                        .layoutPriority(1)
                    // A subsession (group == its parent's name) is marked.
                    if !session.group.isEmpty && !isChild {
                        Text(t("subsessionBadge"))
                            .appFont(.tiny)
                            .foregroundStyle(p.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(p.primary.opacity(0.14), in: Capsule())
                            .padding(.leading, AppSpacing.xs)
                    }
                    if childCount > 0 {
                        Button {
                            onToggleExpand?()
                        } label: {
                            HStack(spacing: 1) {
                                Text(t("subsessionCount", childCount)).appFont(.tiny)
                                AppIcon(expanded ? AppIcons.chevron_up : AppIcons.chevron_down, size: 13)
                            }
                            .foregroundStyle(p.mutedForeground)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(p.mutedForeground.opacity(0.14), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, AppSpacing.xs)
                    }
                    Spacer(minLength: 0)
                    // FIXED-width right-aligned timestamp slot.
                    Text(Self.fmt(session.lastMessageAt.isEmpty ? session.updatedAt : session.lastMessageAt))
                        .appFont(.micro)
                        .foregroundStyle(p.mutedForeground)
                        .lineLimit(1)
                        .frame(width: 52, alignment: .trailing)
                }
                HStack(spacing: 0) {
                    Text(session.lastMessagePreview.isEmpty ? session.id : session.lastMessagePreview)
                        .appFont(.micro)
                        .foregroundStyle(p.mutedForeground)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if unread && !active && unreadCount > 0 {
                        Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                            .appFont(.micro).fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(height: 18)
                            .background(p.destructive, in: Capsule())
                            .padding(.leading, AppSpacing.xs)
                    }
                }
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(selected ? p.primary.opacity(0.14) : (active ? p.primary.opacity(0.10) : .clear))
        .contentShape(Rectangle())
    }

    /// WeChat-style relative label — identical to flutter `wechatTime`.
    static func fmt(_ iso: String) -> String {
        guard !iso.isEmpty, let d = ISO8601DateFormatter().date(from: iso) else { return "" }
        let mins = Int(Date().timeIntervalSince(d) / 60)
        if mins < 1 { return t("timeJustNow") }
        if mins < 60 { return t("timeMinAgo", mins) }
        if mins < 60 * 24 { return t("timeHour", mins / 60) }
        if mins < 60 * 24 * 7 { return t("timeDay", mins / (60 * 24)) }
        let comps = Calendar.current.dateComponents([.month, .day], from: d)
        return "\(comps.month ?? 0)/\(comps.day ?? 0)"
    }
}
