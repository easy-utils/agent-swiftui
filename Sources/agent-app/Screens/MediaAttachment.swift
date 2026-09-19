import SwiftUI
import AVKit
import AVFoundation
import PDFKit
import UniformTypeIdentifiers
import MarkdownUI

// MediaAttachment — port of flutter widgets/media_attachment.dart: renders an
// agent file code by kind (image / audio / video / pdf / text / other), with a
// full-screen viewer, inline audio player, video poster + player, pdf/text
// preview and a save card. Also owns mime classification + the shared
// `[附件 … | file:…]` file-ref splitter used by message bubbles.

// ---- mime / kind helpers ----

func mimeOfName(_ name: String) -> String {
    let n = name.lowercased()
    if n.hasSuffix(".png") { return "image/png" }
    if n.hasSuffix(".jpg") || n.hasSuffix(".jpeg") { return "image/jpeg" }
    if n.hasSuffix(".gif") { return "image/gif" }
    if n.hasSuffix(".webp") { return "image/webp" }
    if n.hasSuffix(".svg") { return "image/svg+xml" }
    if n.hasSuffix(".bmp") { return "image/bmp" }
    if n.hasSuffix(".heic") { return "image/heic" }
    if n.hasSuffix(".tif") || n.hasSuffix(".tiff") { return "image/tiff" }
    if n.hasSuffix(".pdf") { return "application/pdf" }
    if n.hasSuffix(".txt") || n.hasSuffix(".md") { return "text/plain" }
    if n.hasSuffix(".csv") { return "text/csv" }
    if n.hasSuffix(".json") { return "application/json" }
    if n.hasSuffix(".wav") { return "audio/wav" }
    if n.hasSuffix(".mp3") { return "audio/mpeg" }
    if n.hasSuffix(".m4a") || n.hasSuffix(".aac") { return "audio/mp4" }
    if n.hasSuffix(".ogg") { return "audio/ogg" }
    if n.hasSuffix(".mp4") { return "video/mp4" }
    if n.hasSuffix(".webm") { return "video/webm" }
    if n.hasSuffix(".mov") { return "video/quicktime" }
    return "application/octet-stream"
}

enum MediaKind { case image, audio, video, pdf, text, other }

func classifyMedia(_ mime: String?, _ name: String?) -> MediaKind {
    let m = (mime ?? "").lowercased()
    let n = (name ?? "").lowercased()
    if m.hasPrefix("image/") { return .image }
    if m.hasPrefix("audio/") { return .audio }
    if m.hasPrefix("video/") { return .video }
    if m == "application/pdf" || n.hasSuffix(".pdf") { return .pdf }
    if m.hasPrefix("text/") || m == "application/json" || m.hasSuffix("+json")
        || n.hasSuffix(".md") || n.hasSuffix(".txt") || n.hasSuffix(".log") || n.hasSuffix(".csv") {
        return .text
    }
    if n.hasSuffix(".png") || n.hasSuffix(".jpg") || n.hasSuffix(".jpeg")
        || n.hasSuffix(".gif") || n.hasSuffix(".webp") { return .image }
    if n.hasSuffix(".wav") || n.hasSuffix(".mp3") || n.hasSuffix(".m4a")
        || n.hasSuffix(".ogg") || n.hasSuffix(".aac") { return .audio }
    if n.hasSuffix(".mp4") || n.hasSuffix(".webm") || n.hasSuffix(".mov") || n.hasSuffix(".mkv") {
        return .video
    }
    return .other
}

func formatBytes(_ n: Int) -> String {
    if n >= 1024 * 1024 { return String(format: "%.1f MB", Double(n) / 1024 / 1024) }
    if n >= 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
    return "\(n) B"
}

func formatDurationLabel(_ seconds: Double?) -> String {
    guard let s = seconds, s.isFinite, s >= 0 else { return "--:--" }
    let m = Int(s) / 60
    let sec = Int(s) % 60
    return String(format: "%d:%02d", m, sec)
}

// ---- file-ref splitting (flutter _FileRefsText) ----

struct FileRefText: View {
    let text: String
    let api: AgentApi
    let compact: Bool

