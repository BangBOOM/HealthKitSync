import Foundation
import Observation
@preconcurrency import AVFoundation
@preconcurrency import Speech

@MainActor
@Observable
final class DictationStore {
    enum Phase { case idle, preparing, recording, finishing }
    private(set) var phase: Phase = .idle
    private(set) var transcript = ""
    private(set) var audioLevel: Float = 0
    private(set) var message: String?
    var isActive: Bool { phase != .idle }
    var status: String {
        switch phase {
        case .idle: return ""
        case .preparing: return "正在准备语音输入…"
        case .recording: return "正在听，松开结束"
        case .finishing: return "正在完成识别…"
        }
    }
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognition: SFSpeechRecognitionTask?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var isHeld = false
    @ObservationIgnored private var ownsAudioSession = false
    @ObservationIgnored private var tapInstalled = false
    @ObservationIgnored private var capturedFrames = 0
    @ObservationIgnored private var peakLevel: Float = 0
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var sampleRate = 0.0
    @ObservationIgnored private var originalDraft = ""
    @ObservationIgnored private var updateDraft: ((String) -> Void)?

    func begin(draft: String, update: @escaping (String) -> Void) {
        guard phase == .idle else { return }
        generation = UUID()
        let id = generation
        isHeld = true
        phase = .preparing
        message = nil
        transcript = ""
        capturedFrames = 0
        peakLevel = 0
        audioLevel = 0
        sampleRate = 0
        startedAt = Date()
        originalDraft = draft
        updateDraft = update
        // Previously granted permissions need no asynchronous authorization round trip.
        if AVAudioApplication.shared.recordPermission == .granted,
           SFSpeechRecognizer.authorizationStatus() == .authorized {
            Task { [weak self] in
                // Give touch feedback a frame to reach the screen/Taptic Engine before
                // synchronous audio-session activation occupies the main thread.
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.generation == id else { return }
                guard self.isHeld else { self.cleanUp(); return }
                self.start(id: id)
            }
            return
        }
        Task { [weak self] in
            let microphone = await AVAudioApplication.requestRecordPermission()
            guard let self, self.generation == id else { return }
            guard microphone else { self.fail("请在系统设置中允许 HealthKitSync 使用麦克风。"); return }
            // Legacy Speech callbacks may run off-main. @Sendable prevents them
            // from inheriting this store's MainActor isolation and trapping on entry.
            let speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { @Sendable status in
                    continuation.resume(returning: status == .authorized)
                }
            }
            guard self.generation == id else { return }
            guard speech else { self.fail("请在系统设置中允许 HealthKitSync 使用语音识别。"); return }
            guard self.isHeld else {
                self.cleanUp()
                self.message = "语音输入已就绪，请再次按住输入栏说话。"
                return
            }
            self.start(id: id)
        }
    }

    private func start(id: UUID) {
        do {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable else {
                fail("苹果语音识别暂不可用，请稍后重试或使用键盘输入。")
                return
            }
            self.recognizer = recognizer
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
            ownsAudioSession = true
            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.engine = engine
            self.request = request
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                fail("麦克风当前不可用，请检查音频设备后重试。")
                return
            }
            sampleRate = format.sampleRate
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
                request.append(buffer)
                let frames = Int(buffer.frameLength)
                var peak: Float = 0
                if let samples = buffer.floatChannelData?[0] {
                    for index in stride(from: 0, to: frames, by: 16) { peak = max(peak, abs(samples[index])) }
                }
                let level = peak
                Task { @MainActor [weak self] in
                    guard let self, self.generation == id else { return }
                    self.capturedFrames += frames
                    self.peakLevel = max(self.peakLevel, level)
                    self.audioLevel = min(1, level * 8)
                }
            }
            tapInstalled = true
            recognition = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                let failureCode = (error as NSError?)?.code
                let failureDomain = (error as NSError?)?.domain
                let failureDescription = error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.generation == id else { return }
                    if let text, !text.isEmpty {
                        self.transcript = text
                        self.updateDraft?(self.originalDraft + (self.originalDraft.isEmpty ? "" : "\n") + text)
                    }
                    if final { self.complete() }
                    else if let failureCode {
                        self.writeDiagnostic(errorCode: failureCode, errorDomain: failureDomain)
                        if !self.transcript.isEmpty {
                            self.cleanUp()
                            self.message = "识别提前结束，已保留识别文字，请检查后发送。"
                        } else {
                            let detail = failureDescription ?? "苹果语音服务未返回文字"
                            self.fail("\(detail)（\(failureCode)）。原有草稿已保留。")
                        }
                    }
                }
            }
            engine.prepare()
            try engine.start()
            phase = .recording
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(55)) } catch { return }
                guard let self, self.generation == id else { return }
                self.finish()
            }
        } catch { fail("无法启动语音输入：\(error.localizedDescription)") }
    }

    func finish() {
        isHeld = false
        guard phase == .recording else { return }
        phase = .finishing
        stopAudio(deactivateSession: false)
        request?.endAudio()
        deadline?.cancel()
        let id = generation
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, self.generation == id else { return }
            // Keep the last partial transcription if Apple doesn't finalize promptly.
            if self.transcript.isEmpty {
                self.writeDiagnostic(errorDomain: "finalizationTimeout")
                self.fail("识别服务未及时返回文字，请重试；原有草稿已保留。")
            } else { self.complete() }
        }
    }

    func cancel() {
        guard isActive else { return }
        updateDraft?(originalDraft)
        cleanUp()
    }

    private func complete() {
        writeDiagnostic()
        if transcript.isEmpty { fail("没有识别到语音，原有草稿已保留。") }
        else { cleanUp() }
    }

    private func fail(_ reason: String) {
        updateDraft?(originalDraft)
        cleanUp()
        message = reason
    }

    private func stopAudio(deactivateSession: Bool = true) {
        if let engine {
            engine.stop()
            if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
            self.engine = nil
        }
        if deactivateSession, ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
    }

    // Only retain technical metadata from the last attempt, never audio or transcript.
    private func writeDiagnostic(errorCode: Int? = nil, errorDomain: String? = nil) {
        let value: [String: Any] = [
            "checkedAt": Date().ISO8601Format(), "phase": String(describing: phase),
            "elapsedSeconds": Date().timeIntervalSince(startedAt), "capturedFrames": capturedFrames,
            "sampleRate": sampleRate, "peakLevel": peakLevel, "textLength": transcript.count,
            "errorCode": errorCode as Any? ?? NSNull(), "errorDomain": errorDomain as Any? ?? NSNull()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .prettyPrinted),
              let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: folder.appendingPathComponent("dictation-last-attempt.json"), options: .atomic)
    }

    private func cleanUp() {
        generation = UUID() // Ignore late results from the previous recording.
        deadline?.cancel()
        deadline = nil
        recognition?.cancel()
        stopAudio()
        recognition = nil
        request = nil
        recognizer = nil
        updateDraft = nil
        isHeld = false
        phase = .idle
        audioLevel = 0
    }
}
