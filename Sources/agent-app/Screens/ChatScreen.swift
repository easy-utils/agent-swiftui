import SwiftUI
import PhotosUI

// ChatScreen — port of flutter screens/chat.dart (top bar, streaming bubbles,
// tool cards, composer with attachments/voice, settings + menu dialogs).

struct ChatScreen: View {
    @Environment(\.appColors) private var p
    @Bindable var store: AppStore

    @State private var text = ""
    @State private var attachments: [UploadedFile] = []
    @State private var recording = false
    @State private var attachSheet = false
    @State private var settingsOpen = false
    @State private var infoOpen = false
    @State private var voiceMode = false
    @State private var dragging = false
    @State private var forkOpen = false
    @State private var deleteConfirm = false
    @State private var forkName = ""
    @State private var filePickerMime: String?
    /// Follow-bottom: armed while the newest message is in view; scrolling up
    /// disarms (streaming must not fight the reader), returning to the bottom
    /// re-arms (flutter `_followBottom`).
    @State private var followBottom = true
    /// Debounced draft-text persistence (webui: 300ms).
    @State private var draftSaveTask: Task<Void, Never>?
    /// Camera/gallery pick (flutter `_pickImage`): PhotosPicker is the only
    /// camera-capable picker SwiftUI exposes on iOS without an extra plugin.
    @State private var cameraItem: PhotosPickerItem?
    @State private var controllers: [String: MessagesController] = [:]
    @State private var providers: [String: ProviderInfo] = [:]
    @State private var presets: [Preset] = []

    private var sid: String { store.activeSessionId ?? "" }

    private var controller: MessagesController? {
        let id = sid
        guard !id.isEmpty else { return nil }
        if let c = controllers[id] { return c }
        let c = MessagesController(api: store.api, getSessionId: { id }, local: store.local) {
            t("sendFailed", $0.localizedDescription)
        }
        // Bind to exactly ONE live controller: every other visited session's
        // controller is disposed here. Each one holds a live stream + a 30s
        // idle probe whose captured getSessionId would keep RECONNECTING the
        // old session forever if it stayed in the dictionary (N visited
        // sessions = N permanent SSE connections).
        let stale = controllers.values.filter { $0 !== c }
        controllers = [id: c]
        for old in stale { old.dispose() }
        c.init_()
        if let d = store.chatDrafts[id] {
            text = d.text
            attachments = d.attachments
        } else {
            // No draft: clear the composer, or the previous session's text
            // bleeds into this one.
            text = ""
            attachments = []
        }
        followBottom = true
        return c
    }