    private static let re = try! NSRegularExpression(
        pattern: #"\[附件\s+(.+?)\s*\|\s*file:([0-9a-zA-Z]+)\s*\|\s*([^|\]]*)\s*\|\s*([^\]|]*)\]"#
    )

    private enum Seg { case md(String); case file(label: String, code: String, mime: String?) }

    private var segments: [Seg] {
        let ns = text as NSString
        var out: [Seg] = []
        var idx = 0
        for m in Self.re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > idx {
                out.append(.md(ns.substring(with: NSRange(location: idx, length: m.range.location - idx))))
            }
            let label = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let code = ns.substring(with: m.range(at: 2))
            let mime = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
            out.append(.file(label: label, code: code, mime: mime.isEmpty ? nil : mime))
            idx = m.range.location + m.range.length
        }
        if idx < ns.length { out.append(.md(ns.substring(from: idx))) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .md(let s):
                    MarkdownText(text: s)
                case .file(let label, let code, let mime):
                    MediaCard(api: api, code: code, name: label, mime: mime, size: nil, compact: compact)
                }
            }
        }
    }
}

// ---- markdown body (flutter _Markdown / web marked) ----

struct MarkdownText: View {
    @Environment(\.appColors) private var p
    let text: String
    var muted: Bool = false
    var size: CGFloat = 14

    var body: some View {
        Markdown(text)
            .markdownTheme(.agent(p, muted: muted, size: size))
            .textSelection(.enabled)
    }
}

extension Theme {
    static func agent(_ p: AppColors.Palette, muted: Bool, size: CGFloat) -> Theme {
        let fg = muted ? p.mutedForeground : p.foreground
        // The bundled families must be named explicitly: MarkdownUI's styles do
        // not inherit the view's `.font`, so markdown bodies would otherwise
        // render the system face instead of Noto Sans SC.
        let sans = AppFonts.sans
        let mono = AppFonts.mono
        return Theme()
            .text {
                FontFamily(.custom(sans))
                FontSize(size)
                ForegroundColor(fg)
            }
            .code {
                FontFamily(.custom(mono))
                FontSize(size - 2)
                ForegroundColor(fg)
                BackgroundColor(p.muted)
            }
            .strong { FontWeight(.semibold) }
            .emphasis { FontStyle(.italic) }
            .link { ForegroundColor(p.primary) }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.15))
                    .markdownMargin(top: 0, bottom: 8)
            }
            .heading1 { configuration in
                configuration.label.markdownTextStyle {
                    FontWeight(.semibold); FontSize(size + 5); ForegroundColor(fg)
                }.markdownMargin(top: 8, bottom: 6)
            }
            .heading2 { configuration in
                configuration.label.markdownTextStyle {
                    FontWeight(.semibold); FontSize(size + 3); ForegroundColor(fg)
                }.markdownMargin(top: 8, bottom: 6)
            }
            .heading3 { configuration in
                configuration.label.markdownTextStyle {
                    FontWeight(.semibold); FontSize(size + 1); ForegroundColor(fg)
                }.markdownMargin(top: 8, bottom: 6)
            }
            .heading4 { configuration in
                configuration.label.markdownTextStyle { FontWeight(.semibold); ForegroundColor(fg) }
                    .markdownMargin(top: 6, bottom: 4)
            }
            .heading5 { configuration in
                configuration.label.markdownTextStyle { FontWeight(.semibold); ForegroundColor(fg) }
                    .markdownMargin(top: 6, bottom: 4)
            }
            .heading6 { configuration in
                configuration.label.markdownTextStyle { FontWeight(.semibold); ForegroundColor(fg) }
                    .markdownMargin(top: 6, bottom: 4)
            }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    Rectangle().fill(p.primary.opacity(0.5)).frame(width: 3)
                    configuration.label
                        .markdownTextStyle { ForegroundColor(p.mutedForeground); FontStyle(.italic) }
                        .relativePadding(.horizontal, length: .em(0.6))
                }
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: 4, bottom: 8)
            }
            .codeBlock { configuration in
                ScrollView(.horizontal, showsIndicators: false) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .markdownTextStyle {
                            FontFamily(.custom(mono)); FontSize(size - 2); ForegroundColor(fg)
                        }
                        .padding(8)
                }
                .background(p.muted)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
                .markdownMargin(top: 4, bottom: 8)
            }
            .table { configuration in
                configuration.label
                    .markdownTableBorderStyle(TableBorderStyle(color: p.border, strokeStyle: .init(lineWidth: 1)))
                    .markdownMargin(top: 4, bottom: 8)
            }
    }
}

