import SwiftUI

/** Localized capability label. */
func capabilityLabelKey(_ capability: String) -> String {
    switch capability {
    case "image": return "capImage"
    case "video": return "capVideo"
    case "speech": return "capSpeech"
    case "transcription": return "capTranscription"
    case "embedding": return "capEmbedding"
    case "rerank", "reranking": return "capReranking"
    case "realtime": return "capRealtime"
    default: return "capText"
    }
}

/** Capability glyph — the FOUR-client canonical set (flutter `capabilityIcon`,
    webui CapabilityIcon.svelte). */
func capabilityIcon(_ capability: String) -> LucideIconName {
    switch capability {
    case "image": return AppIcons.image
    case "video": return AppIcons.video
    case "speech": return AppIcons.audio
    case "transcription": return AppIcons.mic_vocal
    case "embedding": return AppIcons.scatter
    case "rerank", "reranking": return AppIcons.grip
    case "realtime": return AppIcons.bolt
    default: return AppIcons.chat
    }
}

/** Localized label for an api type tag (falls back to the raw tag). */
func apiTypeLabel(_ tag: String) -> String {
    switch tag {
    case "openai-compatible": return t("apiTypeOpenaiCompat")
    case "openai": return t("apiTypeOpenai")
    case "anthropic": return t("apiTypeAnthropic")
    case "gemini", "google": return t("apiTypeGemini")
    case "deepseek": return t("apiTypeDeepseek")
    case "cohere": return t("apiTypeCohere")
    case "vercel-compatible-gateway": return t("apiTypeGateway")
    default: return tag
    }
}

// ProvidersListScreen — two sections (text providers + the single gateway),
// default-model pick, add/edit entries.

struct ProvidersListScreen: View {
    @Environment(\.appColors) private var p
    @Bindable var store: AppStore
    var showBack: Bool

    @State private var providers: [String: ProviderInfo] = [:]
    @State private var loading = true
    @State private var defaultModel = ""
    @State private var pickDefault = false
    @State private var seenRevision = -1

