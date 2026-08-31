import SwiftUI
import WebKit
import WorkbenchCore

/// 单个模型窗格视图：标题栏（平台名+状态+操作）+ WKWebView + 发送反馈提示。
struct PaneView: View {
    @ObservedObject var controller: PaneController
    var focused: Bool
    var onToggleFocus: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            ZStack(alignment: .topTrailing) {
                WebViewRepresentable(webView: controller.webView)
                if !controller.lastLog.isEmpty {
                    Text(controller.lastLog)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.65))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                        .padding(8)
                        .allowsHitTesting(false)
                }
                // URL 漂移治理：登录跳转后未回到对话页时提供「回到对话」
                if controller.isDrifted {
                    Button(action: { controller.goHome() }) {
                        Label("回到对话", systemImage: "house.fill")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(8)
                }
                // 未登录引导（不拦截鼠标，仅提示）
                if controller.status == .loggedOut {
                    VStack {
                        Spacer()
                        Text("在此窗格内登录（右上角放大更方便）")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 6) {
            Text(controller.adapter.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            statusBadge
            Spacer()
            // 缩放控制（解决平台界面宽于窗格的裁切）
            Button(action: { controller.zoomOut() }) {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("缩小页面（适应窗格宽度）")
            Text("\(Int((controller.zoom * 100).rounded()))%")
                .font(.caption2)
                .foregroundColor(.secondary)
                .monospacedDigit()
                .frame(minWidth: 34)
                .onTapGesture { controller.resetZoom() }
                .help("点击恢复 100%")
            Button(action: { controller.zoomIn() }) {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("放大页面")
            Button(action: onToggleFocus) {
                Image(systemName: focused
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help(focused ? "退出放大" : "放大此窗口（登录/阅读）")
            if controller.status != .ready {
                Button(action: { controller.reload() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("重新加载该窗口")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial)
    }

    private var statusBadge: some View {
        Text(controller.statusLabel)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.92))
            .foregroundColor(.white)
            .clipShape(Capsule())
    }

    private var badgeColor: Color {
        switch controller.status {
        case .loading: return .gray
        case .ready: return .green
        case .loggedOut: return .orange
        case .challenge: return .red
        case .inputMissing: return .purple
        case .unreachable: return .red
        }
    }
}

struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
