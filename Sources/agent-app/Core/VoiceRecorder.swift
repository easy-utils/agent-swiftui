import SwiftUI
import AVFoundation

// VoiceRecorder — port of flutter services/voice.dart (io): records a WAV via
// AVAudioRecorder and returns it as a PickedFile (the upload path input).

final class VoiceRecorder {
    private var recorder: AVAudioRecorder?
    private var url: URL?

    func start() async -> Bool {
        #if os(iOS)
        let granted = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
        guard granted else { return false }
        #else
        // macOS: the system prompts on first use; treat setup success as grant.
        #endif
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let r = try AVAudioRecorder(url: u, settings: settings)
            guard r.record() else { return false }
            recorder = r
            url = u
            return true
        } catch {
            return false
        }
    }

    func stop() async -> PickedFile? {
        guard let r = recorder, let u = url else { return nil }
        let seconds = r.currentTime
        r.stop()
        recorder = nil
        url = nil
        // Ignore clips too short to be meaningful (flutter voiceTooShort).
        guard seconds >= 0.3, let data = try? Data(contentsOf: u) else { return nil }
        try? FileManager.default.removeItem(at: u)
        return PickedFile(name: "voice-\(Int(Date().timeIntervalSince1970)).wav",
                          mime: "audio/wav", bytes: data, localPath: u.path)
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil
    }
}

struct PickedFile {
    var name: String
    var mime: String
    var bytes: Data
    var localPath: String = ""
}
