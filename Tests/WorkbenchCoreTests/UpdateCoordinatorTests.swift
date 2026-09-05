import XCTest
@testable import WorkbenchCore

@MainActor final class UpdateCoordinatorTests: XCTestCase {
    private func release(_ version: String) -> Updater.Release {
        Updater.Release(version: version,
                        dmgURL: "https://github.com/porcelaintech/parallel-workshop/releases/download/v\(version)/ParallelWorkbench-\(version).dmg",
                        notes: nil, dmgSHA256: String(repeating: "a", count: 64))
    }

    func testNoNewReleaseIsSuccessNotFailure() async {
        let current = release("1.0.0")
        let coordinator = UpdateCoordinator(currentVersion: "1.0.0", fetchRelease: { current }, relaunch: {})
        XCTAssertEqual(coordinator.buttonTitle, "Update / 检查更新")
        await coordinator.check(force: true)
        XCTAssertEqual(coordinator.phase, .current)
        XCTAssertNil(coordinator.availableVersion)
        XCTAssertNotNil(coordinator.lastCheckedAt)
        XCTAssertEqual(coordinator.message, "已是最新版本 v1.0.0")
        XCTAssertFalse(coordinator.message.contains("失败"))
    }

    func testNetworkFailureDoesNotClaimLatestAndCanRetry() async {
        var fails = true
        let latest = release("1.1.0")
        let coordinator = UpdateCoordinator(currentVersion: "1.0.0", fetchRelease: {
            if fails { throw URLError(.notConnectedToInternet) }
            return latest
        }, relaunch: {})
        await coordinator.check(force: true)
        XCTAssertEqual(coordinator.phase, .failed)
        XCTAssertNil(coordinator.lastCheckedAt)
        XCTAssertFalse(coordinator.message.contains("已是最新"))
        fails = false
        await coordinator.check(force: true)
        XCTAssertEqual(coordinator.phase, .available)
        XCTAssertEqual(coordinator.buttonTitle, "Update · v1.1.0")
    }

    func testActivationIsThrottledButManualCheckAlwaysRuns() async {
        var count = 0
        var instant = Date(timeIntervalSince1970: 10000)
        let current = release("1.0.0")
        let coordinator = UpdateCoordinator(currentVersion: "1.0.0", now: { instant }, fetchRelease: {
            count += 1
            return current
        }, relaunch: {})
        await coordinator.check(force: false)
        await coordinator.check(force: false)
        XCTAssertEqual(count, 1)
        await coordinator.check(force: true)
        XCTAssertEqual(count, 2)
        instant.addTimeInterval(301)
        await coordinator.check(force: false)
        XCTAssertEqual(count, 3)
    }

    func testFailureNeverRestartsAndRetryUsesValidatedRelease() async {
        let latest = release("1.1.0")
        var installs = 0
        var restarts = 0
        let coordinator = UpdateCoordinator(currentVersion: "1.0.0", fetchRelease: { latest }, installRelease: { rel, _ in
            XCTAssertEqual(rel.version, "1.1.0")
            installs += 1
            return installs == 2
        }, relaunch: { restarts += 1 })
        await coordinator.check(force: true)
        await coordinator.installAvailableUpdate()
        XCTAssertEqual(coordinator.phase, .failed)
        XCTAssertEqual(restarts, 0)
        await coordinator.installAvailableUpdate()
        XCTAssertEqual(coordinator.phase, .restarting)
        XCTAssertEqual(restarts, 1)
    }

    func testRelaunchFailureRetriesWithoutDownloadingAgain() async {
        let latest = release("1.1.0")
        var installs = 0
        var restartAttempts = 0
        let coordinator = UpdateCoordinator(currentVersion: "1.0.0", fetchRelease: { latest }, installRelease: { _, _ in
            installs += 1
            return true
        }, relaunch: {
            restartAttempts += 1
            if restartAttempts == 1 { throw NSError(domain: "fixture", code: 1) }
        })
        await coordinator.check(force: true)
        await coordinator.installAvailableUpdate()
        XCTAssertEqual(coordinator.phase, .failed)
        XCTAssertEqual(coordinator.buttonTitle, "重启更新")
        await coordinator.installAvailableUpdate()
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(restartAttempts, 2)
        XCTAssertEqual(coordinator.phase, .restarting)
    }

    func testConcurrentClicksDoNotStartDuplicateChecks() async {
        var count = 0
        let latest = release("1.1.0")
        let coordinator = UpdateCoordinator(currentVersion: "1.0.0", fetchRelease: {
            count += 1
            try await Task.sleep(nanoseconds: 30_000_000)
            return latest
        }, relaunch: {})
        async let first: Void = coordinator.check(force: true)
        async let second: Void = coordinator.check(force: true)
        _ = await (first, second)
        XCTAssertEqual(count, 1)
    }
}
