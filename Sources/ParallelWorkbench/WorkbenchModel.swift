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
    @Published var focusedID: String? = nil
    @Published var windowStart: Int = 0
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let adapters = Adapter.loadAll()
        panes = adapters.map { PaneController(adapter: $0) }
        enabled = Set(adapters.map(\.id))
        print("已加载适配器: \(adapters.map(\.name).joined(separator: "、"))")
        if adapters.isEmpty {
            statusText = "未加载到适配器配置（资源缺失，请查看日志）"
        }
        for pane in panes {
            pane.$status
                .sink { [weak self] _ in self?.updateLoginProgress() }
                .store(in: &cancellables)
        }
        updateLoginProgress()
    }

    /// 登录进度：就绪窗格数 / 总数；全部就绪时隐藏
    func updateLoginProgress() {
        let ready = panes.filter { $0.status == .ready }.count
        loginProgress = (panes.isEmpty || ready == panes.count) ? "" : "已登录 \(ready)/\(panes.count)"
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
            guard let data = try? Data(contentsOf: url), data.count <= 25 * 1024 * 1024 else { continue }
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
            let ok = await Updater.install(dmgURL: dmg) { msg in
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
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }   // 附件-only 允许发送
        let targets = enabledPanes
        guard !targets.isEmpty else {
            statusText = "没有勾选的模型窗口"
            return
        }
        statusText = "已向 \(targets.count) 个窗口提交"
        let atts = attachmentConfigs
        let sentQuestion = question
        let sentAtts = attachments
        // 状态机：全部失败则回填；第一个成功才清空（防数据丢失）
        Task { @MainActor in
            var okCount = 0
            var failCount = 0
            for pane in targets {
                _ = await pane.send(text: text, attachments: atts)
                if pane.lastResultOK == true { okCount += 1 } else { failCount += 1 }
            }
            if okCount > 0 {
                question = ""
                attachments = []
                statusText = "已提交 \(okCount)/\(targets.count) 个窗口"
            } else {
                question = sentQuestion
                attachments = sentAtts
                statusText = "全部窗口发送失败，问题与附件已回填"
            }
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
                    // 取消勾选后修正分页窗口，避免空窗
                    let list = self.enabledPanes
                    self.windowStart = min(self.windowStart, max(list.count - Self.maxVisiblePanes, 0))
                }
            }
        )
    }
}