    var body: some View {
        if let ctrl = controller, !sid.isEmpty {
            VStack(spacing: 0) {
                topBar(ctrl, p)
                Divider().overlay(p.border.opacity(0.5))
                messageList(ctrl, p)
                composer(ctrl, p)
            }
            .background(p.background)
            .fileImporter(
                isPresented: Binding(
                    get: { filePickerMime != nil && filePickerMime != "camera" },
                    set: { if !$0 { filePickerMime = nil } }
                ),
                allowedContentTypes: filePickerMime == "image/*" ? [.image] : [.item],
                allowsMultipleSelection: true
            ) { result in
                guard case .success(let urls) = result else { return }
                upload(urls: urls)
            }
            .photosPicker(isPresented: Binding(get: { filePickerMime == "camera" }, set: { if !$0 { filePickerMime = nil } }),
                          selection: $cameraItem, matching: .images)
            .sheet(isPresented: $settingsOpen) {
                SessionSettingsSheet(store: store, sid: sid, providers: providers, presets: presets)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $infoOpen) {
                SessionInfoSheet(session: store.activeSession, sid: sid) {
                    infoOpen = false
                    settingsOpen = true
                }
                .presentationDetents([.height(340)])
            }
            .sheet(isPresented: $forkOpen) {
                forkSheet(p)
            }
            .confirmationDialog(t("deleteSession"), isPresented: $deleteConfirm, titleVisibility: .visible) {
                Button(t("delete"), role: .destructive) {
                    Task { await store.deleteSession(sid) }
                }
            } message: {
                let s = store.activeSession
                let label = (s != nil && !s!.org.isEmpty) ? "\(s!.org)/\(s!.repo)/\(s!.branch)" : sid
                Text(t("deleteSessionBody", label))
            }
            .onChange(of: text) { _, new in
                // Persist the typed draft DEBOUNCED so a session switch (or
                // quitting) never loses it — attachments already were.
                draftSaveTask?.cancel()
                let target = sid
                guard !target.isEmpty else { return }
                draftSaveTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    store.saveDraftText(target, new)
                }
            }
            .task(id: sid) {
                (try? await store.api.providers()).map { providers = $0 }
                (try? await store.api.presets()).map { presets = $0 }
            }
            .onChange(of: cameraItem) { _, item in
                guard let item else { return }
                cameraItem = nil
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                    upload(files: [PickedFile(name: "photo-\(Int(Date().timeIntervalSince1970)).jpg",
                                              mime: "image/jpeg", bytes: data)])
                }
            }
        } else {
            Text(t("noSessions")).foregroundStyle(p.mutedForeground)
        }
    }

    private func topBar(_ ctrl: MessagesController, _ p: AppColors.Palette) -> some View {
        let ctx = (store.activeSession?.lastInputTokens ?? 0) + (store.activeSession?.lastOutputTokens ?? 0)
        // flutter `_topBar`: left cluster, session-NAME pill centered, overflow
        // menu on the right (anchored popup, not a sheet).
        return ZStack {
            HStack(spacing: AppSpacing.xs) {
                Button {
                    store.popPage()
                } label: {
                    AppIcon(AppIcons.back)
                        .font(.system(size: 20))
                        .foregroundStyle(p.foreground)
                }
                Circle()
                    .fill(ctrl.sending ? p.warning : p.success)
                    .frame(width: 8, height: 8)
                if ctx > 0 {
                    Text(Self.fmtContext(ctx))
                        .appFont(.micro).monospacedDigit()
                        .foregroundStyle(p.mutedForeground)
                }
                Spacer()
            }
            .padding(.horizontal, AppSpacing.xs)

            Button {
                infoOpen = true
            } label: {
                Text(sid)
                    .appFont(.meta).fontWeight(.semibold)
                    .lineLimit(1)
                    .frame(minWidth: 96, maxWidth: 160)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, 4)
                    .background(p.primary.opacity(0.14), in: Capsule())
                    .foregroundStyle(p.primary)
            }

            HStack {
                Spacer()
                Menu {
                    Button(t("compactHistory")) {
                        Task {
                            do {
                                let created = try await store.api.compact(sid)
                                showToast(t(created ? "historyCompacted" : "nothingToCompact"))
                            } catch {
                                showToast(error.localizedDescription)
                            }
                        }
                    }
                    Button(t("mailbox")) { store.pushPage(.chatOverlay) }
                    Divider()
                    Button(t("fork")) { forkName = ""; forkOpen = true }
                    Button(t("deleteSession"), role: .destructive) { deleteConfirm = true }
                } label: {
                    AppIcon(AppIcons.more_vertical).font(.system(size: 20)).foregroundStyle(p.foreground)
                }
            }
            .padding(.horizontal, AppSpacing.xs)
        }
        .frame(height: 48)
        .overlay(alignment: .bottom) {
            Divider().overlay(p.border.opacity(0.5))
        }
    }

    /// Content-offset anchors inside the scroll space (named "chatScroll"):
    /// top reports 0 when pinned at the very top (load-earlier trigger);
    /// bottom reports the content end's offset in the VISIBLE frame, so
    /// "within 80pt of the viewport bottom" = still following the newest.
    private struct TopOffsetKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }
    private struct BottomOffsetKey: PreferenceKey {
        static var defaultValue: CGFloat = .infinity
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = min(value, nextValue())
        }
    }

    private func messageList(_ ctrl: MessagesController, _ p: AppColors.Palette) -> some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        GeometryReader { g in
                            Color.clear.preference(
                                key: TopOffsetKey.self,
                                value: g.frame(in: .named("chatScroll")).minY
                            )
                        }
                        .frame(height: 0)
                        if ctrl.loading && ctrl.messages.isEmpty {
                            ProgressView().padding()
                        }
                        if ctrl.hasMore {
                            Button(ctrl.loading ? t("loading") : t("loadEarlier")) {
                                Task { await ctrl.loadMore() }
                            }
                            .buttonStyle(.plain)
                            .appFont(.small)
                            .foregroundStyle(p.primary)
                            .padding(.vertical, 4)
                        }
                        ForEach(ctrl.sorted) { msg in
                            MessageBubble(msg: msg, api: store.api) {
                                Task { await ctrl.revert(msg.id) }
                            } onResend: { newText in
                                Task { await ctrl.resendFrom(msg, newText) }
                            }
                            .id(msg.id)
                        }
                        GeometryReader { g in
                            Color.clear.preference(
                                key: BottomOffsetKey.self,
                                value: g.frame(in: .named("chatScroll")).minY
                            )
                        }
                        .frame(height: 0)
                    }
                    .padding(AppSpacing.md)
                }
                .coordinateSpace(name: "chatScroll")
                .onPreferenceChange(TopOffsetKey.self) { y in
                    // Auto-load older history near the top (flutter `_onScroll`
                    // pixels < 80; the load guard prevents a storm).
                    if y < 60, ctrl.hasMore, !ctrl.loading {
                        Task { await ctrl.loadMore() }
                    }
                }
                .onPreferenceChange(BottomOffsetKey.self) { y in
                    // Only the user's own scroll position changes the follow
                    // intent: away from the bottom disarms, back at the bottom
                    // re-arms. Programmatic scrolls land at the bottom and
                    // keep it armed.
                    followBottom = y <= geo.size.height + 80
                }
                .onChange(of: ctrl.revision) {
                    if followBottom, let last = ctrl.sorted.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    if let last = ctrl.sorted.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func composer(_ ctrl: MessagesController, _ p: AppColors.Palette) -> some View {
        VStack(spacing: AppSpacing.xs) {
            if !attachments.isEmpty {
                // flutter: three square tiles per line.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 56, maximum: 72), spacing: AppSpacing.xs)],
                          alignment: .leading, spacing: AppSpacing.xs) {
                    ForEach(Array(attachments.enumerated()), id: \.offset) { _, a in
                        attachmentTile(a, p)
                    }
                }
                .padding(.horizontal, AppSpacing.sm)
            }
            // All three slots share one vertical center; the left and right
            // slots are both 42pt (the field's min height) for symmetry.
            HStack(alignment: .center, spacing: AppSpacing.sm) {
                // Mic/keyboard mode toggle (flutter voice-mode switch).
                Button {
                    voiceMode.toggle()
                    if !voiceMode, recording { cancelRecording() }
                } label: {
                    ZStack {
                        Circle().stroke(p.border, lineWidth: 1.2).frame(width: 42, height: 42)
                        AppIcon(voiceMode ? AppIcons.keyboard : AppIcons.mic)
                            .font(.system(size: 22))
                            .foregroundStyle(p.mutedForeground)
                    }
                    .frame(width: 42, height: 42)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                if voiceMode {
                    // Hold to talk: press-and-hold records, release uploads.
                    Rectangle()
                        .fill(recording ? p.destructive.opacity(0.12) : p.muted)
                        .frame(minHeight: 42)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                        .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                            .stroke(recording ? p.destructive : p.border.opacity(0.6)))
                        .overlay(
                            HStack(spacing: 6) {
                                Text(recording
                                      ? "\(t("releaseToSend")) · \(Self.fmtDuration(voiceElapsed))"
                                      : t("holdToTalk"))
                                    .appFont(.small)
                                    .foregroundStyle(recording ? p.foreground : p.mutedForeground)
                            }
                        )
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in
                                    if !recording { startVoice() }
                                }
                                .onEnded { _ in
                                    if recording { stopVoice() }
                                }
                        )
                } else {
                    TextField(attachments.isEmpty ? t("typeMessage") : "", text: $text, axis: .vertical)
                        .lineLimit(1...6)
                        .appFont(.body)
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, 11)
                        .frame(minHeight: 42)
                        .background(p.muted, in: RoundedRectangle(cornerRadius: AppRadius.md))
                        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(p.border.opacity(0.6)))
                        .foregroundStyle(p.foreground)
                        .onSubmit(send)
                }
                Group {
                    if ctrl.sending {
                        composerCircle(icon: AppIcons.stop, color: p.destructive) { ctrl.stop() }
                    } else if sending {
                        ZStack {
                            Circle().fill(p.card).frame(width: 42, height: 42)
                            Circle().stroke(p.primary, lineWidth: 1.2).frame(width: 42, height: 42)
                            ProgressView().tint(p.primary).controlSize(.small)
                        }
                    } else if canSend {
                        composerCircle(icon: AppIcons.send, color: p.primary, action: send)
                    } else {
                        composerCircle(icon: AppIcons.add, color: p.mutedForeground) { attachSheet = true }
                    }
                }
            }
        }
        .padding(.leading, AppSpacing.md)
        .padding(.trailing, AppSpacing.md)
        .padding(.top, AppSpacing.xs)
        .padding(.bottom, AppSpacing.xs)
        .background(p.card)
        .overlay(alignment: .top) { Divider().overlay(p.border.opacity(0.5)) }
        .onDrop(of: [.fileURL, .image], isTargeted: $dragging) { providers in
            handleDrop(providers)
        }
