import SwiftUI

// ConfigScreen — root list + drill-ins (appearance / backends / presets /
// tools / language).

struct ConfigScreen: View {
    @Bindable var store: AppStore
    @Binding var themeMode: String
    var subId: String?
    /// Clears the active connection and returns to the setup form so the user
    /// can sign in as someone else (Flutter's `onAddUser`).
    var onAddUser: (() -> Void)?

    @State private var pickLang = false
    @State private var pickAgentLocale = false
    @State private var pickTheme = false
    @Environment(\.appColors) private var p

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.sm) {
                if subId != nil {
                    Button {
                        store.popPage()
                    } label: {
                        AppIcon(AppIcons.back).foregroundStyle(p.foreground)
                    }
                }
                Text(title).appFont(.body).fontWeight(.semibold).foregroundStyle(p.foreground)
                Spacer()
                if subId == "presets" {
                    Button {
                        store.pushPage(.presetFormNew)
                    } label: {
                        AppIcon(AppIcons.add).foregroundStyle(p.primary)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.sm)
            .frame(height: 48)
            Divider().overlay(p.border)
            switch subId {
            case nil: rootList(p)
            case "appearance": appearance(p)
            case "backends": backendsDetail(p)
            case "presets": PresetsDetail(store: store)
            case "tools": ToolsDetail(store: store)
            default: EmptyView()
            }
        }
        .background(p.background)
        .confirmationDialog(t("language"), isPresented: $pickLang, titleVisibility: .visible) {
            Button(t("followSystem")) { setLangPref("system") }
            Button("中文") { setLangPref("zh") }
            Button("English") { setLangPref("en") }
        }
        // Tri-state theme (follow system / light / dark); follow-system default.
        .confirmationDialog(t("appearance"), isPresented: $pickTheme, titleVisibility: .visible) {
            Button(t("followSystem")) { themeMode = "system"; Prefs.themeMode = "system" }
            Button(t("themeLight")) { themeMode = "light"; Prefs.themeMode = "light" }
            Button(t("themeDark")) { themeMode = "dark"; Prefs.themeMode = "dark" }
        }
        .confirmationDialog(t("agentLocale"), isPresented: $pickAgentLocale, titleVisibility: .visible) {
            Button(t("agentLocaleFollow")) { setAgentLocale("follow") }
            Button("中文") { setAgentLocale("zh") }
            Button("English") { setAgentLocale("en") }
        }
    }

    private var title: String {
        switch subId {
        case "providers": return t("llmProviders")
        case "presets": return t("presets")
        case "appearance": return t("appearance")
        case "tools": return t("tools")
        case "backends": return t("backendsTitle")
        default: return t("tabConfig")
        }
    }

    /// Tri-state language pref: explicit zh/en, else follow the SYSTEM
    /// language (zh for any Chinese locale, en otherwise).
    private func setLangPref(_ v: String) {
        Prefs.uiLang = v
        I18n.shared.set(resolveLangPref(v))
        // A session whose locale is 'follow' inherits the tenant config locale,
        // so keep that in sync with the effective agent locale whenever the UI
        // language changes (otherwise the agent keeps answering in the stale one).
        Task { try? await store.api.setConfigKey("locale", Prefs.effectiveAgentLocale) }
    }

    private func setAgentLocale(_ v: String) {
        Prefs.agentLocale = v
        Task {
            try? await store.api.setConfigKey("locale", Prefs.effectiveAgentLocale)
        }
    }

    @ViewBuilder
    private func rootList(_ p: AppColors.Palette) -> some View {
        List {
            Section(t("appearance")) {
                row(AppIcons.palette, t("appearance")) { store.pushSibling(.configSub("appearance")) }
            }
            Section(t("backendSection")) {
                Button {
                    store.pushSibling(.configSub("backends"))
                } label: {
                    HStack {
                        AppIcon(AppIcons.swap)
                        Text(t("switchBackend")).fontWeight(.semibold)
                        Spacer()
                        AppIcon(AppIcons.chevron_right).appFont(.meta)
                    }
                    .foregroundStyle(p.destructive)
                }
                .buttonStyle(.plain)
            }
            Section(t("llm")) {
                row(AppIcons.server, t("llmProviders")) { store.pushSibling(.providersList) }
                row(AppIcons.sparkles, t("presets")) { store.pushSibling(.configSub("presets")) }
            }
            Section(t("workspace")) {
                row(AppIcons.tools, t("tools")) { store.pushSibling(.configSub("tools")) }
            }
            Section(t("language")) {
                Button { pickLang = true } label: {
                    rowContent(AppIcons.globe, t("language"))
                }
                .buttonStyle(.plain)
                Button { pickAgentLocale = true } label: {
                    rowContent(AppIcons.language, t("agentLocale"))
                }
                .buttonStyle(.plain)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func row(_ icon: LucideIconName, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            rowContent(icon, label)
        }
        .buttonStyle(.plain)
    }

    private func rowContent(_ icon: LucideIconName, _ label: String) -> some View {
        HStack {
            AppIcon(icon).frame(width: 24)
            Text(label).foregroundStyle(p.foreground)
            Spacer()
            AppIcon(AppIcons.chevron_right).appFont(.meta).foregroundStyle(p.mutedForeground)
        }
    }

    @ViewBuilder
    private func appearance(_ p: AppColors.Palette) -> some View {
        let label = switch themeMode {
        case "light": t("themeLight")
        case "dark": t("themeDark")
        default: t("followSystem")
        }
        return Form {
            Button {
                pickTheme = true
            } label: {
                HStack {
                    Text(t("appearance")).foregroundStyle(p.foreground)
                    Spacer()
                    Text(label).appFont(.meta).foregroundStyle(p.mutedForeground)
                    AppIcon(AppIcons.chevron_right).appFont(.meta).foregroundStyle(p.mutedForeground)
                }
            }
            .buttonStyle(.plain)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func backendsDetail(_ p: AppColors.Palette) -> some View {
        @State var backends = Prefs.backends()
        List {
            if backends.isEmpty {
                Text(t("noSavedBackends")).appFont(.meta).foregroundStyle(p.mutedForeground)
            }
            ForEach(backends) { b in
                HStack {
                    AppIcon(b.baseUrl == store.api.baseUrl ? AppIcons.target : AppIcons.server)
                        .foregroundStyle(b.baseUrl == store.api.baseUrl ? p.primary : p.mutedForeground)
                    VStack(alignment: .leading, spacing: 2) {
                        // Prefer the resolved username (GetIdentity).
                        Text(b.username.isEmpty ? (b.name.isEmpty ? b.baseUrl : b.name) : b.username)
                            .foregroundStyle(p.foreground)
                        Text(b.baseUrl).appFont(.tiny).foregroundStyle(p.mutedForeground).lineLimit(1)
                    }
                    Spacer()
                    Button {
                        Prefs.removeBackend(b)
                        backends = Prefs.backends()
                    } label: {
                        AppIcon(AppIcons.delete).foregroundStyle(p.mutedForeground)
                    }
                    .buttonStyle(.plain)
                }
            }
            // Add another user: clears the active connection and returns to the
            // setup form (the Flutter `addBackend` entry).
            Button {
                onAddUser?()
            } label: {
                HStack {
                    AppIcon(AppIcons.add).foregroundStyle(p.primary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("addBackend")).foregroundStyle(p.foreground)
                        Text(t("addBackendHint")).appFont(.tiny).foregroundStyle(p.mutedForeground).lineLimit(1)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
        .scrollContentBackground(.hidden)
    }
}

// PresetsDetail — list + edit + delete.

struct PresetsDetail: View {
    @Environment(\.appColors) private var p
    @Bindable var store: AppStore

    @State private var presets: [Preset] = []
    @State private var loading = true
    @State private var editing: Preset?
    @State private var deleteFor: Preset?
    @State private var editPrompt = ""
    @State private var editTurns = ""
    @State private var defaultPreset = ""
    @State private var pickDefault = false

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    // The tenant DEFAULT preset, chosen inline (writes
                    // `default_preset`, applied to every session created without
                    // an explicit preset) — flutter _defaultPresetTile.
                    Button {
                        pickDefault = true
                    } label: {
                        HStack {
                            AppIcon(AppIcons.star).foregroundStyle(p.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t("defaultPreset")).foregroundStyle(p.foreground)
                                Text(defaultPreset.isEmpty ? t("none") : defaultPreset)
                                    .appFont(.micro).foregroundStyle(p.mutedForeground)
                            }
                            Spacer()
                            AppIcon(AppIcons.chevron_right).appFont(.meta).foregroundStyle(p.mutedForeground)
                        }
                    }
                    .buttonStyle(.plain)
                    if presets.isEmpty {
                        Text(t("noPresets")).appFont(.meta).foregroundStyle(p.mutedForeground)
                    }
                    ForEach(presets) { pr in
                        Button {
                            editing = pr
                            editPrompt = pr.systemPrompt
                            editTurns = String(pr.maxTurns)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(pr.id).foregroundStyle(p.foreground)
                                    if pr.isSystem {
                                        Text("system").appFont(.micro).foregroundStyle(p.mutedForeground)
                                    }
                                }
                                if !pr.systemPrompt.isEmpty {
                                    Text(pr.systemPrompt).appFont(.meta).foregroundStyle(p.mutedForeground).lineLimit(2)
                                }
                                Text("\(t("maxTurns")): \(pr.maxTurns)")
                                    .appFont(.micro).foregroundStyle(p.mutedForeground)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(t("delete"), role: .destructive) { deleteFor = pr }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .task {
            defaultPreset = (try? await store.api.config("default_preset")) ?? ""
            (try? await store.api.presets()).map { presets = $0 }
            loading = false
        }
        .confirmationDialog(t("defaultPreset"), isPresented: $pickDefault, titleVisibility: .visible) {
            Button(t("none")) {
                defaultPreset = ""
                Task { try? await store.api.setConfigKey("default_preset", "") }
            }
            ForEach(presets.map { $0.id }, id: \.self) { id in
                Button(id) {
                    defaultPreset = id
                    Task { try? await store.api.setConfigKey("default_preset", id) }
                }
            }
        }
        .sheet(item: $editing) { pr in
            editSheet(pr, p)
        }
        .confirmationDialog(t("deletePreset"), isPresented: Binding(get: { deleteFor != nil }, set: { if !$0 { deleteFor = nil } }), titleVisibility: .visible) {
            Button(t("delete"), role: .destructive) {
                if let pr = deleteFor {
                    Task {
                        try? await store.api.deletePreset(pr.id)
                        presets = (try? await store.api.presets()) ?? []
                    }
                }
                deleteFor = nil
            }
        }
    }

    private func editSheet(_ pr: Preset, _ p: AppColors.Palette) -> some View {
        NavigationStack {
            Form {
                Section(t("systemPrompt")) {
                    TextEditor(text: $editPrompt).frame(minHeight: 100)
                }
                Section(t("maxTurns")) {
                    #if os(iOS)
                    TextField("", text: $editTurns).keyboardType(.numberPad)
                    #else
                    TextField("", text: $editTurns)
                    #endif
                }
            }
            .navigationTitle(t("editPreset"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(t("cancel")) { editing = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(t("save")) {
                        Task {
                            try? await store.api.savePreset(
                                Preset(id: pr.id, systemPrompt: editPrompt, tools: pr.tools,
                                       maxTurns: Int(editTurns) ?? 25, isSystem: false)
                            )
                            presets = (try? await store.api.presets()) ?? []
                            editing = nil
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// ToolsDetail — grouped tool cards with per-knob config fields.

struct ToolsDetail: View {
    @Environment(\.appColors) private var p
    @Bindable var store: AppStore

    @State private var tools: [ToolInfo] = []
    @State private var config: [String: Any?] = [:]
    @State private var providers: [String: ProviderInfo] = [:]
    @State private var loading = true
    @State private var expanded: String?
    @State private var drafts: [String: String] = [:]

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tools.isEmpty {
                Text(t("noTools")).foregroundStyle(p.mutedForeground)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        ForEach(Array(tools.groupedByCategory().sorted(by: { $0.key < $1.key })), id: \.key) { cat, list in
                            SectionLabel(cat)
                            ForEach(list) { tl in
                                toolCard(tl, p)
                            }
                        }
                    }
                    .padding(AppSpacing.lg)
                }
            }
        }
        .task {
            (try? await store.api.tools(locale: Prefs.agentLocale == "follow" ? nil : Prefs.agentLocale)).map { tools = $0 }
            (try? await store.api.toolConfig()).map { config = $0 }
            (try? await store.api.providers()).map { providers = $0 }
            loading = false
        }
    }

    private func configValues(_ name: String) -> [String: Any?] {
        (config[name] as? [String: Any?]) ?? [:]
    }

    private func isMissing(_ v: Any?) -> Bool {
        if v == nil { return true }
        return String(describing: v!).isEmpty
    }

    private func toolHeader(_ tl: ToolInfo, _ values: [String: Any?], _ p: AppColors.Palette) -> some View {
        let hasConfig = !values.isEmpty
        let requiredMissing = tl.requiredConfig.contains { isMissing(values[$0]) }
        let statusText = requiredMissing ? t("requiredConfig") : (hasConfig ? t("configured") : t("needsConfig"))
        let statusColor: Color = requiredMissing ? p.destructive : (hasConfig ? p.success : p.warning)
        let chevron = expanded == tl.name ? AppIcons.chevron_down : AppIcons.chevron_right
        return HStack {
            Text(tl.name)
                .appMonoFont(.meta)
                .foregroundStyle(p.foreground)
            Spacer()
            if tl.config.isEmpty {
                Text(t("noConfig")).appFont(.micro).foregroundStyle(p.mutedForeground)
            } else {
                Text(statusText).appFont(.micro).foregroundStyle(statusColor)
            }
            AppIcon(chevron)
                .appFont(.micro).foregroundStyle(p.mutedForeground)
        }
    }

    private func toolKnobRow(_ tl: ToolInfo, _ knob: ToolConfigKnob, _ values: [String: Any?], _ p: AppColors.Palette) -> some View {
        let key = tl.name + "." + knob.name
        let placeholder = knob.defaultValue.map { String(describing: $0) } ?? ""
        let label = knob.name + (tl.requiredConfig.contains(knob.name) ? " *" : "")
        let current = (drafts[key] ?? (values[knob.name].flatMap { $0 as? Any }).map { String(describing: $0) } ?? "")
        // Selection-type knobs save IMMEDIATELY on pick (no Save button): model
        // refs, enum and boolean. Only free text gets an explicit Save.
        if knob.isModelRef {
            let refs = providers.values
                .filter { $0.capability == knob.capability }
                .flatMap { pr in pr.models.map { "\(pr.providerId)/\($0.id)" } }
                .sorted()
            return AnyView(knobShell(knob, p) {
                AppSelect(label, value: Binding(
                    get: { current },
                    set: { v in
                        // The owning EXTENSION id is `tool.category`; the tool
                        // name is NOT an extension.
                        Task { try? await store.api.setToolConfigValue(tl.category, knob.name, v) }
                    }
                ), options: [("", t("none"))] + refs.map { ($0, $0) })
            })
        }
        if knob.type == "enum", !knob.enumValues.isEmpty {
            return AnyView(knobShell(knob, p) {
                AppSelect(label, value: Binding(
                    get: { current },
                    set: { v in
                        Task { try? await store.api.setToolConfigValue(tl.category, knob.name, v) }
                    }
                ), options: [("", t("none"))] + knob.enumValues.map { ($0, $0) })
            })
        }
        if knob.type == "boolean" {
            return AnyView(knobShell(knob, p) {
                AppSelect(label, value: Binding(
                    get: { current },
                    set: { v in
                        Task { try? await store.api.setToolConfigValue(tl.category, knob.name, v) }
                    }
                ), options: [("", t("none")), ("true", "true"), ("false", "false")])
            })
        }
        // Free text / number: field + Save on the RIGHT of the same row.
        return AnyView(knobShell(knob, p) {
            HStack(alignment: .bottom, spacing: AppSpacing.sm) {
                AppField(label, text: Binding(
                    get: { current },
                    set: { drafts[key] = $0 }
                ), placeholder: placeholder)
                Button(t("save")) {
                    Task {
                        try? await store.api.setToolConfigValue(tl.category, knob.name, drafts[key] ?? current)
                    }
                }
                .appFont(.meta)
                .buttonStyle(.borderedProminent)
            }
        })
    }

    /// Shared label + description wrapper for one tool knob row.
    @ViewBuilder
    private func knobShell<Content: View>(_ knob: ToolConfigKnob, _ p: AppColors.Palette, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !knob.description.isEmpty {
                Text(knob.description).appFont(.micro).foregroundStyle(p.mutedForeground)
            }
            content()
        }
    }

    @ViewBuilder
    private func toolCard(_ tl: ToolInfo, _ p: AppColors.Palette) -> some View {
        let values = configValues(tl.name)
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Button {
                expanded = expanded == tl.name ? nil : tl.name
            } label: {
                toolHeader(tl, values, p)
            }
            .buttonStyle(.plain)
            if expanded == tl.name {
                if !tl.description.isEmpty {
                    Text(tl.description).appFont(.micro).foregroundStyle(p.mutedForeground)
                }
                ForEach(tl.config, id: \.name) { knob in
                    toolKnobRow(tl, knob, values, p)
                }
            }
        }
        .padding(AppSpacing.md)
        .background(p.card, in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(p.border.opacity(0.6)))
    }
}

extension Array where Element == ToolInfo {
    func groupedByCategory() -> [String: [ToolInfo]] {
        reduce(into: [:]) { acc, tl in
            acc[tl.category.isEmpty ? "other" : tl.category, default: []].append(tl)
        }
    }
}
