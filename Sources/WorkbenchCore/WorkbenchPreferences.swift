import Foundation

/// 工作台允许的网页缩放范围与统一清洗规则。
public enum WorkbenchZoom {
    public static let minimum = 0.6
    public static let maximum = 1.3

    public static func normalized(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 1.0 }
        return min(max(value, minimum), maximum)
    }
}

/// 用户可恢复的工作台外观/布局偏好。
///
/// 该结构刻意不包含问题文本、附件、聚焦窗格、网页数据或任何凭证。
public struct WorkbenchPreferences: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var enabledAdapterIDs: [String]
    public var pageAnchorAdapterID: String?
    public var zoomByAdapterID: [String: Double]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema"
        case enabledAdapterIDs
        case pageAnchorAdapterID
        case zoomByAdapterID
    }

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        enabledAdapterIDs: [String],
        pageAnchorAdapterID: String? = nil,
        zoomByAdapterID: [String: Double] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.enabledAdapterIDs = enabledAdapterIDs
        self.pageAnchorAdapterID = pageAnchorAdapterID
        self.zoomByAdapterID = zoomByAdapterID
    }

    /// 无已保存偏好时，首次启动默认启用当前全部平台。
    public static func firstLaunch(adapterIDs: [String]) -> Self {
        let ids = orderedUnique(adapterIDs)
        return Self(enabledAdapterIDs: ids, pageAnchorAdapterID: ids.first)
    }

    /// 只保留当前构建认识的平台，并把缩放约束到 WebView 支持的安全范围。
    /// 已存在偏好时不会自动把后续新增的平台加入 enabledAdapterIDs。
    public func sanitized(validAdapterIDs: [String]) -> Self {
        let validIDs = Self.orderedUnique(validAdapterIDs)
        let validSet = Set(validIDs)
        let savedEnabled = Set(enabledAdapterIDs)
        let enabled = validIDs.filter { savedEnabled.contains($0) }

        var zooms: [String: Double] = [:]
        for id in validIDs {
            guard let value = zoomByAdapterID[id], value.isFinite else { continue }
            zooms[id] = WorkbenchZoom.normalized(value)
        }

        let anchor: String?
        if let pageAnchorAdapterID,
           validSet.contains(pageAnchorAdapterID),
           savedEnabled.contains(pageAnchorAdapterID) {
            anchor = pageAnchorAdapterID
        } else {
            anchor = enabled.first
        }

        return Self(
            enabledAdapterIDs: enabled,
            pageAnchorAdapterID: anchor,
            zoomByAdapterID: zooms
        )
    }

    /// 把稳定的平台 ID 锚点还原为当前适配器顺序中的安全分页下标。
    public func pageStart(validAdapterIDs: [String], maximumVisibleCount: Int) -> Int {
        let safe = sanitized(validAdapterIDs: validAdapterIDs)
        let enabledSet = Set(safe.enabledAdapterIDs)
        let enabled = Self.orderedUnique(validAdapterIDs).filter { enabledSet.contains($0) }
        guard let anchor = safe.pageAnchorAdapterID,
              let anchorIndex = enabled.firstIndex(of: anchor) else { return 0 }
        let visibleCount = max(maximumVisibleCount, 1)
        return min(anchorIndex, max(enabled.count - visibleCount, 0))
    }

    private static func orderedUnique(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// WorkbenchPreferences 的 UserDefaults 存储边界。
/// 数据缺失与数据损坏是两种不同状态，但都安全回退到“首次启动”默认值。
public final class WorkbenchPreferencesStore {
    public static let defaultKey = "ParallelWorkbench.preferences.v1"

    private let defaults: UserDefaults
    private let key: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(defaults: UserDefaults = .standard, key: String = WorkbenchPreferencesStore.defaultKey) {
        self.defaults = defaults
        self.key = key
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func load(validAdapterIDs: [String]) -> WorkbenchPreferences {
        let fallback = WorkbenchPreferences.firstLaunch(adapterIDs: validAdapterIDs)
        guard let data = defaults.data(forKey: key),
              let decoded = try? decoder.decode(WorkbenchPreferences.self, from: data),
              decoded.schemaVersion == WorkbenchPreferences.currentSchemaVersion else {
            return fallback
        }
        return decoded.sanitized(validAdapterIDs: validAdapterIDs)
    }

    public func save(_ preferences: WorkbenchPreferences, validAdapterIDs: [String]) {
        let sanitized = preferences.sanitized(validAdapterIDs: validAdapterIDs)
        guard let data = try? encoder.encode(sanitized) else { return }
        defaults.set(data, forKey: key)
    }
}