#if os(macOS)
        .onPasteCommand(of: [.image, .fileURL]) { providers in
            for provider in providers {
                if provider.canLoadObject(ofClass: PlatformImage.self) {
                    _ = provider.loadObject(ofClass: PlatformImage.self) { obj, _ in
                        guard let img = obj as? PlatformImage,
                              let data = img.pngDataCompat else { return }
                        Task { @MainActor in
                            upload(files: [PickedFile(name: "pasted.png", mime: "image/png", bytes: data)])
                        }
                    }
                } else if provider.canLoadObject(ofClass: URL.self) {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url, let data = try? Data(contentsOf: url) else { return }
                        Task { @MainActor in
                            upload(files: [PickedFile(name: url.lastPathComponent,
                                                      mime: mimeOfName(url.lastPathComponent),
                                                      bytes: data, localPath: url.path)])
                        }
                    }
                }
            }
        }
#endif
        .overlay {
            if dragging {
                dropOverlay(p)
            }
        }
        // Attach picker rows render in the sheet below (native dialogs cannot
        // show a glyph); the sheet is the ONLY entry (composer add button).
        .sheet(isPresented: $attachSheet) {
            attachSheetView(p)
                .presentationDetents([.height(230)])
        }
    }

    /// Attach bottom sheet — same four rows as the Flutter / Compose / WebUI
    /// clients (camera · image · file · cancel), rendered with Lucide glyphs.
    @ViewBuilder
    private func attachSheetView(_ p: AppColors.Palette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule().fill(p.mutedForeground.opacity(0.3))
                .frame(width: 40, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            attachRow(AppIcons.camera, t("takePhoto")) { attachSheet = false; filePickerMime = "camera" }
            attachRow(AppIcons.image, t("chooseImage")) { attachSheet = false; filePickerMime = "image/*" }
            attachRow(AppIcons.attach, t("chooseFile")) { attachSheet = false; filePickerMime = "*/*" }
        }
        .padding(.bottom, AppSpacing.md)
        .background(p.card)
    }

    @ViewBuilder
    private func attachRow(_ icon: LucideIconName, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.md) {
                AppIcon(icon, size: 22)
                Text(label)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    /// The composer's morphing 40pt round button (flutter `IconButton.filled`).
    @ViewBuilder
    /// The composer's round action slot: a WHITE circle (card fill) with a
    /// hairline outline and glyph in [color] (blue send / red stop / muted
    /// attach) — never a solid colored fill. 42pt, matching the left slot.
    private func composerCircle(icon: LucideIconName, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(p.card).frame(width: 42, height: 42)
                Circle().stroke(color, lineWidth: 1.2).frame(width: 42, height: 42)
                AppIcon(icon, size: 20).foregroundStyle(color)
            }
        }
        .buttonStyle(.plain)
    }

    /// A uniform square attachment tile with an upload-state corner badge
    /// (spinner / retry / remove), matching the flutter composer tiles.
    @ViewBuilder
    private func attachmentTile(_ a: UploadedFile, _ p: AppColors.Palette) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = localThumbnail(a) {
                    Image(platformImage: img).resizable().scaledToFill()
                } else {
                    Rectangle().fill(p.muted)
                        .overlay(
                            AppIcon(a.mime?.hasPrefix("audio/") == true ? AppIcons.music
                                    : a.mime?.hasPrefix("video/") == true ? AppIcons.film : AppIcons.file)
                                .foregroundStyle(p.mutedForeground)
                        )
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            Button {
                if a.hasError { retryUpload(a) } else {
                    attachments.removeAll { $0.code == a.code }
                    store.saveDraftAttachments(sid, attachments)
                }
            } label: {
                AppIcon(a.hasError ? AppIcons.refresh : AppIcons.close)
                    .appFont(.tiny)
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(a.hasError ? p.destructive : Color.black.opacity(0.55)))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
        }
    }

    private func localThumbnail(_ a: UploadedFile) -> Any? {
        guard a.mime?.hasPrefix("image/") == true, !a.localPath.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: a.localPath)) else { return nil }
        return platformImage(data)
    }

    private func retryUpload(_ a: UploadedFile) {
        guard !a.localPath.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: a.localPath)) else { return }
        attachments.removeAll { $0.code == a.code }
        upload(files: [PickedFile(name: a.name ?? "file", mime: a.mime ?? mimeOfName(a.name ?? ""),
                                  bytes: data, localPath: a.localPath)])
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    Task { @MainActor in showToast(t("folderNotAllowed")) }
                    return
                }
                guard let data = try? Data(contentsOf: url) else { return }
                Task { @MainActor in
                    upload(files: [PickedFile(name: url.lastPathComponent, mime: mimeOfName(url.lastPathComponent),
                                              bytes: data, localPath: url.path)])
                }
            }
        }
        return true
    }

    private func dropOverlay(_ p: AppColors.Palette) -> some View {
        ZStack {
            p.primary.opacity(0.08)
            VStack(spacing: AppSpacing.sm) {
                AppIcon(AppIcons.download).appFont(.screenTitle).foregroundStyle(p.primary)
                Text(t("dropToAttach")).foregroundStyle(p.foreground)
            }
            .padding(AppSpacing.md)
            .background(p.card, in: RoundedRectangle(cornerRadius: AppRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.lg).stroke(p.primary, lineWidth: 1.5))
        }
        .allowsHitTesting(false)
    }

    private func cancelRecording() {
        recording = false
        voiceTicker?.cancel()
        voiceTicker = nil
        recorder.cancel()
    }

    /// Hold-to-talk press: start capture and tick the elapsed label.
    private func startVoice() {
        recording = true
        voiceElapsed = 0
        Task { _ = await recorder.start() }
        voiceTicker?.cancel()
        voiceTicker = Task {
            while !Task.isCancelled, recording {
                try? await Task.sleep(nanoseconds: 200_000_000)
                await MainActor.run { if recording { voiceElapsed += 200 } }
            }
        }
    }

    private func stopVoice() {
        recording = false
        voiceTicker?.cancel()
        voiceTicker = nil
        Task {
            if let f = await recorder.stop() { upload(files: [f]) }
            else { showToast(t("voiceTooShort")) }
        }
    }

    @State private var recorder = VoiceRecorder()
    /// Hold-to-talk elapsed milliseconds (flutter ticks a 200ms Timer).
    @State private var voiceElapsed = 0
    @State private var voiceTicker: Task<Void, Never>?

    static func fmtDuration(_ ms: Int) -> String {
        let total = ms / 1000
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            attachments.contains { !$0.code.hasPrefix("tmp-") }
    }

    private func send() {
        guard let ctrl = controller else { return }
        let files = attachments.filter { !$0.code.hasPrefix("tmp-") }
        let body = text
        text = ""
        attachments = []
        store.clearDraft(sid)
        // A freshly sent message always lands at the bottom.
        followBottom = true
        Task { await ctrl.send(body, attachments: files) }
    }

    private func upload(urls: [URL]) {
        let files = urls.compactMap { url -> PickedFile? in
            guard url.startAccessingSecurityScopedResource() else { return nil }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let bytes = try? Data(contentsOf: url) else { return nil }
            let mime = url.pathExtension.lowercased().isEmpty ? "application/octet-stream" : mimeTypeFor(url.pathExtension)
            return PickedFile(name: url.lastPathComponent, mime: mime, bytes: bytes, localPath: url.path)
        }
        upload(files: files)
    }

    private func upload(files: [PickedFile]) {
        for f in files {
            let tmp = UploadedFile(
                code: "tmp-\(Int(Date().timeIntervalSince1970 * 1000))-\(f.name)",
                name: f.name, mime: f.mime, size: f.bytes.count, uploadState: .uploading
            )
            attachments.append(tmp)
            Task {
                do {
                    let done = try await store.api.uploadFile(name: f.name, mime: f.mime, bytes: f.bytes)
                    if let i = attachments.firstIndex(where: { $0.code == tmp.code }) {
                        attachments[i] = done
                    }
                } catch {
                    if let i = attachments.firstIndex(where: { $0.code == tmp.code }) {
                        attachments[i].uploadState = .error
                        attachments[i].error = error.localizedDescription
                    }
                }
                store.saveDraftAttachments(sid, attachments)
            }
        }
    }

    private func mimeTypeFor(_ ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "mp4": return "video/mp4"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }

    private func forkSheet(_ p: AppColors.Palette) -> some View {
        VStack(spacing: AppSpacing.md) {
            Text(t("fork")).appFont(.body).fontWeight(.semibold).foregroundStyle(p.foreground)
            TextField("", text: $forkName)
                .padding(10)
                .background(p.muted, in: RoundedRectangle(cornerRadius: AppRadius.md))
                .foregroundStyle(p.foreground)
            HStack {
                Button(t("cancel"), role: .cancel) {}
                Spacer()
                Button(t("create")) {
                    let name = forkName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    Task { _ = await store.forkSession(name) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(AppSpacing.lg)
        .presentationDetents([.height(190)])
    }

    static func fmtContext(_ tokens: Int) -> String {
        if tokens <= 0 { return "" }
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 10_000 { return "\(tokens / 1000)k" }
        return String(format: "%.1fk", Double(tokens) / 1000)
    }
}

// SessionInfoSheet — the centered session-info card of flutter's
// _SessionInfoDialog: EVERY field is shown with a placeholder when unset, and
// an Edit action opens the settings sheet.

struct SessionInfoSheet: View {
    @Environment(\.appColors) private var p
    let session: Session?
    let sid: String
    var onEdit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let none = t("none")
        let rows: [(String, String)] = [
            (t("modelLabel"), (session?.model.isEmpty == false) ? session!.model : none),
            (t("variantLabel"), (session?.variant.isEmpty == false) ? session!.variant : t("variantNone")),
            (t("presetLabel"), (session?.preset.isEmpty == false) ? session!.preset : none),
            (t("agentLocale"), (session?.locale?.isEmpty == false) ? session!.locale! : t("agentLocaleFollow")),
            // Generic grouping key (a subsession shows its parent session here).
            (t("sessionGroupLabel"), (session?.group.isEmpty == false) ? session!.group : none),
        ]
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.sm) {
                AppIcon(AppIcons.chat).foregroundStyle(p.primary).appFont(.body)
                Text(session?.id ?? sid).appFont(.meta).fontWeight(.bold).foregroundStyle(p.foreground).lineLimit(1)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                if i > 0 { Divider().overlay(p.border.opacity(0.4)) }
                HStack(alignment: .top) {
                    Text(row.0).appFont(.meta).foregroundStyle(p.mutedForeground)
                        .frame(width: 96, alignment: .leading)
                    Text(row.1).appFont(.meta).fontWeight(.semibold).foregroundStyle(p.foreground)
                    Spacer()
                }
            }
            HStack {
                Spacer()
                Button(t("edit")) {
                    dismiss()
                    onEdit()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// SessionSettingsSheet — model/variant/preset/locale.

struct SessionSettingsSheet: View {
    @Environment(\.appColors) private var p
    @Bindable var store: AppStore
    let sid: String
    let providers: [String: ProviderInfo]
    let presets: [Preset]

    @State private var selectedRef = ""
    @State private var variant = ""
    @State private var preset = ""
    @State private var locale = ""
    @State private var allModels: [ModelInfo] = []
    @State private var loading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(t("modelLabel")) {
                    if loading {
                        ProgressView()
                    } else {
                        Picker(t("modelLabel"), selection: $selectedRef) {
                            ForEach(allModels.map { modelRefOf($0) }, id: \.self) { ref in
                                Text(ref).tag(ref)
                            }
                        }
                        .pickerStyle(.menu)
                        if !variants.isEmpty {
                            Picker(t("variantLabel"), selection: $variant) {
                                Text(t("variantNone")).tag("")
                                ForEach(variants) { v in
                                    Text(v.name.isEmpty ? v.id : v.name).tag(v.id)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                }
                Section(t("presetLabel")) {
                    Picker(t("presetLabel"), selection: $preset) {
                        ForEach(presets.map { $0.id }, id: \.self) { id in
                            Text(id).tag(id)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Section(t("agentLocale")) {
                    Picker(t("agentLocale"), selection: $locale) {
                        Text(t("agentLocaleFollow")).tag("")
                        Text("中文").tag("zh")
                        Text("English").tag("en")
                    }
                    .pickerStyle(.menu)
                }
                Section {
                    Text(t("turnsByPreset")).appFont(.meta).foregroundStyle(p.mutedForeground)
                    Text(t("sysPromptByPreset")).appFont(.meta).foregroundStyle(p.mutedForeground)
                }
            }
            .navigationTitle(t("settingsTitle"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(t("cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(t("save")) {
                        Task {
                            var updates: [String: Any?] = ["variant": variant, "locale": locale]
                            if !selectedRef.isEmpty { updates["model"] = selectedRef }
                            if !preset.isEmpty { updates["preset"] = preset }
                            if let s = try? await store.api.settings(sid, updates) {
                                store.applySession(s)
                            }
                            dismiss()
                        }
                    }
                }
            }
            .onAppear(perform: load)
        }
    }

    private var variants: [ModelVariantInfo] {
        allModels.first { modelRefOf($0) == selectedRef }?.variants ?? []
    }

    private func load() {
        selectedRef = store.activeSession?.model ?? ""
        variant = store.activeSession?.variant ?? ""
        preset = store.activeSession?.preset ?? ""
        locale = store.activeSession?.locale ?? ""
        Task {
            var out: [ModelInfo] = []
            for pid in providers.keys {
                if let ms = try? await store.api.models(providerId: pid) { out.append(contentsOf: ms) }
            }
            allModels = out
            loading = false
            if out.isEmpty == false, !out.contains(where: { modelRefOf($0) == selectedRef }) {
                selectedRef = modelRefOf(out[0])
            }
        }
    }
}

/// A tight inline icon action (mirrors flutter's _tinyIcon: 14pt, muted,
/// tooltip label, no chrome).
struct IconAction: View {
    @Environment(\.appColors) private var p
    let slot: LucideIconName
    let label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            AppIcon(slot, size: 14)
                .foregroundStyle(p.mutedForeground)
                .padding(2)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Relative time label port of flutter's _fmtTime.
func fmtTime(_ iso: String) -> String {
    guard let d = ISO8601DateFormatter().date(from: iso) else { return "" }
    let now = Date()
    let mins = Int(now.timeIntervalSince(d) / 60)
    let hm = d.formatted(date: .omitted, time: .shortened)
    if mins < 1 { return t("timeJustNow") }
    if mins < 60 { return t("timeMinAgo", mins) }
    if Calendar.current.isDateInToday(d) { return hm }
    return "\(Calendar.current.component(.month, from: d))/\(Calendar.current.component(.day, from: d)) \(hm)"
}

// MessageBubble — reasoning-first ordering, tool cards, actions row.

struct MessageBubble: View {
    @Environment(\.appColors) private var p
    let msg: ChatMessage
    let api: AgentApi
    var onUndo: () -> Void
    var onResend: (String) -> Void

    @State private var reasoningOpen = false
    @State private var compactionOpen = false
    @State private var editOpen = false
    @State private var editText = ""
    @State private var retryConfirm = false
    @State private var undoConfirm = false

    /// Concatenated text of the message (retry prompt / edit seed).
    private var textOfMessage: String {
        msg.parts.filter { $0.type == "text" }.map { $0.text }.joined(separator: "\n")
    }

    private var ordered: [ChatPart] {
        msg.parts.filter { $0.type == "reasoning" } + msg.parts.filter { $0.type != "reasoning" }
    }

    var body: some View {
        let isUser = msg.role == "user"
        let isError = msg.role == "error"
        let isSystem = msg.role == "system" || msg.role == "event"
        let isStreaming = msg.status == "streaming"

        VStack(alignment: isSystem ? .center : (isUser ? .trailing : .leading), spacing: 0) {
            if isStreaming && ordered.isEmpty {
                HStack(spacing: AppSpacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(t("thinking")).appFont(.micro).foregroundStyle(p.mutedForeground)
                }
            } else {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    if isError {
                        Text(t("error")).appFont(.micro).fontWeight(.semibold).foregroundStyle(p.destructive)
                    }
                    ForEach(ordered) { part in
                        partView(part, p, isStreaming)
                    }
                }
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, 10)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    isError ? p.destructive.opacity(0.1)
                    : isSystem ? p.muted.opacity(0.3)
                    : isUser ? p.primary.opacity(0.12)
                    : p.card,
                    in: RoundedRectangle(cornerRadius: AppRadius.md)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md).stroke(
                        isError ? p.destructive.opacity(0.4)
                        : isSystem ? p.mutedForeground.opacity(0.25)
                        : isUser ? p.primary.opacity(0.4)
                        : p.border.opacity(0.5)
                    )
                )
                if !isStreaming && !isSystem {
                    HStack(spacing: 2) {
                        if msg.parts.contains(where: { $0.type == "text" || $0.type == "reasoning" }) {
                            IconAction(slot: AppIcons.copy, label: t("copy")) {
                                let s = msg.parts
                                    .filter { $0.type == "text" || $0.type == "reasoning" }
                                    .map { $0.text }.joined(separator: "\n")
                                #if os(macOS)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(s, forType: .string)
                                #else
                                UIPasteboard.general.string = s
                                #endif
                            }
                        }
                        if isUser {
                            IconAction(slot: AppIcons.refresh, label: t("retry")) {
                                retryConfirm = true
                            }
                            IconAction(slot: AppIcons.edit, label: t("edit")) {
                                editText = textOfMessage
                                editOpen = true
                            }
                        }
                        IconAction(slot: AppIcons.undo, label: t("undo")) {
                            undoConfirm = true
                        }
                        Text(fmtTime(msg.createdAt))
                            .appFont(.micro)
                            .foregroundStyle(p.mutedForeground)
                            .padding(.leading, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
                }
            }
        }
        .padding(.bottom, 12)
        .sheet(isPresented: $editOpen) {
            editSheet(p)
        }
        // Retry withdraws the message (and everything after) then resends —
        // destructive, confirm first (four-client policy, same as undo).
        .confirmationDialog(t("retryTitle"), isPresented: $retryConfirm, titleVisibility: .visible) {
            Button(t("retry")) { onResend(textOfMessage) }
        } message: {
            Text(t("retryBody"))
        }
        .confirmationDialog(t("undoTitle"), isPresented: $undoConfirm, titleVisibility: .visible) {
            Button(t("undo"), role: .destructive) { onUndo() }
        } message: {
            Text(t("undoBody"))
        }
    }

    /// Edit sheet (flutter `_editText` / webui edit dialog): pre-fills the
    /// message text; Apply withdraws + resends with the new text.
    private func editSheet(_ p: AppColors.Palette) -> some View {
        VStack(spacing: AppSpacing.md) {
            Text(t("editMessage")).appFont(.body).fontWeight(.semibold).foregroundStyle(p.foreground)
            TextField("", text: $editText, axis: .vertical)
                .lineLimit(3...8)
                .padding(10)
                .background(p.muted, in: RoundedRectangle(cornerRadius: AppRadius.md))
                .foregroundStyle(p.foreground)
            HStack {
                Button(t("cancel"), role: .cancel) {}
                Spacer()
                Button(t("apply")) {
                    let v = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !v.isEmpty else { return }
                    onResend(v)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(AppSpacing.lg)
        .presentationDetents([.height(260)])
    }

    @ViewBuilder
    private func partView(_ part: ChatPart, _ p: AppColors.Palette, _ streaming: Bool) -> some View {
        switch part.type {
        case "text":
            FileRefText(text: part.text, api: api, compact: false)
        case "reasoning":
            VStack(spacing: 4) {
                Button {
                    reasoningOpen.toggle()
                } label: {
                    HStack(spacing: AppSpacing.xs) {
                        AppIcon(reasoningOpen ? AppIcons.chevron_down : AppIcons.chevron_right, size: 14)
                        Text(t("thinkLabel") + (streaming ? "..." : ""))
                            .appFont(.micro).fontWeight(.semibold)
                        Spacer()
                    }
                    .foregroundStyle(p.warning)
                }
                .buttonStyle(.plain)
                if reasoningOpen || streaming {
                    MarkdownText(text: part.text, muted: true, size: 12)
                }
            }
            .padding(.leading, AppSpacing.md)
            .padding(.trailing, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xs)
            .background(p.warning.opacity(0.05))
            .overlay(alignment: .leading) {
                Rectangle().fill(p.warning).frame(width: 2)
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                              bottomTrailingRadius: AppRadius.sm,
                                              topTrailingRadius: AppRadius.sm))
        case "compaction":
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    compactionOpen.toggle()
                } label: {
                    HStack(spacing: AppSpacing.xs) {
                        AppIcon(compactionOpen ? AppIcons.chevron_down : AppIcons.chevron_right, size: 14)
                        Text(t("compactedLabel")).appFont(.micro)
                        Spacer()
                    }
                    .foregroundStyle(p.mutedForeground)
                }
                .buttonStyle(.plain)
                if compactionOpen {
                    Text(part.text).appFont(.meta).foregroundStyle(p.mutedForeground)
                }
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .background(p.muted.opacity(0.4), in: RoundedRectangle(cornerRadius: AppRadius.sm))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.sm).stroke(p.border.opacity(0.5)))
        case "file":
            MediaCard(api: api, code: part.code ?? "", name: part.name, mime: part.mime, size: part.size, compact: false)
        case "tool":
            ToolCard(part: part, streaming: streaming, api: api)
        default:
            EmptyView()
        }
    }
}

struct ToolCard: View {
    @Environment(\.appColors) private var p
    let part: ChatPart
    let streaming: Bool
    var api: AgentApi? = nil
    @State private var open = true
    @State private var inputOpen = true
    @State private var contentOpen = true
    @State private var metaOpen = true

    private var tool: String { part.tool.isEmpty ? (part.state?.title ?? "") : part.tool }

    /// Fixed media fields in a tool result's `data`: images/videos/audio
    /// (each `{code, mime, name}`) render as media cards.
    private var mediaRefs: [(code: String, mime: String?, name: String?)] {
        guard let data = part.state?.data else { return [] }
        var out: [(String, String?, String?)] = []
        func collect(_ v: Any?) {
            if let m = v as? [String: Any?], let code = m["code"] as? String, !code.isEmpty {
                out.append((code, m["mime"] as? String, m["name"] as? String))
            }
        }
        for key in ["images", "videos", "audio"] {
            if let list = data[key] as? [Any?] { list.forEach(collect) } else if let one = data[key] { collect(one) }
        }
        return out
    }

    private var hasMeta: Bool {
        let st = part.state
        return !(st?.changeId ?? "").isEmpty || !(st?.diff ?? "").isEmpty
            || (st?.additions ?? 0) > 0 || (st?.deletions ?? 0) > 0
    }

    var body: some View {
        let st = part.state ?? ToolState()
        let running = streaming && st.status == "running"
        let hasError = st.status == "error" || !(st.error ?? "").isEmpty
        let dot = hasError ? p.destructive : (running ? p.warning : p.success)

        VStack(alignment: .leading, spacing: 0) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    AppIcon(hasError ? AppIcons.error
                            : running ? AppIcons.more : AppIcons.success, size: 14)
                        .foregroundStyle(dot)
                    AppIcon(AppIcons.tools, size: 14)
                        .foregroundStyle(p.primary)
                    Text(toolDisplayName(tool))
                        .appFont(.meta).fontWeight(.semibold)
                        .foregroundStyle(p.mutedForeground).lineLimit(1)
                    if !st.title.isEmpty {
                        Text(st.title).appFont(.micro).italic()
                            .foregroundStyle(p.mutedForeground).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    AppIcon(open ? AppIcons.chevron_down : AppIcons.chevron_right, size: 14)
                        .foregroundStyle(p.mutedForeground)
                }
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, AppSpacing.xs)
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    if let input = st.input, !input.isEmpty {
                        section(t("toolInputParams"), AppIcons.braces, $inputOpen, p) {
                            MonoText(text: prettyAny(input))
                        }
                    } else if let draft = st.inputText, !draft.isEmpty {
                        // Arguments still streaming (tool-input-delta): raw JSON
                        // preview before `tool-call` delivers the parsed input.
                        section(t("toolInputParams"), AppIcons.braces, $inputOpen, p) {
                            MonoText(text: draft)
                        }
                    }
                    if hasError {
                        section(t("error"), AppIcons.error, .constant(true), p, destructive: true) {
                            MonoText(text: st.error ?? "", destructive: true)
                        }
                    }
                    section(t("content"), AppIcons.file, $contentOpen, p) {
                        VStack(alignment: .leading, spacing: AppSpacing.xs) {
                            if running {
                                Text(t("running")).appFont(.micro).italic().foregroundStyle(p.mutedForeground)
                            } else if !(st.output ?? "").isEmpty {
                                MonoText(text: st.output!)
                            }
                            if let api {
                                ForEach(Array(mediaRefs.enumerated()), id: \.offset) { _, ref in
                                    MediaCard(api: api, code: ref.code, name: ref.name, mime: ref.mime, size: nil)
                                }
                            }
                        }
                    }
                    if hasMeta {
                        section(t("metadata"), AppIcons.info, $metaOpen, p) {
                            VStack(alignment: .leading, spacing: 2) {
                                if !(st.changeId ?? "").isEmpty {
                                    metaRow(AppIcons.commit, "change_id", st.changeId!, p.primary)
                                }
                                if (st.additions ?? 0) > 0 || (st.deletions ?? 0) > 0 {
                                    metaRow(AppIcons.diff, "diff",
                                            "+\(st.additions ?? 0) -\(st.deletions ?? 0)",
                                            (st.deletions ?? 0) > 0 ? p.destructive : p.success)
                                }
                                if let diff = st.diff, !diff.isEmpty {
                                    MonoText(text: diff)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, AppSpacing.sm)
            }
        }
        // flutter: NO outer border (error tint destructive@5, else muted@35).
        .background(hasError ? p.destructive.opacity(0.05) : p.muted.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: AppRadius.sm))
    }

    @ViewBuilder
    private func metaRow(_ icon: LucideIconName, _ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: AppSpacing.xs) {
            AppIcon(icon, size: 13).foregroundStyle(color)
            Text(label).appFont(.micro).foregroundStyle(p.mutedForeground)
            Text(value).appMonoFont(.micro).foregroundStyle(color).lineLimit(1)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ icon: LucideIconName, _ binding: Binding<Bool>, _ p: AppColors.Palette,
                         destructive: Bool = false, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                binding.wrappedValue.toggle()
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    AppIcon(binding.wrappedValue ? AppIcons.chevron_down : AppIcons.chevron_right, size: 14)
                        .foregroundStyle(p.mutedForeground)
                    AppIcon(icon, size: 13)
                    Text(title).appFont(.micro)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(destructive ? p.destructive : p.mutedForeground)
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, AppSpacing.xs)
            }
            .buttonStyle(.plain)
            if binding.wrappedValue {
                content().padding(.horizontal, AppSpacing.sm).padding(.bottom, AppSpacing.sm)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.background.opacity(0.5), in: RoundedRectangle(cornerRadius: AppRadius.sm))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.sm)
            .stroke(destructive ? p.destructive.opacity(0.4) : p.border.opacity(0.5)))
        .padding(.horizontal, AppSpacing.sm)
        .padding(.bottom, AppSpacing.sm)
    }
}

struct MonoText: View {
    @Environment(\.appColors) private var p
    let text: String
    var destructive: Bool = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .appMonoFont(.micro)
                .foregroundStyle(destructive ? p.destructive : p.mutedForeground)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 200, alignment: .top)
    }
}

/// flutter `toolDisplayName`: `todowrite` shows as `todo`. The card's glyph and
/// tint are fixed (`tools` / primary) for every tool — see `ToolCard`.
func toolDisplayName(_ name: String) -> String {
    name == "todowrite" ? "todo" : name
}

