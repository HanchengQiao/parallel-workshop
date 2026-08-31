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
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.035),
                    Color(nsColor: .windowBackgroundColor)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                paneRow
            }
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
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor, Color.accentColor.opacity(0.72)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)
                .shadow(color: Color.accentColor.opacity(0.22), radius: 6, y: 3)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text("平行工作台")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text("多模型同步工作区")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Label("⌘↩ 发送", systemImage: "command")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: Capsule())
                    .overlay(Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.45)))
            }

            // 主战场：大输入框 + 大发送按钮
            HStack(spacing: 10) {
                TextField("输入问题（Enter 换行，⌘↩ 或点「发送」同步到所有勾选的模型）", text: $model.question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .regular))
                    .lineLimit(2...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.96))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                inputFocused ? Color.accentColor.opacity(0.78) : Color(nsColor: .separatorColor).opacity(0.55),
                                lineWidth: inputFocused ? 1.5 : 1
                            )
                    )
                    .shadow(
                        color: inputFocused ? Color.accentColor.opacity(0.14) : Color.black.opacity(0.045),
                        radius: inputFocused ? 8 : 4,
                        y: 2
                    )
                    .focused($inputFocused)
                    .animation(.easeOut(duration: 0.16), value: inputFocused)

                Button(action: { voice.toggle() }) {
                    Image(systemName: voice.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(WorkbenchIconButtonStyle(tint: voice.isRecording ? .red : .accentColor, selected: voice.isRecording))
                .help(voice.isRecording ? "停止录音" : "语音输入（点击开始，再次点击结束）")

                Button(action: { model.send() }) {
                    Label("发送", systemImage: "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(WorkbenchPrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: [.command])
                .help("发送到所有勾选的模型（⌘↩）")
                .disabled(model.sending ||
                          (model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.attachments.isEmpty))
            }

            // 语音状态提示
            if !voice.statusText.isEmpty {
                HStack {
                    statusPill(
                        voice.statusText,
                        color: voice.isRecording ? .red : .secondary,
                        systemImage: voice.isRecording ? "waveform" : "mic"
                    )
                    Spacer()
                }
            }

            // 附件栏：已选附件 chips + 添加/拖放/粘贴
            if !model.attachments.isEmpty || true {
                HStack(spacing: 8) {
                    Button(action: { showFilePicker = true }) {
                        Label("附件", systemImage: "paperclip")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(WorkbenchSoftButtonStyle(tint: .accentColor))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.attachments) { att in
                                HStack(spacing: 5) {
                                    Image(systemName: "doc.fill")
                                        .font(.caption2)
                                        .foregroundStyle(Color.accentColor)
                                    Text(att.name)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                    Text(formatBytes(att.size))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Button(action: { model.removeAttachment(id: att.id) }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.secondary)
                                    .help("移除 \(att.name)")
                                }
                                .padding(.leading, 9)
                                .padding(.trailing, 6)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.075), in: Capsule())
                                .overlay(Capsule().stroke(Color.accentColor.opacity(0.16)))
                            }
                        }
                    }

                    Spacer(minLength: 6)

                    Text("可拖入文件 / 图片，或 ⌘V 粘贴图片")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary.opacity(0.78))
                        .fixedSize()
                }
            }

            // 控制行：平台勾选（= 参与显示与发送）+ 分页 + 状态
            HStack(spacing: 9) {
                ForEach(model.panes, id: \.adapter.id) { pane in
                    Toggle(pane.adapter.name, isOn: model.binding(for: pane.adapter.id))
                        .toggleStyle(WorkbenchPlatformToggleStyle())
                        .fixedSize()
                }

                if model.needsPaging {
                    HStack(spacing: 3) {
                        Button(action: { model.pageBackward() }) {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(WorkbenchMiniIconButtonStyle())
                        .disabled(model.windowStart == 0)
                        .help("上一页窗格")

                        Text(model.pageIndicator)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: 30)

                        Button(action: { model.pageForward() }) {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(WorkbenchMiniIconButtonStyle())
                        .disabled(model.windowStart >= model.enabledPanes.count - WorkbenchModel.maxVisiblePanes)
                        .help("下一页窗格")
                    }
                    .padding(3)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.78), in: Capsule())
                    .overlay(Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.45)))
                }

                if let f = model.focusedID {
                    Button(action: { model.toggleFocus(f) }) {
                        Label("退出放大", systemImage: "arrow.down.right.and.arrow.up.left")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(WorkbenchSoftButtonStyle(tint: .accentColor))
                }

                Spacer(minLength: 8)

                // 版本更新区
                if let v = model.updateAvailable {
                    Button("更新到 v\(v)") { model.performUpdate() }
                        .buttonStyle(WorkbenchSoftButtonStyle(tint: .accentColor, emphasized: true))
                        .disabled(model.updating)
                    if !model.updateStatus.isEmpty {
                        statusPill(model.updateStatus, color: .blue, systemImage: "arrow.down.circle")
                    }
                } else {
                    Button("检查更新") { model.checkForUpdates(manual: true) }
                        .buttonStyle(WorkbenchTextButtonStyle())
                    if !model.updateStatus.isEmpty {
                        statusPill(model.updateStatus, color: .secondary, systemImage: "checkmark.circle")
                    }
                }

                if !model.loginProgress.isEmpty {
                    statusPill(model.loginProgress, color: .orange, systemImage: "person.crop.circle.badge.clock")
                }
                if !model.statusText.isEmpty {
                    statusPill(model.statusText, color: .secondary, systemImage: "info.circle")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 11)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.48))
                .frame(height: 1)
        }
        .shadow(color: Color.black.opacity(0.045), radius: 9, y: 3)
        .zIndex(1)
    }

    private var paneRow: some View {
        GeometryReader { geo in
            if model.visiblePanes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Color.accentColor.opacity(0.72))
                    Text("尚未选择模型")
                        .font(.title3.weight(.semibold))
                    Text("在上方选择要参与显示和发送的平台")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.45))
                )
                .shadow(color: Color.black.opacity(0.055), radius: 14, y: 6)
                .frame(width: geo.size.width, height: geo.size.height)
            } else {
                // 每 pane 最小 420px（更窄会触发平台响应式布局、输入框消失）
                let count = CGFloat(model.visiblePanes.count)
                let paneSpacing: CGFloat = 10
                let paneInset: CGFloat = 12
                let availableWidth = geo.size.width - paneInset * 2 - paneSpacing * max(count - 1, 0)
                let paneWidth = max(availableWidth / count, 420)
                ScrollView(.horizontal) {
                    HStack(spacing: paneSpacing) {
                        ForEach(model.visiblePanes, id: \.adapter.id) { pane in
                            PaneView(
                                controller: pane,
                                focused: model.focusedID == pane.adapter.id,
                                onToggleFocus: { model.toggleFocus(pane.adapter.id) }
                            )
                            .frame(width: paneWidth)
                        }
                    }
                    .padding(.horizontal, paneInset)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    @ViewBuilder
    private func statusPill(_ text: String, color: Color, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.09), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.16)))
    }

    private func formatBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n)B" }
        if n < 1024 * 1024 { return String(format: "%.1fKB", Double(n) / 1024) }
        return String(format: "%.1fMB", Double(n) / 1024 / 1024)
    }
}

