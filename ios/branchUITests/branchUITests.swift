import XCTest

/// Smoke tests of the app shell. The communities test talks to the local
/// backend (`make infra-up run` in backend/); without it the test is skipped,
/// not failed.
final class branchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTabsSearchAndBackSwipe() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.collectionViews["feed.hot"].waitForExistence(timeout: 8))

        screenshot(app, "feed")
        app.tabBars.buttons["Поиск"].tap()
        let kotiki = app.staticTexts["Котики"]
        if !kotiki.waitForExistence(timeout: 10) {
            if app.staticTexts["Не удалось загрузить"].exists {
                throw XCTSkip("backend is not running on localhost:8080")
            }
            XCTFail("communities did not load")
        }
        screenshot(app, "communities")

        kotiki.tap()
        XCTAssertTrue(app.collectionViews["feed.community.new"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["community.subscribe"].waitForExistence(timeout: 8))
        screenshot(app, "community")
        app.buttons["Правила"].tap()
        XCTAssertTrue(app.scrollViews["community.rules"].waitForExistence(timeout: 4))

        // The interactive back-swipe from the left edge must keep working.
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertTrue(app.navigationBars["Поиск"].waitForExistence(timeout: 8))

        // Signed out or with a session left in the simulator's keychain.
        app.tabBars.buttons["Профиль"].tap()
        let signedOut = app.staticTexts["Вы не вошли"]
        let signedIn = app.buttons["Выйти"]
        XCTAssertTrue(signedOut.waitForExistence(timeout: 8) || signedIn.exists)
        screenshot(app, "profile")
    }

    @MainActor
    func testDeepLinkOpensRoute() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.collectionViews["feed.hot"].waitForExistence(timeout: 8))
        // Open the link the way another app would: through the system.
        XCUIDevice.shared.system.open(URL(string: "vetka://post/42")!)

        // iOS asks before a URL scheme opens an app from outside it; the
        // button is in the simulator's language.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Открыть", "Open"])).firstMatch
        if open.waitForExistence(timeout: 8) {
            open.tap()
        }
        XCTAssertTrue(app.collectionViews["thread"].waitForExistence(timeout: 8))
        screenshot(app, "deep link")
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