    var body: some View {
        let allProviders = Array(providers.values).sorted { $0.providerId < $1.providerId }

        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.sm) {
                if showBack {
                    Button { store.popPage() } label: {
                        AppIcon(AppIcons.back).foregroundStyle(p.foreground)
                    }
                }
                Text(t("llmProviders")).appFont(.body).fontWeight(.semibold).foregroundStyle(p.foreground)
                Spacer()
            }
            .padding(.horizontal, AppSpacing.sm)
            .frame(height: 48)
            Divider().overlay(p.border)
            if loading {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        if allProviders.isEmpty {
                            Text(t("noProviders")).appFont(.meta).foregroundStyle(p.mutedForeground)
                                .padding(.horizontal, AppSpacing.lg)
                        }
                        // ONE SECTION PER MODALITY (semantic grouping). Only
                        // TEXT carries the tenant default model.
                        ForEach(modelCapabilities, id: \.self) { cap in
                            HStack {
                                Text(t(capabilityLabelKey(cap)).uppercased())
                                    .appFont(.micro).fontWeight(.semibold)
                                    .foregroundStyle(p.mutedForeground)
                                Spacer()
                                Button {
                                    store.beginProviderDraft(nil, capability: cap)
                                    store.pushPage(.providerForm)
                                } label: {
                                    AppIcon(AppIcons.add).foregroundStyle(p.primary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, AppSpacing.lg)
                            .padding(.top, AppSpacing.sm)

                            if cap == "text" {
                                Button { pickDefault = true } label: {
                                    HStack {
                                        AppIcon(AppIcons.star).foregroundStyle(p.primary).frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(t("defaultModel")).foregroundStyle(p.foreground)
                                            Text(defaultModel.isEmpty ? t("none") : defaultModel)
                                                .appFont(.micro).foregroundStyle(p.mutedForeground).lineLimit(1)
                                        }
                                        Spacer()
                                        AppIcon(AppIcons.chevron_right).appFont(.meta).foregroundStyle(p.mutedForeground)
                                    }
                                    .padding(.horizontal, AppSpacing.lg).padding(.vertical, 10)
                                }
                                .buttonStyle(.plain)
                            }
                            ForEach(allProviders.filter { $0.capability == cap }) { pr in
                                Button {
                                    store.beginProviderDraft(pr)
                                    store.pushPage(.providerForm)
                                } label: {
                                    HStack {
                                        AppIcon(capabilityIcon(cap))
                                            .foregroundStyle(p.primary).frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(pr.providerId).foregroundStyle(p.foreground)
                                            Text("\(apiTypeLabel(pr.apiType)) · \(t("modelsCount", pr.models.count))")
                                                .appFont(.micro).foregroundStyle(p.mutedForeground)
                                        }
                                        Spacer()
                                        AppIcon(AppIcons.chevron_right).appFont(.meta).foregroundStyle(p.mutedForeground)
                                    }
                                    .padding(.horizontal, AppSpacing.lg).padding(.vertical, 10)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .background(p.background)
        .task {
            defaultModel = (try? await store.api.config("default_model")) ?? ""
            (try? await store.api.providers()).map { providers = $0 }
            loading = false
        }
        .onChange(of: store.providersRevision) { _, new in
            if seenRevision != -1 && seenRevision != new {
                Task { (try? await store.api.providers()).map { providers = $0 } }
            }
            seenRevision = new
        }
        .confirmationDialog(t("defaultModel"), isPresented: $pickDefault, titleVisibility: .visible) {
            let refs = allProviders.filter { $0.capability == "text" }.flatMap { pr in
                pr.models.filter { ($0.contextLimit ?? 0) > 0 }.map { "\(pr.providerId)/\($0.id)" }
            }.sorted()
            ForEach(refs, id: \.self) { ref in
                Button(ref) {
                    Task {
                        do {
                            try await store.api.setConfigKey("default_model", ref)
                            defaultModel = ref
                        } catch {
                            showToast(error.localizedDescription)
                        }
                    }
                }
            }
            Button(t("none")) {
                Task {
                    do {
                        try await store.api.setConfigKey("default_model", "")
                        defaultModel = ""
                    } catch {
                        showToast(error.localizedDescription)
                    }
                }
            }
        }
    }
}

// ProviderFormScreen — text provider (id/apiType/baseUrl/key + models).

struct ProviderFormScreen: View {
    @Environment(\.appColors) private var p
    @Bindable var store: AppStore
    var showBack: Bool

    @State private var id = ""
    @State private var url = ""
    @State private var key = ""
    @State private var apiType = "openai-compatible"
    @State private var busy = false

    var body: some View {
        let draft = store.providerDraft
        Group {
            if let d = draft {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.md) {
                        AppField(t("providerIdReq"), text: $id, placeholder: "", disabled: d.isEdit)
                        HStack {
                            AppIcon(capabilityIcon(d.capability)).foregroundStyle(p.mutedForeground).frame(width: 24)
                            Text(t(capabilityLabelKey(d.capability))).appFont(.meta).foregroundStyle(p.mutedForeground)
                            Spacer()
                        }
                        AppSelect(t("apiType"), value: $apiType,
                                  options: store.providerCatalog
                                    .filter { $0.value.contains(d.capability) }
                                    .keys.sorted().map { ($0, apiTypeLabel($0)) })
                        AppField(t("baseUrlReq"), text: $url, placeholder: "https://")
                        AppField(t("apiKeyReq"), text: $key, secure: true)
                        HStack {
                            Text(t("modelsLabel")).appFont(.body).fontWeight(.semibold).foregroundStyle(p.foreground)
                            Spacer()
                            Button {
                                store.pushPage(.providerModels(nil))
                            } label: {
                                AppIcon(AppIcons.add).foregroundStyle(p.primary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, AppSpacing.sm)
                        ForEach(d.models) { m in
                            ModelRowView(m: m) {
                                store.pushPage(.providerModels(m.id))
                            } onRemove: {
                                if var tmp = store.providerDraft {
                                    tmp.models.removeAll { $0.id == m.id }
                                    store.providerDraft = tmp
                                }
                            }
                        }
                    }
                    .padding(AppSpacing.lg)
                }
            } else {
                ProgressView()
            }
        }
        .background(p.background)
        .onAppear {
            Task { await store.refreshProviderCatalog() }
            if let d = store.providerDraft {
                id = d.id; url = d.baseUrl; key = d.apiKey; apiType = d.apiType
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(busy ? t("registering") : (store.providerDraft?.isEdit == true ? t("save") : t("register"))) {
                    Task {
                        guard var d = store.providerDraft else { return }
                        busy = true
                        defer { busy = false }
                        d.id = id.trimmingCharacters(in: .whitespaces)
                        d.apiType = apiType
                        d.baseUrl = url.trimmingCharacters(in: .whitespaces)
                        d.apiKey = key
                        guard !d.id.isEmpty, !d.baseUrl.isEmpty else { return }
                        do {
                            try await store.api.registerProvider(
                                ProviderInfo(providerId: d.id, capability: d.capability,
                                             apiType: d.apiType, baseUrl: d.baseUrl,
                                             apiKey: d.apiKey, models: d.models)
                            )
                            store.bumpProvidersRevision()
                            store.endProviderDraft()
                            store.popPage()
                        } catch {
                            // A bad base URL / key must not fail silently —
                            // flutter/webui toast the error.
                            showToast(error.localizedDescription)
                        }
                    }
                }
                .disabled(id.isEmpty || url.isEmpty || busy)
            }
        }
    }
}

struct ModelRowView: View {
    @Environment(\.appColors) private var p
    let m: ProviderModel
    var onTap: () -> Void
    var onRemove: () -> Void

    var body: some View {
        let isText = m.modelType == "text" || m.modelType.isEmpty
        Button(action: onTap) {
            HStack {
                AppIcon(capabilityIcon(isText ? "text" : m.modelType))
                    .foregroundStyle(p.mutedForeground)
                Text(m.id)
                    .appMonoFont(.meta)
                    .foregroundStyle(p.foreground)
                    .lineLimit(1)
                Spacer()
                Text(isText ? "\(t("capText")) · \(m.contextLimit ?? 0)" : t(capabilityLabelKey(m.modelType)))
                    .appFont(.micro).foregroundStyle(p.mutedForeground)
                Button(action: onRemove) {
                    AppIcon(AppIcons.close).foregroundStyle(p.mutedForeground)
                }
                .buttonStyle(.plain)
            }
        }
        .buttonStyle(.plain)
    }
}

// ProviderModelScreen — single model entry (declared modality) + live test.

struct ProviderModelScreen: View {
    @Environment(\.appColors) private var p
    @Bindable var store: AppStore
    let modelId: String?
    var showBack: Bool

    @State private var mid = ""
    @State private var name = ""
    @State private var ctx = ""
    /// The model's modality IS the draft provider's: read-only here.
    private var capability: String { store.providerDraft?.capability ?? "text" }
    @State private var testing = false
    @State private var testMsg = ""

    private func runTest() {
        guard let d = store.providerDraft, !mid.isEmpty else { return }
        Task {
            testing = true
            testMsg = ""
            if let (ok, result) = try? await store.api.testProvider(
                apiType: d.apiType, baseUrl: d.baseUrl, apiKey: d.apiKey,
                providerId: d.id, model: "\(d.id)/\(mid)", capability: capability
            ) {
                testMsg = ok ? t("testModelOk", result) : (result.isEmpty ? t("testFailed") : result)
            }
            testing = false
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                AppField(t("modelIdReq"), text: $mid, placeholder: "gpt-4o-mini")
                AppField(t("modelName"), text: $name, placeholder: t("none"))
                HStack {
                    AppIcon(capabilityIcon(capability)).foregroundStyle(p.mutedForeground).frame(width: 24)
                    Text(t(capabilityLabelKey(capability))).appFont(.meta).foregroundStyle(p.mutedForeground)
                    Spacer()
                }
                if capability == "text" {
                    AppField(t("contextLengthLabel"), text: $ctx, placeholder: "128000")
                } else {
                    Text(t("nonTextModelHint")).appFont(.micro).foregroundStyle(p.mutedForeground)
                }
                HStack(spacing: AppSpacing.xs) {
                    AppIcon(AppIcons.flask, size: 16)
                        .foregroundStyle(testing ? p.mutedForeground : p.primary)
                    Text(testing ? t("connecting") : t("testModel"))
                        .appFont(.small).foregroundStyle(p.primary)
                }
                .opacity(mid.isEmpty || testing ? 0.5 : 1)
                .onTapGesture { if !mid.isEmpty && !testing { runTest() } }
                if !testMsg.isEmpty {
                    Text(testMsg).appMonoFont(.micro).foregroundStyle(p.mutedForeground)
                }
            }
            .padding(AppSpacing.lg)
        }
        .background(p.background)
        .onAppear {
            // Refresh the capability matrix on open (bundled fallback applies
            // until the server answers).
            Task { await store.refreshProviderCatalog() }
            if let d = store.providerDraft, let mId = modelId,
               let m = d.models.first(where: { $0.id == mId }) {
                mid = m.id; name = m.name
                ctx = (m.contextLimit ?? 0) > 0 ? String(m.contextLimit!) : ""
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(t("save")) {
                    // context_limit required (> 0) for text models only.
                    guard let d = store.providerDraft else { return }
                    let c = capability == "text" ? (Int64(ctx) ?? 0) : 0
                    if capability == "text" && c <= 0 { return }
                    var d2 = d
                    if let mId = modelId {
                        d2.models.removeAll { $0.id == mId }
                    }
                    d2.models.removeAll { $0.id == mid }
                    d2.models.append(ProviderModel(id: mid, name: name.isEmpty ? mid : name,
                                                  contextLimit: Int(c), modelType: capability))
                    store.providerDraft = d2
                    store.popPage()
                }
                .disabled(mid.isEmpty)
            }
        }
    }
}