private struct WorkbenchPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WorkbenchPrimaryButtonBody(configuration: configuration)
    }
}

private struct WorkbenchPrimaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 23)
            .frame(height: 46)
            .background(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.74)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.white.opacity(isHovered ? 0.24 : 0.12))
            )
            .shadow(
                color: Color.accentColor.opacity(isEnabled ? (isHovered ? 0.28 : 0.19) : 0),
                radius: isHovered ? 10 : 7,
                y: isHovered ? 5 : 3
            )
            .scaleEffect(configuration.isPressed ? 0.965 : (isHovered ? 1.018 : 1))
            .opacity(isEnabled ? 1 : 0.48)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.16), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

private struct WorkbenchIconButtonStyle: ButtonStyle {
    let tint: Color
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        WorkbenchIconButtonBody(configuration: configuration, tint: tint, selected: selected)
    }
}

private struct WorkbenchIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(tint)
            .frame(width: 46, height: 46)
            .background(
                (selected ? tint.opacity(0.14) : Color(nsColor: .controlBackgroundColor).opacity(isHovered ? 0.96 : 0.78)),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke((selected || isHovered) ? tint.opacity(0.32) : Color(nsColor: .separatorColor).opacity(0.5))
            )
            .shadow(color: Color.black.opacity(isHovered ? 0.08 : 0.035), radius: isHovered ? 7 : 3, y: 2)
            .scaleEffect(configuration.isPressed ? 0.94 : (isHovered ? 1.025 : 1))
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.16), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

private struct WorkbenchSoftButtonStyle: ButtonStyle {
    let tint: Color
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        WorkbenchSoftButtonBody(configuration: configuration, tint: tint, emphasized: emphasized)
    }
}

private struct WorkbenchSoftButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    let emphasized: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.caption.weight(.medium))
            .foregroundStyle(emphasized ? Color.white : tint)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                emphasized ? tint : tint.opacity(isHovered ? 0.13 : 0.075),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(emphasized ? Color.white.opacity(0.15) : tint.opacity(isHovered ? 0.3 : 0.18))
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.13), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

private struct WorkbenchTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(Color.secondary.opacity(configuration.isPressed ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private struct WorkbenchMiniIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .background(Color.primary.opacity(configuration.isPressed ? 0.09 : 0), in: Circle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct WorkbenchPlatformToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        WorkbenchPlatformToggleBody(configuration: configuration)
    }
}

private struct WorkbenchPlatformToggleBody: View {
    let configuration: ToggleStyle.Configuration
    @State private var isHovered = false

    var body: some View {
        Button(action: { configuration.isOn.toggle() }) {
            HStack(spacing: 5) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                configuration.label
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(configuration.isOn ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 9)
            .frame(height: 27)
            .background(
                configuration.isOn ? Color.accentColor.opacity(isHovered ? 0.14 : 0.095) : Color(nsColor: .controlBackgroundColor).opacity(isHovered ? 0.94 : 0.68),
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(
                    configuration.isOn ? Color.accentColor.opacity(isHovered ? 0.36 : 0.23) : Color(nsColor: .separatorColor).opacity(0.45)
                )
            )
            .animation(.easeOut(duration: 0.15), value: configuration.isOn)
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
