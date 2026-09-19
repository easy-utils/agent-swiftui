import SwiftUI

// Root: setup gate + backends manager + the responsive two-tab shell.

enum Phase { case loading, setup, backends, app }

@main
struct AgentApp: App {
    @State private var phase: Phase = .loading
    @State private var store: AppStore?
    // Tri-state theme pref ("system" | "light" | "dark"), follow-system
    // DEFAULT: "system" resolves live against the OS colorScheme.
    @State private var themeMode = Prefs.themeMode
    @Environment(\.colorScheme) private var systemScheme
    @State private var authExpired = false

    private var dark: Bool {
        themeMode == "dark" || (themeMode == "system" && systemScheme == .dark)
    }

    init() {
        // Load the bundled Noto Sans SC / Mono statics before any view builds,
        // so `Font.custom` resolves them instead of falling back to the system
        // face (which would break glyph parity with the other three clients).
        AppFonts.registerBundled()
        I18n.shared.set(resolveLangPref(Prefs.uiLang))
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                (dark ? AppColors.dark : AppColors.light).background.ignoresSafeArea()
                root
                ToastOverlay()
            }
            .appTheme(dark)
            .task { boot() }
            .task(id: authTick) {
                // Poll the global auth flag (any failed RPC sets it) and show the
                // one-tap re-sign-in dialog — flutter auth_gate.dart.
                while !Task.isCancelled {
                    if await MainActor.run(body: { AuthGate.expired }) {
                        await MainActor.run { authExpired = true }
                        return
                    }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
            .confirmationDialog(t("authExpiredTitle"), isPresented: $authExpired, titleVisibility: .visible) {
                Button(t("signInAgain"), role: .destructive) {
                    AuthGate.expired = false
                    Prefs.clearActive()
                    store = nil
                    phase = .setup
                }
            } message: {
                Text(t("authExpiredBody"))
            }
        }
    }

    /// A monotonically increasing counter re-arming the auth watcher.
    private var authTick: Int { 0 }

    @ViewBuilder
    private var root: some View {
        switch phase {
        case .loading:
            LoadingScreen()
        case .setup:
            SetupScreen { base, token, done in
                Task {
                    do {
                        let api = AgentApi(baseUrl: base, token: token)
                        _ = try await api.listSessions() // verify
                        Prefs.save(base, token)
                        Prefs.upsertBackend(BackendCfg(name: backendNameFor(base), baseUrl: base, token: token))
                        await enterApp(api: api)
                        done(nil)
                    } catch {
                        done(error.localizedDescription)
                    }
                }
            }
        case .backends:
            BackendsScreen(
                activeBase: store?.api.baseUrl ?? Prefs.loadBase(),
                onSwitch: { b in
                    Prefs.save(b.baseUrl, b.token)
                    phase = .loading
                    Task {
                        let api = AgentApi(baseUrl: b.baseUrl, token: b.token)
                        await enterApp(api: api)
                    }
                },
                onAdd: {
                    Prefs.clearActive()
                    store = nil
                    phase = .setup
                },
                onBack: { phase = store != nil ? .app : .setup }
            )
        case .app:
            if let store {
                ShellView(store: store, themeMode: $themeMode, onAddUser: {
                    Prefs.clearActive()
                    store = nil
                    phase = .setup
                })
            } else {
                LoadingScreen()
            }
            // no-op placeholder
        }
    }

    private func boot() {
        let base = Prefs.loadBase()
        let token = Prefs.loadToken()
        guard !base.isEmpty, !token.isEmpty else {
            phase = .setup
            return
        }
        Task {
            await enterApp(api: AgentApi(baseUrl: base, token: token))
        }
    }

    private func enterApp(api: AgentApi) async {
        let connScope = scopeOf(api.baseUrl, api.token)
        Prefs.readScope = connScope
        let local = try? LocalStore.open(connScope)
        let s = await MainActor.run { AppStore(api: api, local: local) }
        store = s
        phase = .app
    }
}

// SetupScreen — verified connect.

struct SetupScreen: View {
    @Environment(\.appColors) private var p
    var onConnect: (String, String, @escaping (String?) -> Void) -> Void

