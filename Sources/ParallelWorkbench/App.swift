import SwiftUI
import AppKit
import Darwin

@main
struct ParallelWorkbenchApp: App {
    init() {
        // 关闭 stdout/stderr 缓冲，注入日志实时可见
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
    }

    var body: some Scene {
        WindowGroup("平行工作台") {
            ContentView()
                .frame(minWidth: 1280, minHeight: 780)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1520, height: 900)
    }
}
