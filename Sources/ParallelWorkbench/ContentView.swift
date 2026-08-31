import SwiftUI
import AppKit
import WorkbenchCore

struct ContentView: View {
    @StateObject private var model = WorkbenchModel()
    @StateObject private var voice = VoiceInput()
    @FocusState private var inputFocused: Bool
    @State private var showFilePicker = false
    @State private var questionBaseline = ""
    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            paneRow
        }
        .frame(minWidth: 1280, minHeight: 760)
        .onAppear {
            // 裸可执行文件启动的 GUI 应用：显式常规激活策略 + 激活，否则窗口收不到键盘输入
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            // 稍后把焦点钉到输入框（等窗口先成为 key window）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                inputFocused = true
            }
            // 启动后静默检查更新（有新版本时顶栏出现「更新到 vX」）
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                model.checkForUpdates()
            }
        }
        .onChange(of: voice.isRecording) { recording in
            // 开始录音时记录基线，结束后把转写追加到输入框
            if recording {
                questionBaseline = model.question
            } else if !voice.transcript.isEmpty {
                let base = questionBaseline.trimmingCharacters(in: .whitespacesAndNewlines)
                model.question = base.isEmpty ? voice.transcript : base + " " + voice.transcript
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.image, .pdf, .plainText, .data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                model.addAttachment(urls: urls)
            }
        }
        // 拖入文件 → 附件；粘贴图片 → 附件
        .dropDestination(for: URL.self) { urls, _ in
            model.addAttachment(urls: urls)
            return true
        }
        .onPasteCommand(of: [.image]) { providers in
            for provider in providers {
                _ = provider.loadDataRepresentation(for: .image) { data, _ in
                    if let data {
                        DispatchQueue.main.async {
                            model.addAttachmentImage(data: data, name: "粘贴图片-\(Int(Date().timeIntervalSince1970)).png")
                        }
                    }
                }
            }
        }
    }

    private var topBar: some View {
        VStack(spacing: 8) {
            // 主战场：大输入框 + 大发送按钮
            HStack(spacing: 12) {
                TextField("输入问题（Enter 换行，⌘↩ 或点「发送」同步到所有勾选的模型）", text: $model.question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .lineLimit(2...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.35)))
                    .focused($inputFocused)
                Button(action: { voice.toggle() }) {
                    Image(systemName: voice.isRecording ? "stop.circle.fill" : "mic.fill")
                        .font(.title3)
                        .foregroundColor(voice.isRecording ? .red : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .help(voice.isRecording ? "停止录音" : "语音输入（点击开始，再次点击结束）")
                Button(action: { model.send() }) {
                    Label("发送", systemImage: "paperplane.fill")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 26)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .help("发送到所有勾选的模型（⌘↩）")
                .disabled(model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.attachments.isEmpty)
            }
            // 语音状态提示
            if !voice.statusText.isEmpty {
                Text(voice.statusText)
                    .font(.caption)
                    .foregroundColor(voice.isRecording ? .red : .secondary)
                    .fixedSize()
            }
            // 附件栏：已选附件 chips + 添加/拖放/粘贴
            if !model.attachments.isEmpty || true {
                HStack(spacing: 8) {
                    Button(action: { showFilePicker = true }) {
                        Label("附件", systemImage: "paperclip")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    ForEach(model.attachments) { att in
                        HStack(spacing: 4) {
                            Image(systemName: "doc.fill")
                                .font(.caption2)
                            Text(att.name)
                                .font(.caption)
                                .lineLimit(1)
                            Text(formatBytes(att.size))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Button(action: { model.removeAttachment(id: att.id) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                    }
                    Text("可拖入文件/图片，或 ⌘V 粘贴图片")
                        .font(.caption2)
                        .foregroundColor(Color.secondary.opacity(0.7))
                }
                .padding(.horizontal, 2)
            }
            // 控制行：平台勾选（= 参与显示与发送）+ 分页 + 状态
            HStack(spacing: 12) {
                ForEach(model.panes, id: \.adapter.id) { pane in
                    Toggle(pane.adapter.name, isOn: model.binding(for: pane.adapter.id))
                        .toggleStyle(.checkbox)
                        .fixedSize()
                }
                if model.needsPaging {
                    Button(action: { model.pageBackward() }) {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.windowStart == 0)
                    .help("上一页窗格")
                    Text(model.pageIndicator)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                    Button(action: { model.pageForward() }) {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.windowStart >= model.enabledPanes.count - WorkbenchModel.maxVisiblePanes)
                    .help("下一页窗格")
                }
                if let f = model.focusedID {
                    Button("退出放大") { model.toggleFocus(f) }
                }
                // 版本更新区
                if let v = model.updateAvailable {
                    Button("更新到 v\(v)") { model.performUpdate() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.updating)
                    if !model.updateStatus.isEmpty {
                        Text(model.updateStatus)
                            .font(.caption)
                            .foregroundColor(.blue)
                            .fixedSize()
                    }
                } else {
                    Button("检查更新") { model.checkForUpdates(manual: true) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if !model.updateStatus.isEmpty {
                        Text(model.updateStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize()
                    }
                }
                if !model.loginProgress.isEmpty {
                    Text(model.loginProgress)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize()
                }
                if !model.statusText.isEmpty {
                    Text(model.statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize()
                }
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var paneRow: some View {
        GeometryReader { geo in
            if model.visiblePanes.isEmpty {
                VStack {
                    Spacer()
                    Text("未勾选任何模型 — 在上方勾选要参与的平台")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(width: geo.size.width)
            } else {
                // 每 pane 最小 420px（更窄会触发平台响应式布局、输入框消失）
                let count = CGFloat(model.visiblePanes.count)
                let paneWidth = max(geo.size.width / count, 420)
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(model.visiblePanes, id: \.adapter.id) { pane in
                            PaneView(
                                controller: pane,
                                focused: model.focusedID == pane.adapter.id,
                                onToggleFocus: { model.toggleFocus(pane.adapter.id) }
                            )
                            .frame(width: paneWidth)
                            if pane.adapter.id != model.visiblePanes.last?.adapter.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private func formatBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n)B" }
        if n < 1024 * 1024 { return String(format: "%.1fKB", Double(n) / 1024) }
        return String(format: "%.1fMB", Double(n) / 1024 / 1024)
    }
}