    @State private var base = Prefs.loadBase()
    @State private var token = ""
    @State private var showToken = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            VStack(spacing: AppSpacing.xl) {
                Text(t("appTitle")).appFont(.screenTitle).foregroundStyle(p.foreground)
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    AppField(t("gatewayUrl"), text: $base, disabled: busy, placeholder: Prefs.defaultBase)
                    HStack(spacing: AppSpacing.xs) {
                        AppField(t("tokenLabel"), text: $token, secure: !showToken, disabled: busy)
                        Button {
                            showToken.toggle()
                        } label: {
                            AppIcon(showToken ? AppIcons.eye_off : AppIcons.eye)
                                .foregroundStyle(p.mutedForeground)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                }
                if let error {
                    Text(error).appFont(.meta).foregroundStyle(p.destructive)
                }
                Button {
                    busy = true
                    error = nil
                    onConnect(base.trimmingCharacters(in: .whitespaces), token.trimmingCharacters(in: .whitespaces)) { err in
                        busy = false
                        error = err
                    }
                } label: {
                    HStack {
                        if busy { ProgressView().tint(p.onPrimary) }
                        Text(busy ? t("connecting") : t("connect"))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background((base.isEmpty || token.isEmpty) ? p.primary.opacity(0.4) : p.primary,
                                in: RoundedRectangle(cornerRadius: AppRadius.md))
                    .foregroundStyle(p.onPrimary)
                }
                .disabled(base.isEmpty || token.isEmpty || busy)
            }
            .frame(maxWidth: 480)
            .padding(AppSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// BackendsScreen — switch / delete / add.

struct BackendsScreen: View {
    @Environment(\.appColors) private var p
    var activeBase: String
    var onSwitch: (BackendCfg) -> Void
    var onAdd: () -> Void
    var onBack: () -> Void

    @State private var backends = Prefs.backends()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.sm) {
                Button("←", action: onBack).foregroundStyle(p.foreground)
                Text(t("backendsTitle")).appFont(.body).fontWeight(.semibold).foregroundStyle(p.foreground)
                Spacer()
            }
            .padding(AppSpacing.sm)
            .frame(height: 48)
            Divider().overlay(p.border)
            ScrollView {
                VStack(spacing: AppSpacing.sm) {
                    if backends.isEmpty {
                        Text(t("noSavedBackends")).appFont(.meta).foregroundStyle(p.mutedForeground)
                    }
                    ForEach(backends) { b in
                        HStack(spacing: AppSpacing.md) {
                            AppIcon(b.baseUrl == activeBase ? AppIcons.target : AppIcons.server)
                                .foregroundStyle(b.baseUrl == activeBase ? p.primary : p.mutedForeground)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.name.isEmpty ? b.baseUrl : b.name).foregroundStyle(p.foreground)
                                Text(b.baseUrl).appFont(.tiny).foregroundStyle(p.mutedForeground).lineLimit(1)
                            }
                            Spacer()
                            Button {
                                Prefs.removeBackend(b)
                                backends = Prefs.backends()
                            } label: {
                                AppIcon(AppIcons.delete).foregroundStyle(p.mutedForeground)
                            }.buttonStyle(.plain)
                            Button(t("connect")) { onSwitch(b) }
                                .appFont(.meta)
                                .buttonStyle(.bordered)
                        }
                        .padding(AppSpacing.md)
                        .background(p.card, in: RoundedRectangle(cornerRadius: AppRadius.md))
                        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(p.border))
                    }
                    Divider().overlay(p.border)
                    Button(action: onAdd) {
                        HStack {
                            AppIcon(AppIcons.add)
                            Text(t("addBackend"))
                        }
                        .foregroundStyle(p.foreground)
                    }
                }
                .padding(AppSpacing.lg)
            }
        }
    }
}

// Shell — phones get a tab bar (hidden in an open chat), pads a rail,
// per-tab stack panes.

struct ShellView: View {
    @Bindable var store: AppStore
    @Binding var themeMode: String
    var onSwitchBackend: () -> Void = {}
    var onAddUser: () -> Void = {}

    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.appColors) private var p

    var body: some View {
        let compact = hSize == .compact
        let stack = store.currentStack
        let panes = Array(stack.suffix(compact ? 1 : 2).enumerated())
        let hideTabs = compact && store.siderTab == .chat && store.activeSessionId != nil

        VStack(spacing: 0) {
            HStack(spacing: 0) {                if !compact {
                    VStack(spacing: AppSpacing.xs) {
                        ForEach([(SiderTab.chat, AppIcons.chat, "tabChat"), (.config, AppIcons.settings, "tabConfig")], id: \.1) { tb in
                            let active = store.siderTab == tb.0
                            Button {
                                store.switchTab(tb.0)
                            } label: {
                                VStack(spacing: 4) {
                                    AppIcon(tb.1, size: 20)
                                    Text(t(tb.2)).appFont(.micro)
                                }
                                .frame(width: 64, height: 56)
                                .background(active ? p.primary.opacity(0.15) : .clear,
                                            in: RoundedRectangle(cornerRadius: AppRadius.lg))
                                .foregroundStyle(active ? p.primary : p.mutedForeground)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .frame(width: AppLayout.railWidth)
                    .background(p.card)
                    Divider().overlay(p.border)
                }
                HStack(spacing: 0) {
                    ForEach(panes, id: \.element.key) { i, page in
                        pageView(page, isTop: i == panes.count - 1, p: p)
                            .frame(maxWidth: .infinity)
                        if i < panes.count - 1 {
                            Divider().overlay(p.border)
                        }
                    }
                }
            }
            if compact && !hideTabs {
                HStack {
                    ForEach([(SiderTab.chat, AppIcons.chat, "tabChat"), (.config, AppIcons.settings, "tabConfig")], id: \.1) { tb in
                        let active = store.siderTab == tb.0
                        Button {
                            store.switchTab(tb.0)
                        } label: {
                            VStack(spacing: 4) {
                                AppIcon(tb.1, size: 20)
                                Text(t(tb.2)).appFont(.micro)
                            }
                            .frame(maxWidth: .infinity, maxHeight: 60)
                            .foregroundStyle(active ? p.primary : p.mutedForeground)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(p.card)
            }
        }
        .background(p.background)
    }

    @ViewBuilder
    private func pageView(_ page: AppPage, isTop: Bool, p: AppColors.Palette) -> some View {
        switch page {
        case .chatList:
            SessionListScreen(store: store)
        case .chatSession:
            ChatScreen(store: store)
        case .chatOverlay:
            MailboxScreen(store: store)
        case .configRoot:
            ConfigScreen(store: store, themeMode: $themeMode, subId: nil, onAddUser: onAddUser)
        case .configSub(let id):
            ConfigScreen(store: store, themeMode: $themeMode, subId: id, onAddUser: onAddUser)
        case .providersList:
            ProvidersListScreen(store: store, showBack: isTop)
        case .providerForm:
            ProviderFormScreen(store: store, showBack: isTop)
        case .providerModels(let id):
            ProviderModelScreen(store: store, modelId: id, showBack: isTop)
        case .presetFormNew:
            PresetFormScreen(store: store, showBack: isTop)
        }
    }
}
