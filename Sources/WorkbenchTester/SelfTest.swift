import AppKit
import WebKit
import WorkbenchCore
import Foundation

/// 注入核心自检：用本地夹具页验证 inject.js/probe.js 的各条注入路径，不触网、不打扰真实平台。
enum SelfTest {
    static var window: NSWindow?

    struct Case {
        let name: String
        let cfg: [String: Any]
        let verify: String?     // JS 表达式返回 bool；nil = NO_INPUT 特例（Swift 侧断言）
    }

    static func run() async -> Int {
        let fm = FileManager.default
        let fixtureURL = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("Sources/WorkbenchTester/fixture.html")
        guard fm.fileExists(atPath: fixtureURL.path) else {
            print("FATAL: 夹具页缺失 \(fixtureURL.path)")
            return 2
        }

        let webView: WKWebView = await MainActor.run {
            let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
            let win = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 1000, height: 800),
                               styleMask: [.titled], backing: .buffered, defer: false)
            win.contentView = w
            win.orderFront(nil)
            window = win
            w.loadFileURL(fixtureURL, allowingReadAccessTo: fixtureURL.deletingLastPathComponent())
            return w
        }

        // 等待夹具页真正解析完成（初始空白页 readyState 也是 complete，须轮询夹具元素出现）
        let deadline = Date().addingTimeInterval(15)
        var ready = false
        while Date() < deadline {
            if let r = try? await eval(webView, "document.getElementById('react-input') !== null"), let b = r as? Bool, b {
                ready = true
                break
            }
            await pump(0.2)
        }
        guard ready else {
            print("FATAL: 夹具页加载失败")
            return 2
        }

        let text = "自检问题123"
        let cases: [Case] = [
            Case(name: "textarea 设值 + 合成回车", cfg: [
                "input": ["selectors": ["#react-input"]],
                "send": ["type": "enter"],
                "text": text
            ], verify: "window.__log.reactValue === '\(text)' && window.__log.reactEnter === true"),

            Case(name: "contenteditable + paragraph", cfg: [
                "input": ["selectors": ["#ce-editor"]],
                "send": ["type": "paragraph"],
                "text": text
            ], verify: "window.__log.ceValue !== null && window.__log.ceValue.includes('\(text)')"),

            Case(name: "Slate 结构清空占位后插入", cfg: [
                "input": ["selectors": ["#slate-editor"]],
                "send": ["type": "paragraph"],
                "text": text
            ], verify: "window.__log.slateValue !== null && window.__log.slateValue.includes('\(text)') && !window.__log.slateValue.includes('占位')"),

            Case(name: "输入后按钮启用并点击", cfg: [
                "input": ["selectors": ["#btn-input"]],
                "send": ["type": "button", "selectors": ["#send-btn"]],
                "text": text
            ], verify: "window.__log.btnValue === '\(text)' && window.__log.btnClicked === 1"),

            Case(name: "pointer 事件序列点击", cfg: [
                "input": ["selectors": ["#btn-input"]],
                "send": ["type": "pointer", "selectors": ["#send-btn"]],
                "text": text + "2"
            ], verify: "window.__log.btnClicked === 2"),

            Case(name: "附件注入：file input 赋值", cfg: [
                "input": ["selectors": ["#btn-input"]],
                "send": ["type": "enter"],
                "attachment": ["selectors": ["#file-input"]],
                "attachments": [
                    ["name": "tiny.png", "mime": "image/png",
                     "data": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="]
                ],
                "text": text
            ], verify: "window.__log.fileCount === 1 && window.__log.fileName === 'tiny.png'"),

            Case(name: "附件注入：拖放派发", cfg: [
                "input": ["selectors": ["#btn-input"]],
                "send": ["type": "enter"],
                "attachment": ["selectors": ["#drop-zone"], "forceDrop": true],
                "attachments": [
                    ["name": "doc.txt", "mime": "text/plain", "data": "aGVsbG8="]
                ],
                "text": text
            ], verify: "window.__log.dropCount === 1 && window.__log.dropName === 'doc.txt'"),

            Case(name: "NO_INPUT 回退与候选上报", cfg: [
                "input": ["selectors": ["#nope-missing"]],
                "send": ["type": "enter"],
                "text": text
            ], verify: nil)
        ]

        var failures = 0
        for c in cases {
            let js = InjectionScripts.build(InjectionScripts.injectJS, cfg: c.cfg)
            _ = try? await eval(webView, js)
            var got: Any? = nil
            for _ in 0..<50 {
                if let r = try? await eval(webView, "window.__wb_result || null"), !(r is NSNull) {
                    got = r
                    break
                }
                await pump(0.1)
            }
            let result = got as? [String: Any] ?? [:]
            let ok = result["ok"] as? Bool ?? false
            let sent = result["sent"] as? String ?? "-"
            var verified = false
            if let v = c.verify {
                if let r = try? await eval(webView, v), let b = r as? Bool {
                    verified = b
                }
            } else {
                // NO_INPUT 特例：直接在 Swift 侧断言结果字典
                let error = result["error"] as? String ?? ""
                let candidates = result["candidates"] as? [[String: Any]] ?? []
                verified = !ok && error == "NO_INPUT" && !candidates.isEmpty
            }
            let passed = (c.verify == nil) ? verified : (ok && verified)
            if passed {
                print("✅ \(c.name)（sent=\(sent)）")
            } else {
                var logDump = ""
                if let r = try? await eval(webView, "JSON.stringify(window.__log)"), let s2 = r as? String {
                    logDump = " __log=" + s2
                }
                print("❌ \(c.name)：ok=\(ok) sent=\(sent) verify=\(verified) result=\(result)\(logDump)")
                failures += 1
            }
        }

        // probe.js 自检（夹具中没有登录/验证元素，应全部为 false）
        let probeCfg: [String: Any] = [
            "input": ["selectors": ["#react-input"]],
            "probe": ["loggedOut": ["#logout"], "challenge": ["#challenge"], "loginModal": ["#login-modal"]]
        ]
        let probeJS = InjectionScripts.build(InjectionScripts.probeJS, cfg: probeCfg)
        var probeResult: [String: Any] = [:]
        if let r = try? await eval(webView, probeJS), let d = r as? [String: Any] {
            probeResult = d
        }
        let probeOK = (probeResult["input"] as? Bool ?? false)
            && !(probeResult["loggedOut"] as? Bool ?? true)
            && !(probeResult["challenge"] as? Bool ?? true)
            && !(probeResult["loginModal"] as? Bool ?? true)
        if probeOK {
            print("✅ probe.js 状态探测")
        } else {
            print("❌ probe.js：\(probeResult)")
            failures += 1
        }

        print(failures == 0 ? "\n自检全部通过 ✅" : "\n自检失败 \(failures) 项 ❌")
        return failures == 0 ? 0 : 1
    }

    private static func eval(_ w: WKWebView, _ js: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
            let run = {
                w.evaluateJavaScript(js) { result, error in
                    if let error { cont.resume(throwing: error) } else { cont.resume(returning: result) }
                }
            }
            if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
        }
    }

    private static func pump(_ seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            await MainActor.run {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
        }
    }
}
