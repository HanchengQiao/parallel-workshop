import Speech
import AVFoundation

/// 语音输入：SFSpeechRecognizer 实时转写（免费、系统内置），结果经回调写入提问输入框。
@MainActor
final class VoiceInput: ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var statusText = ""

    private let recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    init() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    func start() {
        guard !isRecording else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .authorized:
                    self.beginRecording()
                default:
                    self.statusText = "需要麦克风与语音识别权限（系统设置 → 隐私与安全性 → 麦克风/语音识别）"
                    self.isRecording = false
                }
            }
        }
    }

    private func beginRecording() {
        guard let recognizer, recognizer.isAvailable else {
            statusText = "语音识别暂不可用"
            return
        }
        let engine = AVAudioEngine()
        audioEngine = engine
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            statusText = "麦克风启动失败：\(error.localizedDescription)"
            return
        }
        transcript = ""
        isRecording = true
        statusText = "正在聆听…（再点一次结束）"

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let text = result?.bestTranscription.formattedString, !text.isEmpty {
                    self.transcript = text
                }
                if error != nil || result?.isFinal == true {
                    self.statusText = ""
                    self.stop()
                }
            }
        }
    }

    func stop() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        request?.endAudio()
        task?.cancel()
        audioEngine = nil
        request = nil
        task = nil
        isRecording = false
        statusText = ""
    }
}
