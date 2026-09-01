import Foundation
import CryptoKit

/// 版本更新：查询 GitHub Releases 最新版并一键更新。
/// 安全设计（开源未签名分发模型）：
/// 1. 下载后若 Release Notes 含该资产的 SHA256 行则强校验（防传输/供应链篡改）；
/// 2. 新应用先落地到 /Applications 内临时名，校验 Bundle ID 后再原子换名（mv 同卷原子），
///    任何一步失败都回滚恢复旧版本，绝不出现「旧版已删、新版未装」；
/// 3. 每个子进程检查退出码，非零即视为失败；
/// 4. 安装完成后对新应用去除隔离属性（未签名应用的启动必要步骤；用户主动点击更新即知情同意）。
public enum Updater {
    public struct Release {
        public let version: String
        public let dmgURL: String?
        public let notes: String?
        public let dmgSHA256: String?
    }

    /// 仓库配置：环境变量 PWB_REPO 优先
    public static var repo: String {
        ProcessInfo.processInfo.environment["PWB_REPO"] ?? "porcelaintech/parallel-workshop"
    }

    public static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    /// 拉取 GitHub Releases 最新版信息
    public static func fetchLatest() async -> Release? {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ParallelWorkbench/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let notes = json["body"] as? String
        let assets = json["assets"] as? [[String: Any]] ?? []
        let expectedName = "ParallelWorkbench-\(version).dmg"
        let dmgAsset = assets.first(where: { ($0["name"] as? String) == expectedName })
        let dmg = dmgAsset?["browser_download_url"] as? String
        let apiDigest = (dmgAsset?["digest"] as? String)?.replacingOccurrences(of: "sha256:", with: "")
        let digest = normalizedSHA256(apiDigest) ?? normalizedSHA256(expectedSHA256(assetName: expectedName, notes: notes))
        return Release(version: version, dmgURL: dmg, notes: notes, dmgSHA256: digest)
    }

    /// 简单语义版本比较：latest 是否高于 current
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        let a = latest.split(separator: ".").compactMap { Int($0) }
        let b = current.split(separator: ".").compactMap { Int($0) }
        guard !a.isEmpty, !b.isEmpty else { return latest != current }
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }

    /// 从 Release Notes 提取某资产名的 SHA256（格式：`SHA256 <文件名> <hex>`，可多行）
    static func expectedSHA256(assetName: String, notes: String?) -> String? {
        guard let notes else { return nil }
        for line in notes.split(separator: "\n") {
            let parts = String(line).split(separator: " ").map(String.init)
            if parts.count >= 3, parts[0].caseInsensitiveCompare("SHA256") == .orderedSame, parts[1] == assetName {
                return parts[2]
            }
        }
        return nil
    }

    static func normalizedSHA256(_ value: String?) -> String? {
        guard let value else { return nil }
        let digest = value.lowercased()
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { return nil }
        return digest
    }

    static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 下载 DMG → 校验 → 挂载 → 原子替换 /Applications → 去隔离 → 卸载镜像。
    /// 全程校验退出码；失败即回滚并返回 false。
    public static func install(dmgURL: String, expectedSHA256: String?, notes: String? = nil,
                               progress: @escaping (String) -> Void) async -> Bool {
        progress("正在下载新版本…")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pwb-update-\(UUID().uuidString).dmg")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let url = URL(string: dmgURL) else { return false }
        let assetName = url.lastPathComponent
        guard let expected = normalizedSHA256(expectedSHA256) ??
                normalizedSHA256(Self.expectedSHA256(assetName: assetName, notes: notes)) else {
            progress("校验失败：Release 未提供有效 SHA-256，已中止")
            return false
        }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
            let actual = sha256Hex(of: data)
            guard actual.lowercased() == expected else {
                progress("校验失败：下载文件哈希不匹配，已中止")
                return false
            }
            try data.write(to: tmp)
        } catch { return false }

        progress("正在安装…")
        // 1) 挂载
        guard let mountOutput = run("/usr/bin/hdiutil", ["attach", tmp.path, "-readonly", "-nobrowse"]),
              let mount = mountOutput.split(separator: "\n")
                .compactMap({ line -> String? in
                    let s = String(line)
                    guard s.contains("/Volumes/") else { return nil }
                    return s.components(separatedBy: "\t").last?.trimmingCharacters(in: .whitespaces)
                }).first else { return false }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount]) }

        // 2) 定位镜像内应用
        let srcs = [mount + "/ParallelWorkbench.app", mount + "/平行工作台.app"]
        guard let src = srcs.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return false }

        // 3) 校验新应用身份（Bundle ID 必须一致，防止装错包）
        let newInfoPlist = src + "/Contents/Info.plist"
        guard let newInfo = NSDictionary(contentsOfFile: newInfoPlist) as? [String: Any],
              let newBundleID = newInfo["CFBundleIdentifier"] as? String,
              newBundleID == "ParallelWorkbench" else {
            progress("校验失败：安装包 Bundle ID 不符，已中止")
            return false
        }

        // 4) 原子替换：先复制到同卷临时名（保留复制失败时旧版完好）
        let dest = "/Applications/ParallelWorkbench.app"
        let transaction = UUID().uuidString
        let staged = "/Applications/.ParallelWorkbench.app.new-\(transaction)"
        let backup = "/Applications/.ParallelWorkbench.app.old-\(transaction)"
        let hadOld = FileManager.default.fileExists(atPath: dest)

        _ = run("/bin/rm", ["-rf", staged])
        guard run("/bin/cp", ["-R", src, staged]) != nil,
              FileManager.default.isExecutableFile(atPath: staged + "/Contents/MacOS/ParallelWorkbench") else {
            progress("安装失败：新版本复制未完成，旧版本保留")
            _ = run("/bin/rm", ["-rf", staged])
            return false
        }
        // 同卷 replaceItemAt：替换失败时系统保留原目标，并生成可回滚备份。
        if hadOld {
            _ = run("/bin/rm", ["-rf", backup])
            do {
                _ = try FileManager.default.replaceItemAt(
                    URL(fileURLWithPath: dest),
                    withItemAt: URL(fileURLWithPath: staged),
                    backupItemName: URL(fileURLWithPath: backup).lastPathComponent,
                    options: []
                )
            } catch {
                _ = run("/bin/rm", ["-rf", staged])
                progress("安装失败：原版本保持不变")
                return false
            }
        } else {
            guard run("/bin/mv", [staged, dest]) != nil else {
                _ = run("/bin/rm", ["-rf", staged])
                progress("安装失败：新版本未安装")
                return false
            }
        }
        if hadOld { _ = run("/bin/rm", ["-rf", backup]) }

        // 5) 去隔离（未签名应用启动必要步骤）
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest])
        progress("更新完成")
        return true
    }

    /// 执行子进程：退出码非零视为失败（返回 nil）
    private static func run(_ bin: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            return nil
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: output, encoding: .utf8)
    }
}
