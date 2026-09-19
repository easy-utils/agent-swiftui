/// Bundled fallback copy of the server capability matrix (canonical api
/// types only). Used until ListProvidersCatalog answers.
let fallbackApiTypeCapabilities: [String: [String]] = [
    "openai-compatible": ["text", "embedding", "image", "speech", "transcription", "realtime"],
    "openai": ["text", "embedding", "image", "speech", "transcription", "realtime"],
    "anthropic": ["text"],
    "deepseek": ["text"],
    "google": ["text"],
    "vercel-compatible-gateway": ["text", "image", "video", "speech", "transcription", "embedding", "rerank", "realtime"],
    "cohere": ["text", "rerank"],
]

/// The 8 first-class modalities, in section order.
let modelCapabilities: [String] = [
    "text", "image", "video", "speech", "transcription", "embedding", "rerank", "realtime",
]

import Foundation

// Domain models — a port of flutter/lib/models.dart (the UI subset).

struct Session: Identifiable, Equatable {
    var id: String
    var org: String = ""
    var repo: String = ""
    var branch: String = ""
    var model: String = ""
    var variant: String = ""
    var preset: String = ""
    var tipId: String?
    var maxTurns: Int?
    var systemPrompt: String?
    var locale: String?
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var totalTokens: Int = 0
    var lastInputTokens: Int = 0
    var lastOutputTokens: Int = 0
    var createdAt: String = ""
    var updatedAt: String = ""
    var unreadCount: Int?
    var lastMessageAt: String = ""
    var lastMessagePreview: String = ""
    var messageSeq: Int = 0
    /// Generic grouping key (empty = ungrouped). A subsession records its
    /// parent's session name here.
    var group: String = ""

    var sessionName: String { org.isEmpty ? id : "\(org):\(repo):\(branch)" }
}

struct ToolState: Equatable {
    var status: String = ""
    var title: String = ""
    var input: [String: Any?]?
    var output: String?
    var error: String?
    var data: [String: Any?]?
    var changeId: String?
    var diff: String?
    var additions: Int?
    var deletions: Int?
    /// Raw streamed tool-argument JSON (tool-input-delta), shown live until the
    /// complete `input` arrives with `tool-call`.
    var inputText: String?
    static func == (a: ToolState, b: ToolState) -> Bool {
        a.status == b.status && a.title == b.title && a.output == b.output &&
        a.error == b.error && a.changeId == b.changeId && a.diff == b.diff &&
        a.additions == b.additions && a.deletions == b.deletions &&
        a.inputText == b.inputText
    }
}

struct MessagePart {
    var id: String
    var type: String
    var text: String?
    var tool: String?
    var toolCallId: String?
    var state: ToolState?
    var code: String?
    var name: String?
    var mime: String?
    var size: Int?
}

struct Message {
    var id: String
    var role: String
    var parts: [MessagePart]
    var createdAt: String?
    var prevId: String = ""
}

struct ChatPart: Identifiable, Equatable {
    var id: String
    var type: String
    var text: String = ""
    var tool: String = ""
    var state: ToolState?
    var code: String?
    var name: String?
    var mime: String?
    var size: Int?
}

struct ChatMessage: Identifiable {
    var id: String
    var role: String
    var status: String // pending | streaming | complete | error
    var parts: [ChatPart]
    var createdAt: String = ""
    var seq: Int?
    var prevId: String = ""
    var isLocal: Bool = false
}

enum UploadState: String { case idle, uploading, done, error }

struct UploadedFile: Equatable {
    var code: String
    var name: String?
    var mime: String?
    var size: Int?
    var localPath: String = ""
    var uploadState: UploadState = .done
    var error: String?
    var isUploading: Bool { uploadState == .uploading }
    var hasError: Bool { uploadState == .error }
}

/// File metadata from GetFileMeta. The optional media facts are populated
/// (server-side, best-effort) only for supported image/video/audio files.
struct FileMeta {
    var contentType: String?
    var length: Int
    var width: Int?
    var height: Int?
    var durationMs: Int?
    var thumbCode: String?
    var thumbhash: String?
}

struct ChatDraft {
    var text: String = ""
    var attachments: [UploadedFile] = []
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty }
}

struct MailboxEntry: Identifiable {
    var id: String
    var msgType: String
    var payload: String
    var effectiveAt: String?
    var status: String
    var createdAt: String
    var consumedAt: String?
}

struct Preset: Identifiable {
    var id: String
    var systemPrompt: String = ""
    var tools: [String] = []
    var maxTurns: Int = 25
    var isSystem: Bool = false
}

struct ToolConfigField {
    var key: String
    var label: String
    var type: String
}

struct ToolConfigKnob {
    var name: String
    var type: String
    /// `value` (ordinary knob) or `model` (a provider_id/model_id reference).
    var kind: String = "value"
    /// When kind == "model": the modality the reference must match.
    var capability: String = ""
    var enumValues: [String] = []
    var defaultValue: Any?
    var description: String = ""
    var scope: String = "global"
}

struct ToolInfo: Identifiable {
    var name: String
    var description: String = ""
    var category: String = ""
    var parameters: [String: Any?]?
    var configFields: [ToolConfigField] = []
    var config: [ToolConfigKnob] = []
    var requiredConfig: [String] = []
    var id: String { name }
}

struct ProviderModel: Identifiable, Equatable {
    var id: String
    var name: String
    var contextLimit: Int?
    var modelType: String = ""
}

struct ProviderInfo: Identifiable, Equatable {
    var providerId: String
    /// The single modality this provider serves (semantic grouping).
    var capability: String = "text"
    var apiType: String
    var baseUrl: String
    var apiKey: String
    var headers: [String: String] = [:]
    var models: [ProviderModel] = []
    var id: String { providerId }
}

struct ProviderDraft {
    var originalId: String?
    var id: String = ""
    var capability: String = "text"
    var apiType: String = "openai-compatible"
    var baseUrl: String = ""
    var apiKey: String = ""
    var models: [ProviderModel] = []
    var isEdit: Bool { originalId != nil }
}

struct ModelVariantInfo: Identifiable, Equatable {
    var id: String
    var name: String = ""
    var description: String = ""
}

struct ModelInfo: Identifiable {
    var id: String
    var name: String
    var providerId: String = ""
    var contextLimit: Int?
    var variants: [ModelVariantInfo] = []
    var id_: String { providerId.isEmpty ? id : "\(providerId)/\(id)" }
}

func modelRefOf(_ m: ModelInfo) -> String { m.id_ }

struct BackendCfg: Identifiable, Equatable {
    var name: String
    var baseUrl: String
    var token: String
    var id: String { baseUrl }
}

func backendNameFor(_ baseUrl: String) -> String {
    URL(string: baseUrl)?.host ?? baseUrl
}

// ---- stream events ----

struct StreamEvent {
    var event: String
    var params: [String: Any?]
    var eid: String = ""
    var runId: String = ""
}

struct SessionListEvent {
    var snapshot: Bool
    var upserts: [Session]
    var removed: [String]
}
