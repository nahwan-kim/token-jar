import XCTest

@MainActor
final class TokenTankUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.tokentank.TokenTank")
    private let timeout: TimeInterval = 10

    func testLanguageSwitcherUpdatesOpenWindows() {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appLanguage", "en"]
        app.launchEnvironment["TOKENTANK_DISABLE_AUTOSTART"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MATRIX"] = "1"
        app.launchEnvironment["TOKENTANK_UI_SETTINGS"] = "1"
        app.launch()
        defer { app.terminate() }
        let settings = app.windows["Token Tank UI Test Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 45))
        let picker = settings.popUpButtons["settings.language.picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: timeout), settings.debugDescription)
        picker.click()
        app.menuItems["한국어"].click()
        let detail = app.windows["Token Tank UI Test Detail"]
        XCTAssertTrue(detail.buttons["action.quit"].waitForExistence(timeout: timeout))
        XCTAssertEqual(detail.buttons["action.quit"].label, "Token Tank 종료")
        XCTAssertTrue(settings.popUpButtons.matching(NSPredicate(format: "value == %@", "주간 한도")).firstMatch.exists)
        picker.click()
        app.menuItems["English"].click()
        XCTAssertEqual(detail.buttons["action.quit"].label, "Quit Token Tank")
        XCTAssertTrue(settings.popUpButtons.matching(NSPredicate(format: "value == %@", "Weekly limit")).firstMatch.exists)
    }
    func testFableUsesWeeklyGaugeLayout() {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["TOKENTANK_DISABLE_AUTOSTART"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MATRIX"] = "1"
        app.launch()
        defer { app.terminate() }

        let window = app.windows["Token Tank UI Test Detail"]
        XCTAssertTrue(window.waitForExistence(timeout: timeout))
        let weekly = window.descendants(matching: .any)["quota.ui-test.claude"]
        let fable = weekly.descendants(matching: .any)["quota.scoped.ui-test.claude.fable"]
        XCTAssertTrue(fable.waitForExistence(timeout: timeout))
        XCTAssertTrue(fable.label.contains("Fable"))
        XCTAssertEqual(fable.value as? String, "56%")
        let headline = weekly.descendants(matching: .any)["field.percentage"]
        XCTAssertGreaterThan(fable.frame.minY, headline.frame.maxY)
        XCTAssertEqual(fable.frame.width, headline.frame.width, accuracy: 1)
        XCTAssertGreaterThan(fable.frame.height, headline.frame.height + 3)
    }

    func testStatusUsesCompactLEDsInsteadOfText() {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["TOKENTANK_DISABLE_AUTOSTART"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MATRIX"] = "1"
        app.launch()
        defer { app.terminate() }

        let window = app.windows["Token Tank UI Test Detail"]
        XCTAssertTrue(window.waitForExistence(timeout: timeout))
        for identifier in ["detail.overall-status", "state.fresh", "state.stale", "state.authentication-required"] {
            let led = window.descendants(matching: .any).matching(identifier: identifier).firstMatch
            XCTAssertTrue(led.waitForExistence(timeout: timeout))
            XCTAssertNotEqual(led.elementType, .staticText)
            XCTAssertFalse(led.label.isEmpty, "Status remains available to VoiceOver")
            XCTAssertGreaterThan(led.frame.width, 0)
            XCTAssertLessThanOrEqual(led.frame.width, 14)
            XCTAssertLessThanOrEqual(led.frame.height, 14)
        }
        XCTAssertTrue(window.staticTexts["error.offline"].exists, "Actionable error details remain visible")
    }

    func testMultipleQuotasUseTwoColumns() {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["TOKENTANK_DISABLE_AUTOSTART"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MATRIX"] = "1"
        defer { app.terminate() }

        for count in [2, 3] {
            app.launchEnvironment["TOKENTANK_UI_QUOTA_COUNT"] = String(count)
            app.launch()
            let window = app.windows["Token Tank UI Test Detail"]
            XCTAssertTrue(window.waitForExistence(timeout: timeout))
            let first = window.descendants(matching: .any)["quota.ui-test.codex"]
            let second = window.descendants(matching: .any)["quota.ui-test.codex.2"]
            XCTAssertTrue(first.waitForExistence(timeout: timeout))
            XCTAssertTrue(second.waitForExistence(timeout: timeout))
            XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 1)
            XCTAssertEqual(first.frame.width, second.frame.width, accuracy: 1)
            XCTAssertGreaterThan(second.frame.minX, first.frame.maxX)

            let single = window.descendants(matching: .any)["quota.ui-test.claude"]
            XCTAssertTrue(single.exists)
            XCTAssertGreaterThan(single.frame.width, first.frame.width * 1.9)
            if count == 3 {
                let third = window.descendants(matching: .any)["quota.ui-test.codex.3"]
                XCTAssertTrue(third.exists)
                XCTAssertEqual(third.frame.minX, first.frame.minX, accuracy: 1)
                XCTAssertGreaterThan(third.frame.minY, first.frame.maxY)
            }
            app.terminate()
        }
    }

    func testCompactAccountEmails() {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["TOKENTANK_DISABLE_AUTOSTART"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MATRIX"] = "1"
        app.launch()
        defer { app.terminate() }

        let detailWindow = app.windows["Token Tank UI Test Detail"]
        XCTAssertTrue(detailWindow.waitForExistence(timeout: timeout))
        let codexAccount = detailWindow.staticTexts["provider.codex.account"]
        XCTAssertTrue(codexAccount.waitForExistence(timeout: timeout))
        XCTAssertEqual(codexAccount.value as? String ?? codexAccount.label, "codex@example.com")
        let codexName = detailWindow.staticTexts["provider.codex.name"]
        let codexPlan = detailWindow.staticTexts["provider.codex.plan"]
        XCTAssertTrue(codexName.exists)
        XCTAssertTrue(codexPlan.exists)
        XCTAssertGreaterThan(codexPlan.frame.minX, codexName.frame.maxX)
        XCTAssertLessThan(codexPlan.frame.minY, codexName.frame.maxY)
        XCTAssertLessThanOrEqual(codexPlan.frame.maxY, codexAccount.frame.minY)
        let claudeAccount = detailWindow.staticTexts["provider.claude.account"]
        XCTAssertTrue(claudeAccount.exists, "Stale snapshots retain their associated account")
        XCTAssertEqual(
            claudeAccount.value as? String ?? claudeAccount.label,
            "claude.long.account.name.for.compact.layout@example.com"
        )
        XCTAssertLessThanOrEqual(claudeAccount.frame.height, 20, "Account stays on one compact line")
        XCTAssertFalse(detailWindow.staticTexts["provider.doubao.account"].exists)
        XCTAssertFalse(detailWindow.staticTexts["provider.cursor.account"].exists)
    }

    func testMenuBarAccessibilityAndTermination() {
        continueAfterFailure = false
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["TOKENTANK_DISABLE_AUTOSTART"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MATRIX"] = "1"
        app.launchEnvironment["TOKENTANK_UI_SETTINGS"] = "1"
        app.launch()

        let statusItem = app.statusItems
            .matching(identifier: "menu-bar.summary")
            .firstMatch
        XCTAssertTrue(
            statusItem.waitForExistence(timeout: timeout),
            "The menu-bar-only app must publish its one-line status item"
        )
        let summaryText = [
            statusItem.title,
            statusItem.label,
            statusItem.value as? String ?? "",
        ].joined(separator: " ")
        XCTAssertFalse(summaryText.contains("\n"), "Menu summary must remain one line")
        for expected in ["CDX", "100%", "CLD", "90%", "GRK", "CUR", "DB"] {
            XCTAssertTrue(
                summaryText.contains(expected),
                "Menu summary is missing \(expected): \(summaryText)"
            )
        }

        let detailWindow = app.windows["Token Tank UI Test Detail"]
        XCTAssertTrue(
            detailWindow.waitForExistence(timeout: timeout),
            "The UITest configuration must host the real detail surface"
        )
        for identifier in [
            "provider.codex",
            "provider.claude",
            "provider.grok",
            "provider.cursor",
            "provider.doubao",
            "state.fresh",
            "state.stale",
            "state.authentication-required",
            "error.offline",
            "error.permissionDenied",
        ] {
            let element = detailWindow.descendants(matching: .any)
                .matching(identifier: identifier)
                .firstMatch
            XCTAssertTrue(
                element.waitForExistence(timeout: timeout),
                "Missing detail accessibility element: \(identifier)"
            )
        }
        for identifier in ["action.settings", "action.quit"] {
            XCTAssertTrue(
                app.buttons.matching(identifier: identifier).firstMatch
                    .waitForExistence(timeout: timeout),
                "Missing detail action: \(identifier)"
            )
        }
        let doubaoQuota = detailWindow.descendants(matching: .any)
            .matching(identifier: "quota.ui-test.doubao")
            .firstMatch
        XCTAssertTrue(doubaoQuota.waitForExistence(timeout: timeout))
        let doubaoPercentage = doubaoQuota.descendants(matching: .any)
            .matching(identifier: "field.percentage")
            .firstMatch
        XCTAssertTrue(doubaoPercentage.waitForExistence(timeout: timeout))
        XCTAssertTrue(
            doubaoPercentage.label.contains("Remaining percentage")
                && (doubaoPercentage.value as? String)?.contains("0 tokens") == true,
            "Zero remaining must stay distinct from a missing source value; label=\(doubaoPercentage.label), value=\(String(describing: doubaoPercentage.value))"
        )
        let codexPercentage = detailWindow.descendants(matching: .any)
            .matching(identifier: "quota.ui-test.codex")
            .firstMatch
            .descendants(matching: .any)
            .matching(identifier: "field.percentage")
            .firstMatch
        XCTAssertTrue(codexPercentage.waitForExistence(timeout: timeout))
        XCTAssertTrue(
            codexPercentage.label.contains("Remaining percentage")
                && (codexPercentage.value as? String)?.contains("100%") == true,
            "Gauge accessibility must match the prominently displayed remaining percentage; label=\(codexPercentage.label), value=\(String(describing: codexPercentage.value))"
        )
        let codexQuota = detailWindow.descendants(matching: .any)
            .matching(identifier: "quota.ui-test.codex")
            .firstMatch
        XCTAssertTrue(
            codexQuota.descendants(matching: .any)
                .matching(identifier: "field.reset")
                .firstMatch
                .waitForExistence(timeout: timeout),
            "Missing detail field: field.reset"
        )
        for identifier in [
            "action.refresh",
            "action.waitForNextRefresh",
            "action.signInTokenTank",
            "action.allowAccessInSystemSettings",
        ] {
            XCTAssertTrue(
                detailWindow.descendants(matching: .any)
                    .matching(identifier: identifier)
                    .firstMatch
                    .waitForExistence(timeout: timeout),
                "Missing recovery control: \(identifier)"
            )
        }
        let settingsWindow = app.windows["Token Tank UI Test Settings"]
        XCTAssertTrue(
            settingsWindow.waitForExistence(timeout: timeout),
            "The UITest configuration must host the real Settings surface"
        )
        let unavailableState = settingsWindow.staticTexts
            .matching(NSPredicate(format: "value CONTAINS %@", "Selected quota unavailable"))
            .firstMatch
        XCTAssertTrue(
            unavailableState.waitForExistence(timeout: timeout),
            "Missing frozen vanished representative state"
        )
        XCTAssertTrue(
            settingsWindow.buttons
                .matching(identifier: "action.choose-another.grok")
                .firstMatch
                .waitForExistence(timeout: timeout),
            "Missing vanished representative Choose another action"
        )

        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: timeout))
    }

    func testGaugeScrollingRemainsResponsive() {
        continueAfterFailure = false
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["TOKENTANK_DISABLE_AUTOSTART"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MATRIX"] = "1"
        app.launch()

        let detailWindow = app.windows["Token Tank UI Test Detail"]
        XCTAssertTrue(detailWindow.waitForExistence(timeout: timeout))
        app.activate()
        detailWindow.click()

        let scrollView = detailWindow.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: timeout))
        for _ in 0..<8 {
            scrollView.scroll(byDeltaX: 0, deltaY: 240)
            scrollView.scroll(byDeltaX: 0, deltaY: -240)
        }

        XCTAssertTrue(
            app.buttons.matching(identifier: "action.refresh").firstMatch
                .waitForExistence(timeout: timeout),
            "Repeated gauge scrolling must leave the popover responsive"
        )

        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: timeout))
    }
    func testKoreanDetailLocalization() {
        continueAfterFailure = false
        app.launchArguments = [
            "-AppleLanguages", "(ko)",
            "-AppleLocale", "ko_KR",
        ]
        app.launchEnvironment["TOKENTANK_DISABLE_AUTOSTART"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MATRIX"] = "1"
        app.launch()

        XCTAssertTrue(
            app.statusItems.matching(identifier: "menu-bar.summary").firstMatch
                .waitForExistence(timeout: timeout)
        )
        let detailWindow = app.windows["Token Tank UI Test Detail"]
        XCTAssertTrue(detailWindow.waitForExistence(timeout: timeout))
        let doubaoQuota = detailWindow.descendants(matching: .any)
            .matching(identifier: "quota.ui-test.doubao")
            .firstMatch
        XCTAssertTrue(doubaoQuota.waitForExistence(timeout: timeout))
        let missingUsed = doubaoQuota.descendants(matching: .any)
            .matching(identifier: "field.used")
            .firstMatch
        XCTAssertTrue(
            missingUsed.waitForExistence(timeout: timeout)
                && (missingUsed.value as? String)?.contains("제공 안 됨") == true,
            "Korean must use the frozen missing-value label"
        )
        for identifier in ["action.settings", "action.quit"] {
            XCTAssertTrue(
                app.buttons.matching(identifier: identifier).firstMatch
                    .waitForExistence(timeout: timeout)
            )
        }

        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: timeout))
    }

    func testUnknownLanguageFallsBackToEnglish() {
        continueAfterFailure = false
        app.launchArguments = [
            "-AppleLanguages", "(ja)",
            "-AppleLocale", "ja_JP",
        ]
        app.launchEnvironment["TOKENTANK_DISABLE_AUTOSTART"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MATRIX"] = "1"
        app.launch()

        let detailWindow = app.windows["Token Tank UI Test Detail"]
        XCTAssertTrue(detailWindow.waitForExistence(timeout: timeout))
        let missingUsed = detailWindow.descendants(matching: .any)
            .matching(identifier: "quota.ui-test.doubao")
            .firstMatch
            .descendants(matching: .any)
            .matching(identifier: "field.used")
            .firstMatch
        XCTAssertTrue(
            missingUsed.waitForExistence(timeout: timeout)
                && (missingUsed.value as? String)?.contains("Not provided") == true,
            "Unknown system languages must fall back to English"
        )

        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: timeout))
    }
}
