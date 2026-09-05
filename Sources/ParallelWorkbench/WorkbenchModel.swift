import SwiftUI
import AppKit
import Combine
import WorkbenchCore

/// 工作台模型：加载适配器、管理窗格（勾选 = 参与显示与发送）、分页与发送。
@MainActor
final class WorkbenchModel: ObservableObject {
    /// 同时最多显示的窗格数（超出用分页导航）
    static let maxVisiblePanes = 3

    @Published var panes: [PaneController] = []
    @Published var enabled: Set<String> = []
    @Published var question: String = ""
    @Published var statusText: String = ""
    @Published var loginProgress: String = ""
    @Published var sending = false
    @Published var focusedID: String? = nil
    @Published var windowStart: Int = 0
    private var cancellables: Set<AnyCancellable> = []
    private let preferencesStore: WorkbenchPreferencesStore

    init(preferencesStore: WorkbenchPreferencesStore = WorkbenchPreferencesStore()) {
        self.preferencesStore = preferencesStore
        let adapters = Adapter.loadAll()
        panes = adapters.map { PaneController(adapter: $0) }
        let adapterIDs = adapters.map(\.id)
        let preferences = preferencesStore.load(validAdapterIDs: adapterIDs)
        enabled = Set(preferences.enabledAdapterIDs)
        for pane in panes {
            pane.restoreZoom(preferences.zoomByAdapterID[pane.adapter.id])
        }
        windowStart = preferences.pageStart(
            validAdapterIDs: adapterIDs,
            maximumVisibleCount: Self.maxVisiblePanes
        )
        print("已加载适配器: \(adapters.map(\.name).joined(separator: "、"))")
        if adapters.isEmpty {
            statusText = "未加载到适配器配置（资源缺失，请查看日志）"
        }
        for pane in panes {
            pane.$status
                .sink { [weak self] _ in self?.updateLoginProgress() }
                .store(in: &cancellables)
            pane.$zoom
                .dropFirst()
                .sink { [weak self] zoom in
                    self?.persistPreferences(zoomOverride: (pane.adapter.id, zoom))
                }
                .store(in: &cancellables)
        }
        Publishers.CombineLatest($enabled, $windowStart)
            .dropFirst()
            .sink { [weak self] enabled, windowStart in
                self?.persistPreferences(enabledOverride: enabled, windowStartOverride: windowStart)
            }
            .store(in: &cancellables)
        updateLoginProgress()
    }

    /// 仅保存明确允许恢复的布局偏好；问题、附件、焦点与网页凭证均不进入此存储。
    private func persistPreferences(
        enabledOverride: Set<String>? = nil,
        windowStartOverride: Int? = nil,
        zoomOverride: (id: String, value: Double)? = nil
    ) {
        let adapterIDs = panes.map { $0.adapter.id }
        let enabledValue = enabledOverride ?? enabled
        let enabledIDs = adapterIDs.filter { enabledValue.contains($0) }
        let requestedStart = windowStartOverride ?? windowStart
        let start = min(max(requestedStart, 0), max(enabledIDs.count - Self.maxVisiblePanes, 0))
        let anchor = enabledIDs.indices.contains(start) ? enabledIDs[start] : nil

        var zooms = Dictionary(uniqueKeysWithValues: panes.map { ($0.adapter.id, $0.zoom) })
        if let zoomOverride {
            zooms[zoomOverride.id] = zoomOverride.value
        }
        preferencesStore.save(
            WorkbenchPreferences(
                enabledAdapterIDs: enabledIDs,
                pageAnchorAdapterID: anchor,
                zoomByAdapterID: zooms
            ),
            validAdapterIDs: adapterIDs
        )
    }

    /// 就绪进度：输入框可用窗格数 / 总数；游客模式就绪不等同于已登录。
    func updateLoginProgress() {
        let ready = panes.filter { $0.status == .ready }.count
        loginProgress = (panes.isEmpty || ready == panes.count) ? "" : "就绪 \(ready)/\(panes.count)"
    }

    var enabledPanes: [PaneController] {
        panes.filter { enabled.contains($0.adapter.id) }
    }

    /// 可见窗格：放大模式显示单个；否则显示勾选列表的当前分页窗口（最多 3 个）
    var visiblePanes: [PaneController] {
        if let f = focusedID, let pane = panes.first(where: { $0.adapter.id == f }) {
            return [pane]
        }
        let list = enabledPanes
        guard !list.isEmpty else { return [] }
        let start = min(windowStart, max(list.count - Self.maxVisiblePanes, 0))
        return Array(list[start..<min(start + Self.maxVisiblePanes, list.count)])
    }

    /// 勾选数超过上限时需要分页导航
    var needsPaging: Bool {
        enabledPanes.count > Self.maxVisiblePanes
    }

    /// 分页指示，如 "1-3 / 5"
    var pageIndicator: String {
        let list = enabledPanes
        guard needsPaging else { return "" }
        let start = min(windowStart, max(list.count - Self.maxVisiblePanes, 0))
        return "\(start + 1)-\(min(start + Self.maxVisiblePanes, list.count)) / \(list.count)"
    }

    func pageBackward() {
        windowStart = max(0, windowStart - 1)
    }

    func pageForward() {
        let list = enabledPanes
        windowStart = min(max(list.count - Self.maxVisiblePanes, 0), windowStart + 1)
    }