// ---- media card ----

struct MediaCard: View {
    @Environment(\.appColors) private var p
    let api: AgentApi
    let code: String
    var name: String?
    var mime: String?
    var size: Int?
    var compact: Bool = false
    var localData: Data? = nil

    @State private var bytes: Data?
    @State private var loadError = false
    @State private var viewerOpen = false
    @State private var previewOpen = false
    @State private var localURL: URL?

    private var kind: MediaKind { classifyMedia(mime, name) }
    private var title: String { name ?? code }

    var body: some View {
        Group {
            switch kind {
            case .image: imageCard(p)
            case .audio: audioCard(p)
            case .video: videoCard(p)
            case .pdf, .text: previewCard(p)
            case .other: saveCard(p)
            }
        }
        .task(id: code) { await load() }
        .sheet(isPresented: $viewerOpen) {
            FullScreenMediaView(url: localURL, kind: kind)
        }
    }

    private func load() async {
        if let d = localData { bytes = d } else {
            do { bytes = try await api.fetchFileBytes(code) }
            catch { loadError = true }
        }
        guard let d = bytes, kind == .audio || kind == .video else { return }
        let ext = (name as NSString?)?.pathExtension ?? ""
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(code)\(ext.isEmpty ? "" : ".\(ext)")")
        try? d.write(to: url)
        localURL = url
    }

    private func imageCard(_ p: AppColors.Palette) -> some View {
        Group {
            if let bytes, let img = platformImage(bytes) {
                Image(platformImage: img)
                    .resizable().scaledToFit()
                    .frame(maxHeight: compact ? 72 : 260)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                    .onTapGesture { viewerOpen = true }
            } else if loadError {
                mediaError(p)
            } else {
                placeholder(p, "photo")
            }
        }
    }

    private func audioCard(_ p: AppColors.Palette) -> some View {
        HStack(spacing: AppSpacing.sm) {
            AppIcon(AppIcons.music).foregroundStyle(p.primary)
            Text(title).appFont(.meta).foregroundStyle(p.foreground).lineLimit(1)
            Spacer()
            AudioPlayButton(url: localURL)
        }
        .padding(AppSpacing.sm)
        .background(p.muted.opacity(0.4), in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(p.border.opacity(0.5)))
    }

    private func videoCard(_ p: AppColors.Palette) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.md).fill(p.muted)
            if loadError {
                Text("!").foregroundStyle(p.destructive)
            } else if localURL != nil {
                // First-frame poster via AVAssetImageGenerator would need async;
                // show the play affordance + open the full-screen player.
                AppIcon(AppIcons.play_round).appFont(.screenTitle).foregroundStyle(.white)
            } else {
                ProgressView()
            }
        }
        .frame(height: compact ? 72 : 200)
        .onTapGesture { if localURL != nil { viewerOpen = true } }
    }

    private func previewCard(_ p: AppColors.Palette) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack {
                AppIcon(AppIcons.file).foregroundStyle(p.primary)
                Text(title).appFont(.meta).foregroundStyle(p.foreground).lineLimit(1)
                Spacer()
                if let size { Text(formatBytes(size)).appFont(.micro).foregroundStyle(p.mutedForeground) }
                Button {
                    previewOpen.toggle()
                } label: {
                    AppIcon(previewOpen ? AppIcons.chevron_up : AppIcons.chevron_down)
                        .appFont(.micro).foregroundStyle(p.mutedForeground)
                }.buttonStyle(.plain)
            }
            if previewOpen, let bytes {
                if kind == .text, let s = String(data: bytes, encoding: .utf8) {
                    ScrollView { Text(s).appMonoFont(.micro).foregroundStyle(p.mutedForeground) }
                        .frame(maxHeight: 200)
                } else {
                    PDFKitView(data: bytes).frame(height: 320)
                }
            }
        }
        .padding(AppSpacing.sm)
        .background(p.muted.opacity(0.4), in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(p.border.opacity(0.5)))
    }

    private func saveCard(_ p: AppColors.Palette) -> some View {
        HStack(spacing: AppSpacing.sm) {
            AppIcon(AppIcons.download).foregroundStyle(p.primary)
            Text(title).appFont(.meta).foregroundStyle(p.foreground).lineLimit(1)
            if let size { Text(formatBytes(size)).appFont(.micro).foregroundStyle(p.mutedForeground) }
            Spacer()
            Button(t("save")) { saveToDownloads() }.appFont(.meta).buttonStyle(.bordered)
        }
        .padding(AppSpacing.sm)
        .background(p.muted.opacity(0.4), in: RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md).stroke(p.border.opacity(0.5)))
    }

    private func placeholder(_ p: AppColors.Palette, _ icon: String) -> some View {
        RoundedRectangle(cornerRadius: AppRadius.md).fill(p.muted)
            .frame(height: compact ? 72 : 120)
            .overlay(ProgressView())
    }

    private func mediaError(_ p: AppColors.Palette) -> some View {
        RoundedRectangle(cornerRadius: AppRadius.md).fill(p.destructive.opacity(0.1))
            .frame(height: 48)
            .overlay(
                HStack(spacing: AppSpacing.sm) {
                    AppIcon(AppIcons.image_off).foregroundStyle(p.destructive)
                    Text(t("loadError")).appFont(.meta).foregroundStyle(p.destructive)
                }
            )
    }

    private func saveToDownloads() {
        guard let bytes else { return }
        let name = (self.name?.isEmpty == false) ? self.name! : code
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent(name)
        try? bytes.write(to: url)
    }
}

