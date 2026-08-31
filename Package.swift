// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ParallelWorkbench",
    platforms: [.macOS(.v13)],
    targets: [
        // 核心库：适配器 + 注入引擎 + 窗格控制器（GUI 与 CLI 测试器共享）
        .target(
            name: "WorkbenchCore",
            path: "Sources/WorkbenchCore",
            resources: [
                .copy("Resources/adapters"),
                .copy("Resources/injection")
            ]
        ),
        // macOS GUI 应用
        .executableTarget(
            name: "ParallelWorkbench",
            dependencies: ["WorkbenchCore"],
            path: "Sources/ParallelWorkbench"
        ),
        // 无人值守验收测试器（离屏 WKWebView + DOM 取证 + 截图）
        .executableTarget(
            name: "WorkbenchTester",
            dependencies: ["WorkbenchCore"],
            path: "Sources/WorkbenchTester"
        )
    ]
)