    func toggleFocus(_ id: String) {
        focusedID = (focusedID == id) ? nil : id
    }

    // MARK: - 版本更新

    /// 附件（base64 数据 + 元信息），随问题一并发送给所有勾选平台
    struct AttachmentItem: Identifiable {
        let id = UUID()
        let name: String
        let mime: String
        let data: String   // base64
        let size: Int
    }

    @Published var attachments: [AttachmentItem] = []

    func addAttachment(urls: [URL]) {
        for url in urls {
            guard url.isFileURL else {
                statusText = "只支持本地文件，已忽略网络 URL"
                continue
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 25 * 1024 * 1024 else {
                statusText = "附件超过 25MB 或无法读取：\(url.lastPathComponent)"
                continue
            }
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count == size else {
                statusText = "附件读取失败：\(url.lastPathComponent)"
                continue
            }
            let mime = mimeType(for: url.pathExtension)
            attachments.append(AttachmentItem(
                name: url.lastPathComponent,
                mime: mime,
                data: data.base64EncodedString(),
                size: data.count
            ))
        }
    }

    func addAttachmentImage(data: Data, name: String) {
        guard data.count <= 25 * 1024 * 1024 else { return }
        attachments.append(AttachmentItem(
            name: name, mime: "image/png", data: data.base64EncodedString(), size: data.count
        ))
    }

    func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        case "txt", "md": return "text/plain"
        case "doc", "docx": return "application/msword"
        case "xls", "xlsx": return "application/vnd.ms-excel"
        case "ppt", "pptx": return "application/vnd.ms-powerpoint"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }

    /// 附件转为注入配置
    var attachmentConfigs: [[String: Any]] {
        attachments.map { ["name": $0.name, "mime": $0.mime, "data": $0.data] }
    }

    /// 发现新版本时非空（值为版本号）
    @Published var updateAvailable: String? = nil
    @Published var updateStatus: String = ""
    @Published var updating = false

    /// 启动时自动检查（失败静默；手动检查会提示结果）
    func checkForUpdates(manual: Bool = false) {
        Task {
            if let rel = await Updater.fetchLatest() {
                await MainActor.run {
                    if Updater.isNewer(rel.version, than: Updater.currentVersion) {
                        updateAvailable = rel.version
                        updateStatus = "发现新版本 v\(rel.version)"
                    } else if manual {
                        statusText = "已是最新版本（v\(Updater.currentVersion)）"
                    }
                }
            } else if manual {
                await MainActor.run {
                    statusText = "检查更新失败（仓库未发布或网络不可达）"
                }
            }
        }
    }

    /// 一键更新：下载 → 覆盖安装 → 去隔离 → 重启到新版
    func performUpdate() {
        guard !updating else { return }
        updating = true
        updateStatus = "准备更新…"
        Task {
            guard let rel = await Updater.fetchLatest(), let dmg = rel.dmgURL else {
                await MainActor.run {
                    updating = false
                    updateStatus = "获取更新信息失败"
                }
                return
            }
            let ok = await Updater.install(dmgURL: dmg, expectedSHA256: rel.dmgSHA256, notes: rel.notes) { msg in
                Task { @MainActor in self.updateStatus = msg }
            }
            await MainActor.run {
                updating = false
                if ok {
                    updateStatus = "更新完成，正在重启…"
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/ParallelWorkbench.app"))
                    NSApp.terminate(nil)
                } else {
                    updateStatus = "更新失败，请稍后重试"
                }
            }
        }
    }

    func send() {
        guard !sending else { return }
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }   // 附件-only 允许发送
        let targets = enabledPanes
        guard !targets.isEmpty else {
            statusText = "没有勾选的模型窗口"
            return
        }
        sending = true
        statusText = "正在向 \(targets.count) 个窗口并发提交…"
        let atts = attachmentConfigs
        let sentQuestion = question
        let sentAtts = attachments
        // 所有任务立即启动；结果全部收齐后统一清空/回填，保持真正的平行发送。
        Task { @MainActor in
            let tasks = targets.map { pane in
                Task { @MainActor in
                    _ = await pane.send(text: text, attachments: atts)
                    return pane.lastResultOK == true
                }
            }
            var okCount = 0
            for task in tasks {
                if await task.value { okCount += 1 }
            }
            let failCount = targets.count - okCount
            if okCount > 0 {
                if question == sentQuestion { question = "" }
                let sentIDs = Set(sentAtts.map(\.id))
                attachments.removeAll { sentIDs.contains($0.id) }
                statusText = "已提交 \(okCount)/\(targets.count) 个窗口" +
                    (failCount > 0 ? "，\(failCount) 个失败" : "")
            } else {
                if question.isEmpty { question = sentQuestion }
                let currentIDs = Set(attachments.map(\.id))
                attachments.append(contentsOf: sentAtts.filter { !currentIDs.contains($0.id) })
                statusText = "全部窗口发送失败，问题与附件已回填"
            }
            sending = false
        }
    }

    func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { self.enabled.contains(id) },
            set: { on in
                if on {
                    self.enabled.insert(id)
                } else {
                    self.enabled.remove(id)
                    if self.focusedID == id { self.focusedID = nil }
                    // 取消勾选后修正分页窗口，避免空窗
                    let list = self.enabledPanes
                    self.windowStart = min(self.windowStart, max(list.count - Self.maxVisiblePanes, 0))
                }
            }
        )
    }
}