func platformImage(_ data: Data) -> Any? {
    #if os(macOS)
    return NSImage(data: data)
    #else
    return UIImage(data: data)
    #endif
}

extension Image {
    init(platformImage: Any) {
        #if os(macOS)
        self.init(nsImage: platformImage as! NSImage)
        #else
        self.init(uiImage: platformImage as! UIImage)
        #endif
    }
}

struct AudioPlayButton: View {
    @Environment(\.appColors) private var p
    let url: URL?
    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var timer: Timer?

    var body: some View {
        Button {
            guard let url else { return }
            if playing {
                player?.pause()
                playing = false
            } else {
                if player == nil { player = try? AVAudioPlayer(contentsOf: url) }
                player?.play()
                playing = true
            }
        } label: {
            AppIcon(playing ? AppIcons.pause_round : AppIcons.play_round)
                .appFont(.screenTitle).foregroundStyle(p.primary)
        }
        .buttonStyle(.plain)
        .onDisappear { player?.stop(); playing = false }
    }
}

struct PDFKitView: View {
    let data: Data
    var body: some View {
        Group {
            #if os(macOS)
            PDFRepresentable(data: data)
            #else
            PDFRepresentable(data: data)
            #endif
        }
    }
}

#if os(macOS)
struct PDFRepresentable: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView(); v.autoScales = true; v.document = PDFDocument(data: data); return v
    }
    func updateNSView(_ v: PDFView, context: Context) {}
}
#else
struct PDFRepresentable: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView(); v.autoScales = true; v.document = PDFDocument(data: data); return v
    }
    func updateUIView(_ v: PDFView, context: Context) {}
}
#endif

struct FullScreenMediaView: View {
    let url: URL?
    let kind: MediaKind
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url {
                switch kind {
                case .video: VideoPlayer(player: AVPlayer(url: url))
                case .image:
                    #if os(macOS)
                    if let img = NSImage(contentsOf: url) { Image(nsImage: img).resizable().scaledToFit() }
                    #else
                    if let img = UIImage(contentsOfFile: url.path) { Image(uiImage: img).resizable().scaledToFit() }
                    #endif
                default: Text(url.lastPathComponent).foregroundStyle(.white)
                }
            }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        AppIcon(AppIcons.close).appFont(.screenTitle).foregroundStyle(.white)
                    }
                }
                Spacer()
            }
            .padding()
        }
    }
}

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
extension NSImage {
    /// PNG bytes of the image (pasteboard / clipboard upload path).
    var pngDataCompat: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
#else
import UIKit
typealias PlatformImage = UIImage
extension UIImage {
    var pngDataCompat: Data? { pngData() }
}
#endif
