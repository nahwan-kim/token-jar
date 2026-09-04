import XCTest

@MainActor
final class TokenTankUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.tokentank.TokenTank")
    private let timeout: TimeInterval = 10

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
        let missingUsed = doubaoQuota.descendants(matching: .any)
            .matching(identifier: "field.used")
            .firstMatch
        XCTAssertTrue(
            missingUsed.waitForExistence(timeout: timeout)
                && (missingUsed.value as? String)?.contains("Not provided") == true,
            "Missing source fields must use the frozen label"
        )
        let zeroRemaining = doubaoQuota.descendants(matching: .any)
            .matching(identifier: "field.remaining")
            .firstMatch
        XCTAssertTrue(
            zeroRemaining.waitForExistence(timeout: timeout)
                && (zeroRemaining.value as? String)?.contains("0 tokens") == true,
            "Zero must remain distinct from a missing source value"
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
        let doubaoPercentage = doubaoQuota.descendants(matching: .any)
            .matching(identifier: "field.percentage")
            .firstMatch
        XCTAssertTrue(
            doubaoPercentage.waitForExistence(timeout: timeout)
                && doubaoPercentage.label.contains("Remaining percentage"),
            "Missing percentages must retain explicit remaining-percentage semantics"
        )
        let codexQuota = detailWindow.descendants(matching: .any)
            .matching(identifier: "quota.ui-test.codex")
            .firstMatch
        for identifier in ["field.reset", "field.refreshed"] {
            XCTAssertTrue(
                codexQuota.descendants(matching: .any)
                    .matching(identifier: identifier)
                    .firstMatch
                    .waitForExistence(timeout: timeout),
                "Missing detail field: \(identifier)"
            )
        }
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
