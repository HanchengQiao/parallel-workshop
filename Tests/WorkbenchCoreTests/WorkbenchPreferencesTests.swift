import XCTest
@testable import WorkbenchCore

final class WorkbenchPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: WorkbenchPreferencesStore!

    override func setUp() {
        super.setUp()
        suiteName = "WorkbenchPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = WorkbenchPreferencesStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFirstLaunchEnablesAllKnownAdapters() {
        let loaded = store.load(validAdapterIDs: ["chatgpt", "deepseek", "kimi"])

        XCTAssertEqual(loaded.schemaVersion, 1)
        XCTAssertEqual(loaded.enabledAdapterIDs, ["chatgpt", "deepseek", "kimi"])
        XCTAssertEqual(loaded.pageAnchorAdapterID, "chatgpt")
        XCTAssertTrue(loaded.zoomByAdapterID.isEmpty)
    }

    func testExistingPreferencesDoNotAutomaticallyEnableNewAdapter() {
        store.save(
            WorkbenchPreferences(
                enabledAdapterIDs: ["deepseek"],
                pageAnchorAdapterID: "deepseek",
                zoomByAdapterID: ["deepseek": 0.9]
            ),
            validAdapterIDs: ["chatgpt", "deepseek"]
        )

        let loaded = store.load(validAdapterIDs: ["chatgpt", "deepseek", "doubao"])

        XCTAssertEqual(loaded.enabledAdapterIDs, ["deepseek"])
        XCTAssertFalse(loaded.enabledAdapterIDs.contains("doubao"))
        XCTAssertEqual(loaded.pageAnchorAdapterID, "deepseek")
        XCTAssertEqual(loaded.zoomByAdapterID, ["deepseek": 0.9])
    }

    func testUnknownIDsAreFilteredAndZoomsAreClamped() throws {
        let raw = WorkbenchPreferences(
            enabledAdapterIDs: ["ghost", "kimi", "chatgpt"],
            pageAnchorAdapterID: "ghost",
            zoomByAdapterID: [
                "ghost": 1.1,
                "kimi": 9.0,
                "chatgpt": 0.1
            ]
        )
        defaults.set(try JSONEncoder().encode(raw), forKey: WorkbenchPreferencesStore.defaultKey)

        let loaded = store.load(validAdapterIDs: ["chatgpt", "deepseek", "kimi"])

        XCTAssertEqual(loaded.enabledAdapterIDs, ["chatgpt", "kimi"])
        XCTAssertEqual(loaded.pageAnchorAdapterID, "chatgpt")
        XCTAssertEqual(loaded.zoomByAdapterID["chatgpt"], 0.6)
        XCTAssertEqual(loaded.zoomByAdapterID["kimi"], 1.3)
        XCTAssertNil(loaded.zoomByAdapterID["ghost"])
    }

    func testCorruptDataFallsBackToSafeFirstLaunchDefaults() {
        defaults.set(Data("not-json".utf8), forKey: WorkbenchPreferencesStore.defaultKey)

        let loaded = store.load(validAdapterIDs: ["chatgpt", "deepseek"])

        XCTAssertEqual(loaded, .firstLaunch(adapterIDs: ["chatgpt", "deepseek"]))
    }

    func testUnsupportedSchemaFallsBackToSafeFirstLaunchDefaults() throws {
        let future = WorkbenchPreferences(
            schemaVersion: 99,
            enabledAdapterIDs: [],
            pageAnchorAdapterID: nil,
            zoomByAdapterID: [:]
        )
        defaults.set(try JSONEncoder().encode(future), forKey: WorkbenchPreferencesStore.defaultKey)

        let loaded = store.load(validAdapterIDs: ["chatgpt", "deepseek"])

        XCTAssertEqual(loaded, .firstLaunch(adapterIDs: ["chatgpt", "deepseek"]))
    }

    func testExplicitEmptySelectionSurvivesRoundTrip() {
        store.save(
            WorkbenchPreferences(enabledAdapterIDs: []),
            validAdapterIDs: ["chatgpt", "deepseek"]
        )

        let loaded = store.load(validAdapterIDs: ["chatgpt", "deepseek"])

        XCTAssertEqual(loaded.enabledAdapterIDs, [])
        XCTAssertNil(loaded.pageAnchorAdapterID)
    }

    func testPageAnchorRestoresSafeWindowStartAcrossCurrentAdapterOrder() {
        let preferences = WorkbenchPreferences(
            enabledAdapterIDs: ["a", "b", "c", "d", "e"],
            pageAnchorAdapterID: "d"
        )

        XCTAssertEqual(
            preferences.pageStart(
                validAdapterIDs: ["a", "b", "c", "d", "e"],
                maximumVisibleCount: 3
            ),
            2,
            "锚点位于末页时必须钳制到不会产生空白窗格的最大起点"
        )
        XCTAssertEqual(
            preferences.pageStart(
                validAdapterIDs: ["e", "d", "c", "b", "a"],
                maximumVisibleCount: 3
            ),
            1,
            "适配器排序变化后仍应按稳定 ID 找回锚点"
        )
    }

    func testStoredPayloadContainsOnlyWhitelistedPreferenceFields() throws {
        store.save(
            WorkbenchPreferences(
                enabledAdapterIDs: ["chatgpt"],
                pageAnchorAdapterID: "chatgpt",
                zoomByAdapterID: ["chatgpt": 1.1]
            ),
            validAdapterIDs: ["chatgpt"]
        )

        let data = try XCTUnwrap(defaults.data(forKey: WorkbenchPreferencesStore.defaultKey))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(
            Set(object.keys),
            Set(["schema", "enabledAdapterIDs", "pageAnchorAdapterID", "zoomByAdapterID"])
        )
        XCTAssertEqual(object["schema"] as? Int, 1)
        XCTAssertNil(object["question"])
        XCTAssertNil(object["attachments"])
        XCTAssertNil(object["focusedID"])
        XCTAssertNil(object["credentials"])
    }

    func testZoomNormalizationRejectsNonFiniteAndClampsBounds() {
        XCTAssertEqual(WorkbenchZoom.normalized(nil), 1.0)
        XCTAssertEqual(WorkbenchZoom.normalized(.nan), 1.0)
        XCTAssertEqual(WorkbenchZoom.normalized(.infinity), 1.0)
        XCTAssertEqual(WorkbenchZoom.normalized(0.2), 0.6)
        XCTAssertEqual(WorkbenchZoom.normalized(1.8), 1.3)
        XCTAssertEqual(WorkbenchZoom.normalized(0.95), 0.95)
    }
}
