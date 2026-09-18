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
        originalDraft = draft
        updateDraft = update
        Task { [weak self] in
            let microphone = await AVAudioApplication.requestRecordPermission()
            guard let self, self.generation == id else { return }
            guard microphone else { self.fail("请在系统设置中允许 HealthKitSync 使用麦克风。"); return }
            let speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
            guard self.generation == id else { return }
            guard speech else { self.fail("请在系统设置中允许 HealthKitSync 使用语音识别。"); return }
            guard self.isHeld else {
                self.cleanUp()
                self.message = "语音输入已就绪，请再次按住麦克风说话。"
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
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            tapInstalled = true
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard let self, self.generation == id else { return }
                    if let text, !text.isEmpty {
                        self.transcript = text
                        self.updateDraft?(self.originalDraft + (self.originalDraft.isEmpty ? "" : "\n") + text)
                    }
                    if final { self.complete() }
                    else if failed { self.fail("语音识别未完成，请重试；原有草稿已保留。") }
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
        stopAudio()
        request?.endAudio()
        deadline?.cancel()
        let id = generation
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self, self.generation == id else { return }
            // Keep the last partial transcription if Apple doesn't finalize promptly.
            self.complete()
        }
    }

    func cancel() {
        guard isActive else { return }
        updateDraft?(originalDraft)
        cleanUp()
    }

    private func complete() {
        if transcript.isEmpty { fail("没有识别到语音，原有草稿已保留。") }
        else { cleanUp() }
    }

    private func fail(_ reason: String) {
        updateDraft?(originalDraft)
        cleanUp()
        message = reason
    }

    private func stopAudio() {
        if let engine {
            engine.stop()
            if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
            self.engine = nil
        }
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
    }

    private func cleanUp() {
        generation = UUID() // Ignore late results from the previous recording.
        deadline?.cancel()
        deadline = nil
        stopAudio()
        recognition?.cancel()
        recognition = nil
        request = nil
        recognizer = nil
        updateDraft = nil
        isHeld = false
        phase = .idle
    }
}
