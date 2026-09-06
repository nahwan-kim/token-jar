import XCTest

@MainActor
final class TokenTankUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.tokentank.TokenTank")
    private let timeout: TimeInterval = 10
    private func accessibilityText(_ element: XCUIElement) -> String {
        let ownValues = [
            element.label,
            element.title,
            element.value as? String ?? "",
        ]
        let childValues = element.descendants(matching: .any)
            .allElementsBoundByIndex
            .flatMap { child in
                [
                    child.label,
                    child.title,
                    child.value as? String ?? "",
                ]
            }
        return (ownValues + childValues).joined(separator: " ")
    }

    private func reveal(_ element: XCUIElement, in window: XCUIElement, deltaY: CGFloat = -400) {
        app.activate()
        window.click()
        let scrollView = window.scrollViews.firstMatch
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            scrollView.scroll(byDeltaX: 0, deltaY: deltaY)
        }
    }

    func testOpenStandaloneWindowReusesAndReopensWindow() {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appLanguage", "en"]
        app.launchEnvironment["TOKENTANK_DISABLE_AUTOSTART"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MATRIX"] = "1"
        app.launch()
        defer { app.terminate() }

        let popup = app.windows["Token Jar UI Test Detail"]
        XCTAssertTrue(popup.waitForExistence(timeout: timeout))
        let openButton = popup.buttons["action.open-window"]
        XCTAssertTrue(openButton.exists)
        openButton.click()

        let window = app.windows["Token Jar"]
        XCTAssertTrue(window.waitForExistence(timeout: timeout))
        XCTAssertTrue(window.buttons["action.refresh"].exists)
        XCTAssertFalse(window.buttons["action.open-window"].exists)
        XCTAssertTrue(window.descendants(matching: .any)["quota.ui-test.codex"].exists)

        popup.click()
        XCTAssertTrue(window.exists, "Moving focus away must not dismiss the standalone window")
        openButton.click()
        XCTAssertEqual(app.windows.matching(identifier: "Token Jar").count, 1)

        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: timeout))
        XCTAssertTrue(popup.exists, "Closing the window must leave the app running")
        openButton.click()
        XCTAssertTrue(window.waitForExistence(timeout: timeout))
    }

    func testSettingsRowsAlignAndSupportReordering() throws {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appLanguage", "en"]
        app.launchEnvironment["TOKENTANK_DISABLE_AUTOSTART"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MATRIX"] = "1"
        app.launchEnvironment["TOKENTANK_UI_SETTINGS"] = "1"
        app.launch()
        defer { app.terminate() }

        let settings = app.windows["Token Jar UI Test Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 45))
        settings.click()
        let codex = settings.checkBoxes["settings.visible.codex"]
        let claude = settings.checkBoxes["settings.visible.claude"]
        XCTAssertTrue(codex.waitForExistence(timeout: timeout))
        XCTAssertTrue(claude.exists)
        XCTAssertEqual(codex.frame.minX, claude.frame.minX, accuracy: 1)
        let codexUp = settings.buttons["settings.move-up.codex"]
        let claudeUp = settings.buttons["settings.move-up.claude"]
        XCTAssertEqual(codexUp.frame.minX, claudeUp.frame.minX, accuracy: 1)
        XCTAssertEqual(codexUp.frame.width, claudeUp.frame.width, accuracy: 1)
        XCTAssertLessThan(codex.frame.maxX, codexUp.frame.minX)
        XCTAssertEqual(codex.frame.midY, codexUp.frame.midY, accuracy: 2)
        XCTAssertFalse(settings.textFields["settings.abbreviation.codex"].exists)

        let percentSign = settings.checkBoxes["settings.summary.percent-sign"]
        reveal(percentSign, in: settings, deltaY: 400)
        XCTAssertTrue(percentSign.exists)
        XCTAssertEqual(percentSign.label, "Show % symbol")
        let originalPercentSign = try XCTUnwrap(percentSign.value as? NSNumber)
        percentSign.click()
        XCTAssertNotEqual(percentSign.value as? NSNumber, originalPercentSign)
        percentSign.click()
        XCTAssertEqual(percentSign.value as? NSNumber, originalPercentSign)

        let down = settings.buttons["settings.move-down.codex"]
        reveal(down, in: settings)
        down.click()
        XCTAssertLessThan(claude.frame.minY, codex.frame.minY)
        let up = settings.buttons["settings.move-up.codex"]
        reveal(up, in: settings)
        up.click()
        XCTAssertLessThan(codex.frame.minY, claude.frame.minY)

        let visibility = settings.checkBoxes["settings.visible.codex"]
        reveal(visibility, in: settings, deltaY: 400)
        let original = try XCTUnwrap(visibility.value as? NSNumber)
        visibility.click()
        XCTAssertNotEqual(visibility.value as? NSNumber, original)
        visibility.click()
        XCTAssertEqual(visibility.value as? NSNumber, original)

        let screenshot = XCTAttachment(screenshot: settings.screenshot())
        screenshot.name = "Settings — aligned provider rows"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertFalse(settings.descendants(matching: .any).matching(identifier: "Credentials").firstMatch.exists)

        let sourcesTab = settings.descendants(matching: .any)
            .matching(identifier: "Sources").firstMatch
        XCTAssertTrue(sourcesTab.waitForExistence(timeout: timeout))
        sourcesTab.click()
        XCTAssertTrue(
            settings.descendants(matching: .any)["settings.sources.content"]
                .waitForExistence(timeout: timeout)
        )
        let sourcesScreenshot = XCTAttachment(screenshot: settings.screenshot())
        sourcesScreenshot.name = "Settings — sources"
        sourcesScreenshot.lifetime = .keepAlways
        add(sourcesScreenshot)
    }
    func testUpdateSettingsToggleAndLocalizedDisclosures() throws {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appLanguage", "en"]
        app.launchEnvironment["TOKENTANK_DISABLE_AUTOSTART"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MATRIX"] = "1"
        app.launchEnvironment["TOKENTANK_UI_SETTINGS"] = "1"
        app.launch()

        defer { app.terminate() }

        let settings = app.windows["Token Jar UI Test Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 45))
        settings.click()

        let currentVersion = settings.descendants(matching: .any)
            .matching(identifier: "settings.updates.current-version")
            .firstMatch
        XCTAssertTrue(currentVersion.waitForExistence(timeout: timeout))
        let englishVersion = accessibilityText(currentVersion)
        XCTAssertTrue(englishVersion.contains("Current version:"))
        let versionRange = try XCTUnwrap(
            englishVersion.range(of: #"[0-9]+(?:\.[0-9]+){1,2} \([0-9]+\)"#, options: .regularExpression)
        )
        let versionAndBuild = String(englishVersion[versionRange])

        let automatic = settings.checkBoxes["settings.updates.automatic"]
        XCTAssertTrue(automatic.waitForExistence(timeout: timeout), settings.debugDescription)
        let original = try XCTUnwrap(automatic.value as? NSNumber)
        automatic.click()
        XCTAssertNotEqual(automatic.value as? NSNumber, original)
        automatic.click()
        XCTAssertEqual(automatic.value as? NSNumber, original)

        let checkNow = settings.buttons["settings.updates.check-now"]
        XCTAssertTrue(checkNow.waitForExistence(timeout: timeout), settings.debugDescription)

        let warning = settings.descendants(matching: .any)
            .matching(identifier: "settings.updates.manual-install-warning")
            .firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: timeout), settings.debugDescription)
        reveal(warning, in: settings)
        XCTAssertTrue(accessibilityText(warning).contains("unnotarized"))

        let privacy = settings.descendants(matching: .any)
            .matching(identifier: "settings.updates.privacy")
            .firstMatch
        XCTAssertTrue(privacy.waitForExistence(timeout: timeout), settings.debugDescription)
        XCTAssertTrue(accessibilityText(privacy).contains("GitHub"))
        XCTAssertTrue(accessibilityText(privacy).contains("IP"))

        let picker = settings.popUpButtons["settings.language.picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: timeout), settings.debugDescription)
        picker.click()
        app.menuItems["한국어"].click()

        XCTAssertTrue(
            warning.waitForExistence(timeout: timeout),
            settings.debugDescription
        )
        XCTAssertTrue(accessibilityText(warning).contains("공증되지"))
        XCTAssertTrue(accessibilityText(privacy).contains("GitHub"))
        XCTAssertTrue(accessibilityText(privacy).contains("IP"))
        XCTAssertTrue(accessibilityText(currentVersion).contains("현재 버전:"))
        XCTAssertTrue(accessibilityText(currentVersion).contains(versionAndBuild))
        XCTAssertEqual(settings.checkBoxes["settings.summary.percent-sign"].label, "% 기호 표시")

        picker.click()
        app.menuItems["English"].click()
    }

    func testLanguageSwitcherUpdatesOpenWindows() {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appLanguage", "en"]
        app.launchEnvironment["TOKENTANK_DISABLE_AUTOSTART"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MATRIX"] = "1"
        app.launchEnvironment["TOKENTANK_UI_SETTINGS"] = "1"
        app.launchEnvironment["TOKENTANK_UI_STANDALONE"] = "1"
        app.launch()
        defer { app.terminate() }
        let settings = app.windows["Token Jar UI Test Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 45))
        app.activate()
        settings.click()
        let picker = settings.popUpButtons["settings.language.picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: timeout), settings.debugDescription)

        let detail = app.windows["Token Jar UI Test Detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: timeout))
        let standaloneEnglish = app.windows["Token Jar"]
        XCTAssertTrue(standaloneEnglish.waitForExistence(timeout: timeout))
        settings.click()

        picker.click()
        app.menuItems["한국어"].click()
        let standaloneKorean = app.windows["토큰 항아리"]
        XCTAssertTrue(standaloneKorean.waitForExistence(timeout: timeout))
        XCTAssertFalse(app.windows["Token Jar"].exists)
        XCTAssertTrue(detail.buttons["action.quit"].waitForExistence(timeout: timeout))
        XCTAssertTrue(detail.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "action.quit", "토큰 항아리 종료")).firstMatch.waitForExistence(timeout: timeout))
        XCTAssertTrue(settings.popUpButtons.matching(NSPredicate(format: "value == %@", "주간")).firstMatch.exists)

        picker.click()
        app.menuItems["English"].click()
        let standaloneEnglishAgain = app.windows["Token Jar"]
        XCTAssertTrue(standaloneEnglishAgain.waitForExistence(timeout: timeout))
        XCTAssertFalse(app.windows["토큰 항아리"].exists)
        XCTAssertTrue(detail.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "action.quit", "Quit Token Jar")).firstMatch.waitForExistence(timeout: timeout))
        XCTAssertTrue(settings.popUpButtons.matching(NSPredicate(format: "value == %@", "Weekly")).firstMatch.exists)
    }
    func testFableUsesWeeklyGaugeLayout() {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["TOKENTANK_DISABLE_AUTOSTART"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MATRIX"] = "1"
        app.launch()
        defer { app.terminate() }

        let window = app.windows["Token Jar UI Test Detail"]
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

        let window = app.windows["Token Jar UI Test Detail"]
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

    func testCodexWeeklyAndTicketsUseTwoCompactColumns() {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appLanguage", "en"]
        app.launchEnvironment["TOKENTANK_DISABLE_AUTOSTART"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MATRIX"] = "1"
        app.launch()
        defer { app.terminate() }
        let window = app.windows["Token Jar UI Test Detail"]
        XCTAssertTrue(window.waitForExistence(timeout: timeout))
        let weekly = window.descendants(matching: .any)["quota.ui-test.codex"]
        let tickets = window.descendants(matching: .any)["provider.codex.reset-credits"]
        XCTAssertTrue(weekly.waitForExistence(timeout: timeout))
        XCTAssertTrue(tickets.exists)
        XCTAssertEqual(weekly.frame.minY, tickets.frame.minY, accuracy: 1)
        XCTAssertEqual(weekly.frame.width, tickets.frame.width, accuracy: 1)
        XCTAssertGreaterThan(tickets.frame.minX, weekly.frame.maxX)
        XCTAssertTrue(accessibilityText(tickets).contains("2"))
        XCTAssertEqual(tickets.descendants(matching: .any).matching(identifier: "provider.codex.ticket-expiry").count, 1)
        XCTAssertFalse(window.descendants(matching: .any)["quota.ui-test.codex.spark"].exists)
        XCTAssertLessThan(weekly.frame.height, 60)
    }

    func testEveryProviderShowsCompactRefreshAgeNextToStatus() {
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appLanguage", "en"]
        app.launchEnvironment["TOKENTANK_DISABLE_AUTOSTART"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MATRIX"] = "1"
        app.launch()
        defer { app.terminate() }
        let window = app.windows["Token Jar UI Test Detail"]
        XCTAssertTrue(window.waitForExistence(timeout: timeout))
        for (provider, statusID) in [("codex", "state.fresh"), ("claude", "state.stale"),
                                     ("grok", "state.authentication-required"), ("cursor", "state.stale"), ("doubao", "state.fresh")] {
            let group = window.descendants(matching: .any)["provider.\(provider)"]
            let age = group.descendants(matching: .any)["provider.\(provider).refreshed"]
            let status = group.descendants(matching: .any).matching(identifier: statusID).firstMatch
            XCTAssertTrue(age.waitForExistence(timeout: timeout))
            XCTAssertTrue(status.exists)
            XCTAssertLessThanOrEqual(age.frame.maxX, status.frame.minX)
            XCTAssertLessThan(age.frame.height, 20)
            XCTAssertFalse(accessibilityText(age).isEmpty)
        }
    }

    func testCompactAccountEmails() {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["TOKENTANK_DISABLE_AUTOSTART"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MATRIX"] = "1"
        app.launch()
        defer { app.terminate() }

        let detailWindow = app.windows["Token Jar UI Test Detail"]
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
    func testDualCodexAccountsShowLabelsEmailsAndDistinctPercentages() {
        continueAfterFailure = false
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-appLanguage", "en",
        ]
        app.launchEnvironment["TOKENTANK_DISABLE_AUTOSTART"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MATRIX"] = "1"
        app.launchEnvironment["TOKENTANK_UI_CODEX_ACCOUNTS"] = "1"
        app.launch()

        let detailWindow = app.windows["Token Jar UI Test Detail"]
        XCTAssertTrue(detailWindow.waitForExistence(timeout: timeout))
        defer { app.terminate() }

        let codexQuery = detailWindow.descendants(matching: .any)
            .matching(identifier: "provider.codex")
        let codex = codexQuery.firstMatch
        XCTAssertTrue(codex.waitForExistence(timeout: timeout))
        XCTAssertEqual(codexQuery.count, 1, "Dual-account Codex must remain one provider group")

        let accountIDs = [
            "provider.codex.account.codex.primary",
            "provider.codex.account.codex.secondary",
        ]
        let accounts = accountIDs.map { accountID in
            codex.descendants(matching: .any)
                .matching(identifier: accountID)
                .firstMatch
        }
        for account in accounts {
            XCTAssertTrue(account.waitForExistence(timeout: timeout))
        }

        let descendantIDs = codex.descendants(matching: .any)
            .allElementsBoundByIndex
            .map { $0.identifier }
        guard
            let primaryIndex = descendantIDs.firstIndex(of: accountIDs[0]),
            let secondaryIndex = descendantIDs.firstIndex(of: accountIDs[1])
        else {
            XCTFail("Codex account IDs must be present in the provider accessibility tree")
            return
        }
        XCTAssertLessThan(primaryIndex, secondaryIndex, "Codex accounts must keep stable primary-then-secondary order")

        let expectedAccounts = [
            (email: "work@example.com", remaining: "74%"),
            (email: "personal@example.com", remaining: "98%"),
        ]
        for (index, expected) in expectedAccounts.enumerated() {
            let account = accounts[index]
            XCTAssertFalse(account.descendants(matching: .any)["\(accountIDs[index]).alias"].exists)

            let email = account.descendants(matching: .any)
                .matching(identifier: "\(accountIDs[index]).email")
                .firstMatch
            XCTAssertTrue(email.waitForExistence(timeout: timeout))
            XCTAssertTrue(
                accessibilityText(email).contains("\(expected.email) · Plus"),
                "Missing account email \(expected.email)"
            )

            let percentage = account.descendants(matching: .any)
                .matching(identifier: "field.percentage")
                .firstMatch
            XCTAssertTrue(percentage.waitForExistence(timeout: timeout))
            XCTAssertTrue(
                accessibilityText(percentage).contains(expected.remaining),
                "Missing remaining percentage \(expected.remaining) for \(expected.email)"
            )
        }
    }

    func testDualCodexAccountStatusesAreIsolatedAndMenuContainsAliasesAndValues() {
        continueAfterFailure = false
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-appLanguage", "en",
        ]
        app.launchEnvironment["TOKENTANK_DISABLE_AUTOSTART"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MATRIX"] = "1"
        app.launchEnvironment["TOKENTANK_UI_CODEX_ACCOUNTS"] = "1"
        app.launchEnvironment["TOKENTANK_UI_CODEX_SECONDARY_FAILURE"] = "1"
        app.launch()

        let detailWindow = app.windows["Token Jar UI Test Detail"]
        XCTAssertTrue(detailWindow.waitForExistence(timeout: timeout))
        defer { app.terminate() }

        let codex = detailWindow.descendants(matching: .any)
            .matching(identifier: "provider.codex")
            .firstMatch
        XCTAssertTrue(codex.waitForExistence(timeout: timeout))

        let accountIDs = [
            "provider.codex.account.codex.primary",
            "provider.codex.account.codex.secondary",
        ]
        for accountID in accountIDs {
            let account = codex.descendants(matching: .any)
                .matching(identifier: accountID)
                .firstMatch
            XCTAssertTrue(account.waitForExistence(timeout: timeout))

            let statusQuery = account.descendants(matching: .any)
                .matching(identifier: "\(accountID).status")
            let status = statusQuery.firstMatch
            XCTAssertTrue(status.waitForExistence(timeout: timeout))
            XCTAssertEqual(statusQuery.count, 1, "Each Codex account must expose one isolated status element")
            XCTAssertFalse(accessibilityText(status).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertEqual(status.label, accountID.hasSuffix("primary") ? "Fresh" : "Authentication required")
        }

        let summary = app.statusItems
            .matching(identifier: "menu-bar.summary")
            .firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: timeout))
        let summaryText = accessibilityText(summary)
        XCTAssertFalse(summaryText.contains("Work"))
        XCTAssertFalse(summaryText.contains("Personal"))
        for expected in ["74% · 98%"] {
            XCTAssertTrue(
                summaryText.contains(expected),
                "Menu accessibility summary is missing \(expected): \(summaryText)"
            )
        }
    }

    func testMenuBarAccessibilityAndTermination() {
        continueAfterFailure = false
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["TOKENTANK_DISABLE_AUTOSTART"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MATRIX"] = "1"
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
        for expected in ["Codex", "100%", "Claude", "90%", "Grok", "Cursor", "Doubao"] {
            XCTAssertTrue(
                summaryText.contains(expected),
                "Menu summary is missing \(expected): \(summaryText)"
            )
        }

        let detailWindow = app.windows["Token Jar UI Test Detail"]
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
        reveal(doubaoQuota, in: detailWindow)
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
        reveal(detailWindow.descendants(matching: .any).matching(identifier: "quota.ui-test.codex").firstMatch,
               in: detailWindow, deltaY: 400)
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
        XCTAssertTrue((codexPercentage.value as? String)?.contains("Reset") == true,
                      "The combined quota accessibility value must include its visible reset countdown")
        for identifier in [
            "action.refresh",
            "action.waitForNextRefresh",
            "action.signInSourceApp",
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
        detailWindow.buttons["action.settings"].click()
        let settingsWindow = app.windows.containing(.any, identifier: "settings.providers.content").firstMatch
        XCTAssertTrue(
            settingsWindow.waitForExistence(timeout: 45),
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

        let detailWindow = app.windows["Token Jar UI Test Detail"]
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
    func testDualCodexGaugeScrollingReachesLowerProviders() {
        continueAfterFailure = false
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-appLanguage", "en",
        ]
        app.launchEnvironment["TOKENTANK_DISABLE_AUTOSTART"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MATRIX"] = "1"
        app.launchEnvironment["TOKENTANK_UI_CODEX_ACCOUNTS"] = "1"
        app.launch()

        let detailWindow = app.windows["Token Jar UI Test Detail"]
        XCTAssertTrue(detailWindow.waitForExistence(timeout: timeout))
        defer { app.terminate() }

        let codex = detailWindow.descendants(matching: .any)
            .matching(identifier: "provider.codex")
            .firstMatch
        XCTAssertTrue(codex.waitForExistence(timeout: timeout))
        XCTAssertTrue(
            codex.descendants(matching: .any)
                .matching(identifier: "field.percentage")
                .firstMatch
                .waitForExistence(timeout: timeout),
            "Dual-account Codex quota gauge must remain present before scrolling"
        )

        app.activate()
        detailWindow.click()
        let scrollView = detailWindow.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: timeout))

        let lowerProvider = detailWindow.descendants(matching: .any)
            .matching(identifier: "provider.doubao")
            .firstMatch
        XCTAssertTrue(lowerProvider.waitForExistence(timeout: timeout))
        XCTAssertFalse(lowerProvider.isHittable, "Lower provider should begin below the popup viewport")

        for _ in 0..<8 where !lowerProvider.isHittable {
            scrollView.scroll(byDeltaX: 0, deltaY: -240)
        }
        XCTAssertTrue(lowerProvider.isHittable, "Scrolling over the quota gauge must reveal lower providers")
    }
    func testKoreanDetailLocalization() {
        continueAfterFailure = false
        app.launchArguments = [
            "-AppleLanguages", "(ko)",
            "-AppleLocale", "ko_KR",
            "-appLanguage", "ko",
        ]
        app.launchEnvironment["TOKENTANK_DISABLE_AUTOSTART"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MATRIX"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MISSING_QUOTA"] = "1"
        app.launch()

        XCTAssertTrue(
            app.statusItems.matching(identifier: "menu-bar.summary").firstMatch
                .waitForExistence(timeout: timeout)
        )
        let detailWindow = app.windows["Token Jar UI Test Detail"]
        XCTAssertTrue(detailWindow.waitForExistence(timeout: timeout))
        let doubaoQuota = detailWindow.descendants(matching: .any)
            .matching(identifier: "quota.ui-test.doubao")
            .firstMatch
        reveal(doubaoQuota, in: detailWindow)
        XCTAssertTrue(doubaoQuota.waitForExistence(timeout: timeout))
        let missingUsed = doubaoQuota.descendants(matching: .any)
            .matching(identifier: "field.percentage")
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
            "-appLanguage", "",
        ]
        app.launchEnvironment["TOKENTANK_DISABLE_AUTOSTART"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MATRIX"] = "1"
        app.launchEnvironment["TOKENTANK_UI_MISSING_QUOTA"] = "1"
        app.launch()

        let detailWindow = app.windows["Token Jar UI Test Detail"]
        XCTAssertTrue(detailWindow.waitForExistence(timeout: timeout))
        let missingUsed = detailWindow.descendants(matching: .any)
            .matching(identifier: "quota.ui-test.doubao")
            .firstMatch
            .descendants(matching: .any)
            .matching(identifier: "field.percentage")
            .firstMatch
        reveal(missingUsed, in: detailWindow)
        XCTAssertTrue(
            missingUsed.waitForExistence(timeout: timeout)
                && (missingUsed.value as? String)?.contains("Not provided") == true,
            "Unknown system languages must fall back to English"
        )

        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: timeout))
    }
}
