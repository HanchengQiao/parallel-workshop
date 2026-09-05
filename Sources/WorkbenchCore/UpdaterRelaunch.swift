import Foundation

extension Updater {
    /// 先准备独立进程，再由调用方终止旧应用；新应用只会在旧 PID 退出后打开。
    /// 等待上限一分钟，避免用户取消退出后产生悬挂的重启进程。
    public static func scheduleRelaunch(afterProcessID processID: Int32, applicationURL: URL) throws {
        let arguments = try relaunchArguments(afterProcessID: processID, applicationURL: applicationURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw UpdateError.relaunchFailed(error.localizedDescription) }
    }

    static func relaunchArguments(afterProcessID processID: Int32, applicationURL: URL) throws -> [String] {
        guard processID > 1, applicationURL.isFileURL, applicationURL.path.hasPrefix("/"),
              applicationURL.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: applicationURL), bundle.bundleIdentifier == "ParallelWorkbench",
              let executableURL = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw UpdateError.invalidApplication
        }
        // 路径和 PID 是位置参数，不拼接入脚本文本；空格、中文、引号均不产生命令注入。
        let script = """
        old_pid="$1"
        app_path="$2"
        attempts=0
        while /bin/kill -0 "$old_pid" 2>/dev/null; do
            attempts=$((attempts + 1))
            [ "$attempts" -lt 300 ] || exit 1
            /bin/sleep 0.2
        done
        exec /usr/bin/open -n "$app_path"
        """
        return ["-c", script, "parallel-workbench-relaunch", String(processID), applicationURL.path]
    }
}
