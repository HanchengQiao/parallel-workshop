import Foundation

/// 每个平台的适配器配置（与未来 Windows/Edge 扩展共享同一份 JSON schema）。
public struct Adapter: Codable {
    public struct InputSpec: Codable {
        public var selectors: [String]
        public init(selectors: [String]) { self.selectors = selectors }
    }

    public struct SendSpec: Codable {
        public var type: String        // "enter" | "button"
        public var selector: String?   // 兼容字段：仅 "button" 时的单个选择器
        public var selectors: [String]?  // "button" 时的 fallback 链
        public init(type: String, selector: String? = nil, selectors: [String]? = nil) {
            self.type = type
            self.selector = selector
            self.selectors = selectors
        }
    }

    public struct ProbeSpec: Codable {
        public var loggedOut: [String]?
        public var challenge: [String]?
        public var loginModal: [String]?
        public init(loggedOut: [String]? = nil, challenge: [String]? = nil, loginModal: [String]? = nil) {
            self.loggedOut = loggedOut
            self.challenge = challenge
            self.loginModal = loginModal
        }
    }

    /// 验收判定提示：某些平台（如 ChatGPT 游客模式）发送后不清空输入框，
    /// 改用"回答标志文本"判定是否真的生成了回答。
    public struct VerifySpec: Codable {
        public var responseIndicator: String?
        public init(responseIndicator: String? = nil) {
            self.responseIndicator = responseIndicator
        }
    }

    /// 发送前预动作：某些平台登录后落在落地页，需先点击入口（如「新建对话」）进入对话视图。
    public struct PrepareSpec: Codable {
        public var clickSelector: String?
        public var waitSeconds: Double?
        public init(clickSelector: String? = nil, waitSeconds: Double? = nil) {
            self.clickSelector = clickSelector
            self.waitSeconds = waitSeconds
        }
    }

    /// 附件注入目标选择器（文件输入框或拖放区）与唤起动作（如先点击工具箱按钮让上传面板渲染）；
    /// 缺省时自动发现 file input、回退编辑器拖放
    public struct AttachmentSpec: Codable {
        public var selectors: [String]?
        public var openSelectors: [String]?
        /// 强制走拖放路径（部分框架的 file input 不接受程序化赋值，但编辑器支持拖放）
        public var forceDrop: Bool?
        public init(selectors: [String]? = nil, openSelectors: [String]? = nil, forceDrop: Bool? = nil) {
            self.selectors = selectors
            self.openSelectors = openSelectors
            self.forceDrop = forceDrop
        }
    }

    public var id: String
    public var name: String
    public var origin: String
    public var input: InputSpec
    public var send: SendSpec
    public var probe: ProbeSpec?
    public var verify: VerifySpec?
    public var prepare: PrepareSpec?
    public var international: Bool?
    /// 归属域名：pane 当前 URL 不在其中时视为"漂移"（登录跳转后未回到对话页），UI 提供「回到对话」
    public var homeHosts: [String]?
    public var attachment: AttachmentSpec?

    public init(id: String, name: String, origin: String, input: InputSpec, send: SendSpec,
                probe: ProbeSpec? = nil, verify: VerifySpec? = nil, prepare: PrepareSpec? = nil,
                international: Bool? = nil, homeHosts: [String]? = nil, attachment: AttachmentSpec? = nil) {
        self.id = id
        self.name = name
        self.origin = origin
        self.input = input
        self.send = send
        self.probe = probe
        self.verify = verify
        self.prepare = prepare
        self.international = international
        self.homeHosts = homeHosts
        self.attachment = attachment
    }

    /// 从 adapters/*.json 加载全部适配器。
    public static func loadAll() -> [Adapter] {
        let dir = Resources.root().appendingPathComponent("adapters")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let adapter = try? JSONDecoder().decode(Adapter.self, from: data) else { return nil }
                return adapter
            }
    }

    /// 注入脚本用的配置对象（含问题文本与附件），序列化后替换 inject.js 里的 __CFG__。
    /// reqId：本次注入的操作编号，结果回执携带同一编号，防止快速连续发送时串读结果。
    public func injectionConfig(text: String, attachments: [[String: Any]] = [], noSend: Bool = false, reqId: String = "") -> [String: Any] {
        var cfg: [String: Any] = [
            "input": ["selectors": input.selectors],
            "send": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(send))) as? [String: Any] ?? ["type": "enter"],
            "text": text,
            "attachments": attachments,
            "reqId": reqId
        ]
        if let probe = probe {
            cfg["probe"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(probe))) ?? [:]
        }
        if let attachment = attachment {
            cfg["attachment"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(attachment))) ?? [:]
        }
        cfg["noSend"] = noSend
        return cfg
    }

    /// 状态探测脚本用的配置对象。
    public func probeConfig() -> [String: Any] {
        injectionConfig(text: "")
    }
}
