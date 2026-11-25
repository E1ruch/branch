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
        app.tabBars.buttons["Сообщества"].tap()
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
        XCTAssertTrue(app.navigationBars["Сообщества"].waitForExistence(timeout: 8))

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
    func testEmailRegistrationAndRequiredNickname() async throws {
        let base = URL(string: ProcessInfo.processInfo.environment["VETKA_UI_TEST_API_URL"] ?? "http://localhost:8080")!
        guard let (_, response) = try? await URLSession.shared.data(from: base.appending(path: "/readyz")),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw XCTSkip("The local API must be ready at \(base)")
        }

        let app = XCUIApplication()
        app.launchEnvironment["VETKA_API_URL"] = base.absoluteString
        app.launch()
        app.tabBars.buttons["Профиль"].tap()
        let signIn = app.buttons["profile.signIn"]
        guard signIn.waitForExistence(timeout: 8) else {
            throw XCTSkip("Run on a signed-out simulator")
        }

        let suffix = UUID().uuidString.prefix(8).lowercased()
        let taken = "vetka_\(suffix)"
        let email = "vetka_\(suffix)@example.com"
        // The simulator may use a non-Latin system keyboard in secure fields.
        let password = String(Int.random(in: 10_000_000_000...99_999_999_999))
        let fixtureToken = try await Self.passwordToken(base, path: "register", email: "taken_\(suffix)@example.com", password: password)
        addTeardownBlock {
            _ = try? await Self.authRequest(base, path: "/v1/me", method: "DELETE", token: fixtureToken)
            if let token = try? await Self.passwordToken(base, path: "login", email: email, password: password) {
                _ = try? await Self.authRequest(base, path: "/v1/me", method: "DELETE", token: token)
            }
        }
        let (_, fixtureResponse) = try await Self.authRequest(base, path: "/v1/me", method: "PATCH",
            token: fixtureToken, json: ["username": taken])
        XCTAssertEqual(fixtureResponse.statusCode, 200)

        signIn.tap()
        app.buttons["Регистрация"].tap()
        fillAuthForm(app, email: email, password: password, registering: true)

        let title = app.staticTexts["onboarding.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Пропустить"].exists)
        let next = app.buttons["onboarding.continue"]
        XCTAssertFalse(next.isEnabled)

        app.terminate()
        app.launch()
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        app.buttons["onboarding.signOut"].tap()
        fillAuthForm(app, email: email, password: password)
        XCTAssertTrue(title.waitForExistence(timeout: 8))

        let username = app.textFields["onboarding.username"]
        username.tap()
        username.typeText(taken)
        XCTAssertTrue(app.staticTexts["Ник занят. Попробуйте другой."].waitForExistence(timeout: 8))
        XCTAssertFalse(next.isEnabled)
        screenshot(app, "nickname-taken")

        username.typeText("2")
        XCTAssertTrue(app.staticTexts["Ник свободен"].waitForExistence(timeout: 8))
        XCTAssertTrue(next.isEnabled)
        screenshot(app, "nickname-available")
        next.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 8))
        app.tabBars.buttons["Профиль"].tap()
        let settings = app.buttons["profile.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))

        let signedInToken = try await Self.passwordToken(base, path: "login", email: email, password: password)
        let (profile, ownerResponse) = try await Self.authRequest(base, path: "/v1/me", method: "GET", token: signedInToken)
        XCTAssertEqual(ownerResponse.statusCode, 200)
        let owner = try JSONSerialization.jsonObject(with: profile) as? [String: Any]
        XCTAssertEqual(owner?["username"] as? String, "\(taken)2")

        app.terminate()
        app.launch()
        app.tabBars.buttons["Профиль"].tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        XCTAssertFalse(title.exists)
    }

    @MainActor
    private func fillAuthForm(_ app: XCUIApplication, email: String, password: String, registering: Bool = false) {
        let emailField = app.textFields["auth.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 8))
        emailField.typeText(email)
        let passwordField = app.secureTextFields["auth.password"]
        passwordField.tap()
        if registering {
            // iOS may offer to generate a password on the first character.
            passwordField.typeText(String(password.prefix(1)))
            let suggestion = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                "надежный пароль", "strong password")).firstMatch
            if suggestion.waitForExistence(timeout: 2) {
                let close = app.buttons.matching(NSPredicate(format: "label IN %@",
                    ["Закрыть", "Close", "Отмена", "Cancel"])).allElementsBoundByIndex
                    .first { $0.isHittable && $0.frame.midY > passwordField.frame.maxY }
                if let close { close.tap() }
                else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.58)).tap() }
            }
            let hasFirstCharacter = (passwordField.value as? String)?.count == 1
            passwordField.typeText(hasFirstCharacter ? String(password.dropFirst()) : password)
        } else {
            passwordField.typeText(password)
        }
        let submit = app.buttons["auth.submit"]
        XCTAssertTrue(submit.isEnabled)
        if !submit.isHittable { app.scrollViews.firstMatch.swipeUp() }
        submit.tap()
    }

    private static func passwordToken(_ base: URL, path: String, email: String, password: String) async throws -> String {
        let (data, response) = try await authRequest(base, path: "/v1/auth/\(path)", method: "POST",
            json: ["email": email, "password": password])
        guard (200...201).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(body?["access_token"] as? String)
    }

    private static func authRequest(_ base: URL, path: String, method: String, token: String? = nil,
                                    json: [String: String]? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.httpBody = try JSONEncoder().encode(json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
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
