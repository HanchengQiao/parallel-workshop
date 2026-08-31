import SwiftUI
import WebKit
import WorkbenchCore

private typealias PanePalette = WorkbenchPalette

/// 单个模型窗格视图：标题栏（平台名+状态+操作）+ WKWebView + 发送反馈提示。
struct PaneView: View {
    @ObservedObject var controller: PaneController
    var focused: Bool
    var onToggleFocus: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Rectangle()
                .fill(PanePalette.graphite.opacity(0.13))
                .frame(height: 1)
                .allowsHitTesting(false)
            ZStack(alignment: .topTrailing) {
                // 保持 WKWebView 原始渲染树，不加 clip / blur / scale / transition。
                WebViewRepresentable(webView: controller.webView)

                if !controller.lastLog.isEmpty {
                    Label(controller.lastLog, systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(PanePalette.warmWhite.opacity(0.96), in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(PanePalette.graphite.opacity(0.14))
                                .allowsHitTesting(false)
                        )
                        .foregroundStyle(PanePalette.graphite)
                        .shadow(color: PanePalette.graphite.opacity(0.08), radius: 5, y: 2)
                        .padding(10)
                        .allowsHitTesting(false)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // URL 漂移治理：登录跳转后未回到对话页时提供「回到对话」
                if controller.isDrifted {
                    Button(action: { controller.goHome() }) {
                        Label("回到对话", systemImage: "house.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(PaneAccentButtonStyle())
                    .padding(10)
                }

                // 未登录引导（不拦截鼠标，仅提示）
                if controller.status == .loggedOut {
                    VStack {
                        Spacer()
                        Label("在此窗格内登录，放大后操作更方便", systemImage: "person.crop.circle.badge.exclamationmark")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(PanePalette.graphite.opacity(0.68))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(PanePalette.warmWhite.opacity(0.96), in: Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(PanePalette.sage.opacity(0.24))
                                    .allowsHitTesting(false)
                            )
                            .shadow(color: PanePalette.graphite.opacity(0.06), radius: 5, y: 2)
                            .padding(10)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(PanePalette.warmWhite)
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(
                    focused ? PanePalette.sage.opacity(0.78) : PanePalette.graphite.opacity(isHovered ? 0.22 : 0.14),
                    lineWidth: focused ? 1.6 : 1
                )
                .allowsHitTesting(false)
        )
        .shadow(
            color: focused ? PanePalette.sage.opacity(0.1) : PanePalette.graphite.opacity(isHovered ? 0.065 : 0.035),
            radius: focused ? 7 : (isHovered ? 6 : 4),
            y: isHovered ? 3 : 2
        )
        .animation(.easeOut(duration: 0.18), value: focused)
        .animation(.easeOut(duration: 0.18), value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var headerBar: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(badgeColor.opacity(0.12))
                    .allowsHitTesting(false)
                Text(String(controller.adapter.name.prefix(1)))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(badgeColor)
                    .allowsHitTesting(false)
            }
            .frame(width: 23, height: 23)
            .overlay(
                Circle()
                    .stroke(badgeColor.opacity(0.18))
                    .allowsHitTesting(false)
            )

            Text(controller.adapter.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(PanePalette.graphite)

            statusBadge

            Spacer()

            // 缩放控制（解决平台界面宽于窗格的裁切）
            HStack(spacing: 1) {
                Button(action: { controller.zoomOut() }) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(PaneIconButtonStyle())
                .help("缩小页面（适应窗格宽度）")

                Button(action: { controller.resetZoom() }) {
                    Text("\(Int((controller.zoom * 100).rounded()))%")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(PanePalette.graphite.opacity(0.62))
                        .monospacedDigit()
                        .frame(minWidth: 36)
                }
                .buttonStyle(PaneZoomButtonStyle())
                .help("点击恢复 100%")

                Button(action: { controller.zoomIn() }) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(PaneIconButtonStyle())
                .help("放大页面")
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(PanePalette.graphite.opacity(0.035))
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(PanePalette.graphite.opacity(0.12))
                    .allowsHitTesting(false)
            )

            Button(action: onToggleFocus) {
                Image(systemName: focused
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(PaneIconButtonStyle(tint: focused ? PanePalette.sage : PanePalette.graphite.opacity(0.62), selected: focused))
            .help(focused ? "退出放大" : "放大此窗口（登录/阅读）")

            if controller.status != .ready {
                Button(action: { controller.reload() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(PaneIconButtonStyle(tint: PanePalette.graphite.opacity(0.62)))
                .help("重新加载该窗口")
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .background(PanePalette.warmWhite.opacity(0.98))
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(badgeColor)
                .frame(width: 5, height: 5)
            Text(controller.statusLabel)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(badgeColor.opacity(0.1), in: Capsule())
        .foregroundStyle(badgeColor)
        .overlay(
            Capsule()
                .stroke(badgeColor.opacity(0.16))
                .allowsHitTesting(false)
        )
    }

    private var badgeColor: Color {
        switch controller.status {
        case .loading: return PanePalette.graphite.opacity(0.48)
        case .ready: return PanePalette.sage
        case .loggedOut: return PanePalette.sage.opacity(0.72)
        case .challenge: return PanePalette.graphite.opacity(0.9)
        case .inputMissing: return PanePalette.graphite.opacity(0.7)
        case .unreachable: return PanePalette.graphite
        }
    }
}

private struct PaneIconButtonStyle: ButtonStyle {
    var tint: Color = PanePalette.graphite.opacity(0.62)
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        PaneIconButtonBody(configuration: configuration, tint: tint, selected: selected)
    }
}

private struct PaneIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 27, height: 25)
            .background(
                selected ? tint.opacity(0.15) : PanePalette.graphite.opacity(isHovered ? 0.065 : 0),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(selected ? tint.opacity(0.2) : Color.clear)
                    .allowsHitTesting(false)
            )
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(isEnabled ? 1 : 0.38)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

private struct PaneZoomButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .background(PanePalette.graphite.opacity(configuration.isPressed ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

private struct PaneAccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PaneAccentButtonBody(configuration: configuration)
    }
}

private struct PaneAccentButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(PanePalette.warmWhite)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(PanePalette.sage.opacity(isHovered ? 1 : 0.92), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.13), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
