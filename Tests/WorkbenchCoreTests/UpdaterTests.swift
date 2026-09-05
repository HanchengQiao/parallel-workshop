import XCTest
@testable import WorkbenchCore

final class UpdaterTests: XCTestCase {
    func testReleaseNotesDigestExtraction() {
        let digest = String(repeating: "a", count: 64)
        let notes = """
        Release notes
        SHA256 ParallelWorkbench-0.2.1.dmg \(digest)
        """
        XCTAssertEqual(
            Updater.expectedSHA256(assetName: "ParallelWorkbench-0.2.1.dmg", notes: notes),
            digest
        )
    }

    func testDigestNormalizationFailsClosed() {
        XCTAssertNil(Updater.normalizedSHA256(nil))
        XCTAssertNil(Updater.normalizedSHA256("abc"))
        XCTAssertNil(Updater.normalizedSHA256(String(repeating: "z", count: 64)))
        XCTAssertEqual(
            Updater.normalizedSHA256(String(repeating: "A", count: 64)),
            String(repeating: "a", count: 64)
        )
    }

    func testVersionComparison() {
        XCTAssertTrue(Updater.isNewer("0.2.1", than: "0.2.0"))
        XCTAssertFalse(Updater.isNewer("0.2.0", than: "0.2.0"))
        XCTAssertFalse(Updater.isNewer("0.1.9", than: "0.2.0"))
    }

    func testDMGAssetVersionParsingFailsClosed() {
        XCTAssertEqual(Updater.versionFromDMGAssetName("ParallelWorkbench-1.2.3.dmg"), "1.2.3")
        XCTAssertNil(Updater.versionFromDMGAssetName("ParallelWorkbench-latest.dmg"))
        XCTAssertNil(Updater.versionFromDMGAssetName("edge-extension.zip"))
        XCTAssertNil(Updater.versionFromDMGAssetName("ParallelWorkbench-1.2.dmg"))
    }
}
