#if DEBUG
import SwiftUI
@preconcurrency import AVFoundation
@preconcurrency import Speech

/// Exercises the real authorization callback on a phone, without recording audio.
struct DictationProbeView: View {
    @State private var dictation = DictationStore()
    @State private var draft = "保留原草稿"
    @State private var recognition: SFSpeechRecognitionTask?
    @State private var outcome: [String: Any]?
    @State private var report = "检查语音授权回调…"
    var body: some View {
        Text(report).padding().task {
            guard AVAudioApplication.shared.recordPermission == .granted,
                  SFSpeechRecognizer.authorizationStatus() == .authorized else {
                finish(false, "权限尚未授予，跳过探针；不请求权限或录音。")
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--dictation-transcription-probe") {
                var results: [[String: Any]] = []
                for local in [true, false] { results.append(await transcribe(local: local)) }
                let value: [String: Any] = ["results": results, "checkedAt": Date().ISO8601Format()]
                let data = try? JSONSerialization.data(withJSONObject: value, options: .prettyPrinted)
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try? data?.write(to: documents.appendingPathComponent("dictation-transcription-probe.json"), options: .atomic)
                report = results.description
                return
            }
            for _ in 0..<3 {
                dictation.begin(draft: draft) { draft = $0 }
                // Release before the deferred audio start: no microphone capture starts.
                dictation.finish()
                for _ in 0..<100 {
                    if !dictation.isActive { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard !dictation.isActive, draft == "保留原草稿",
                      dictation.message == nil else {
                    dictation.cancel()
                    finish(false, "快速松手恢复检查失败")
                    return
                }
            }
            finish(true, "PASS：已授权快速启动连续检查三次；立即松手不录音；原草稿保留。")
        }
    }
    private func transcribe(local: Bool) async -> [String: Any] {
        outcome = nil
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) else { return ["error": "locale unavailable"] }
        do {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let file = try AVAudioFile(forReading: documents.appendingPathComponent("dictation-fixture.caf"))
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = local
            recognition = recognizer.recognitionTask(with: request) { @Sendable result, error in
                let text = result?.bestTranscription.formattedString ?? ""
                let final = result?.isFinal ?? false
                let code = (error as NSError?)?.code
                let domain = (error as NSError?)?.domain
                let description = error?.localizedDescription
                Task { @MainActor in
                    if final || code != nil {
                        outcome = ["local": local, "text": text, "final": final, "code": code as Any? ?? NSNull(), "domain": domain as Any? ?? NSNull(), "error": description as Any? ?? NSNull()]
                    }
                }
            }
            while file.framePosition < file.length {
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
                try file.read(into: buffer)
                request.append(buffer)
            }
            request.endAudio()
            for _ in 0..<150 {
                if outcome != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let value = outcome ?? ["local": local, "error": "timed out"]
            recognition?.cancel()
            recognition = nil
            _ = recognizer.isAvailable // Keep the recognizer alive until the task ends.
            return value
        } catch { return ["local": local, "error": error.localizedDescription] }
    }

    private func finish(_ success: Bool, _ message: String) {
        report = message
        let value: [String: Any] = ["success": success, "report": message, "checkedAt": Date().ISO8601Format()]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: .prettyPrinted),
           let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: documents.appendingPathComponent("dictation-probe-result.json"), options: .atomic)
        }
    }
}
#endif
