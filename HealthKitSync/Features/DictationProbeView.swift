#if DEBUG
import SwiftUI
import AVFoundation
import Speech

/// Exercises the real authorization callback on a phone, without recording audio.
struct DictationProbeView: View {
    @State private var dictation = DictationStore()
    @State private var draft = "保留原草稿"
    @State private var report = "检查语音授权回调…"
    var body: some View {
        Text(report).padding().task {
            guard AVAudioApplication.shared.recordPermission == .granted,
                  SFSpeechRecognizer.authorizationStatus() == .authorized else {
                finish(false, "权限尚未授予，跳过探针；不请求权限或录音。")
                return
            }
            for _ in 0..<3 {
                dictation.begin(draft: draft) { draft = $0 }
                // Release while authorization is pending: no microphone capture starts.
                dictation.finish()
                for _ in 0..<100 {
                    if !dictation.isActive { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard !dictation.isActive, draft == "保留原草稿",
                      dictation.message == "语音输入已就绪，请再次按住麦克风说话。" else {
                    dictation.cancel()
                    finish(false, "授权返回或松手恢复检查失败")
                    return
                }
            }
            finish(true, "PASS：真实系统授权回调连续执行三次；松手后不录音；原草稿保留。")
        }
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
