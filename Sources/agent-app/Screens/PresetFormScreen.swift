import SwiftUI

// PresetFormScreen — full-page editor for a NEW user preset.

struct PresetFormScreen: View {
    @Environment(\.appColors) private var p
    @Bindable var store: AppStore
    var showBack: Bool

    @State private var id = ""
    @State private var sysPrompt = ""
    @State private var maxTurns = "25"
    @State private var tools: [ToolInfo] = []
    @State private var selected = Set<String>()
    @State private var saving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                AppField(t("presetId"), text: $id)
                AppField(t("systemPrompt"), text: $sysPrompt, multiline: true)
                AppField(t("maxTurns"), text: $maxTurns, placeholder: "25")
                Text("\(t("tools")) · \(selected.count)")
                    .appFont(.meta).foregroundStyle(p.foreground).padding(.top, AppSpacing.sm)
                ForEach(tools) { tl in
                    Button {
                        if selected.contains(tl.name) {
                            selected.remove(tl.name)
                        } else {
                            selected.insert(tl.name)
                        }
                    } label: {
                        HStack {
                            AppIcon(selected.contains(tl.name) ? AppIcons.success : AppIcons.circle)
                                .foregroundStyle(selected.contains(tl.name) ? p.primary : p.mutedForeground)
                            Text(tl.name).appFont(.micro).foregroundStyle(p.foreground)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(AppSpacing.lg)
        }
        .background(p.background)
        .task {
            (try? await store.api.tools(locale: nil)).map { tools = $0 }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? t("connecting") : t("save")) {
                    let pid = id.trimmingCharacters(in: .whitespaces)
                    guard !pid.isEmpty else { return }
                    Task {
                        saving = true
                        try? await store.api.savePreset(
                            Preset(id: pid, systemPrompt: sysPrompt,
                                   tools: Array(selected), maxTurns: Int(maxTurns) ?? 25)
                        )
                        store.popPage()
                        saving = false
                    }
                }
                .disabled(id.isEmpty || saving)
            }
        }
    }
}
