import XCTest

/// These launch the real controls in a DEBUG-only, offline fixture. They do not claim
/// end-to-end YouTube playback, translation-model quality, haptics or real audio routing.
final class KodaComponentSmokeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testTranslationTapAndHoldAreExclusive() {
        let app = launch()
        app.buttons["fixture.translation"].tap()
        let orb = app.buttons["lyrics.translation.toggle"]
        XCTAssertTrue(orb.waitForExistence(timeout: 10))
        XCTAssertEqual(orb.value as? String, "Off")
        orb.tap()
        XCTAssertEqual(orb.value as? String, "On")
        orb.press(forDuration: 0.8)
        let done = app.buttons["lyrics.translation.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        XCTAssertEqual(app.switches.count, 0, "The details panel must not duplicate the display switch")
        capture(app, "translation-details")
        app.buttons["lyrics.translation.settings"].tap()
        XCTAssertTrue(app.navigationBars["Chinese Lyrics"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.switches["Show Chinese Translation"].exists)
        app.navigationBars["Chinese Lyrics"].buttons.element(boundBy: 0).tap()
        done.tap()
        XCTAssertTrue(orb.waitForExistence(timeout: 10))
        XCTAssertEqual(orb.value as? String, "On", "Releasing a long press must not also toggle")
        orb.tap()
        XCTAssertEqual(orb.value as? String, "Off")
        orb.tap()
        XCTAssertEqual(orb.value as? String, "On")
    }

    @MainActor
    func testLocalSongSelectionAndDeselectAll() {
        let app = launch()
        app.buttons["fixture.selection"].tap()
        let row = app.buttons["playlist.row.0"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let count = app.staticTexts["playlist.selection.count"]
        XCTAssertEqual(count.label, "0 selected")
        row.tap()
        XCTAssertEqual(count.label, "1 selected")
        app.buttons["playlist.selection.menu"].tap()
        app.buttons["playlist.selectAll"].tap()
        XCTAssertEqual(count.label, "2 selected")
        XCTAssertTrue(app.buttons["playlist.actions.menu"].isEnabled)
        capture(app, "playlist-selection")
        app.buttons["playlist.selection.menu"].tap()
        app.buttons["playlist.deselectAll"].tap()
        XCTAssertEqual(count.label, "0 selected")
        XCTAssertFalse(app.buttons["playlist.actions.menu"].isEnabled)
    }

    @MainActor
    func testMergingLocalPlaylistsPreservesSourcesAndExcludesExactDuplicates() {
        let app = launch()
        app.buttons["fixture.merge"].tap()
        let field = app.textFields["playlist.merge.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("UI Merged\n")
        for name in ["Fixture Beta", "Fixture Alpha"] {
            let choice = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "playlist.merge.choice.", name)).firstMatch
            reveal(choice, in: app)
            choice.tap()
        }
        let prepare = app.buttons["playlist.merge.prepare"]
        reveal(prepare, in: app)
        XCTAssertTrue(prepare.isEnabled)
        prepare.tap()
        let create = app.buttons["playlist.merge.create"]
        reveal(create, in: app)
        capture(app, "playlist-merge-preview")
        create.tap()
        // Successful persistence supplies Undo; no fixed sleeps or presumed task timing.
        reveal(app.buttons["Undo"], in: app, towardTop: true)
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["fixture.playlist.UI Merged"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["fixture.playlist.UI Merged"].label, "UI Merged: 3")
        XCTAssertEqual(app.staticTexts["fixture.playlist.Fixture Alpha"].label, "Fixture Alpha: 2")
        XCTAssertEqual(app.staticTexts["fixture.playlist.Fixture Beta"].label, "Fixture Beta: 2")
    }

    @MainActor
    func testDeviceSoundSettingsCanBeOpenedAndDisabled() {
        let app = launch()
        app.buttons["fixture.sound"].tap()
        let link = app.buttons["sound.deviceSettings"]
        reveal(link, in: app)
        link.tap()
        let automatic = app.switches["sound.automaticRouting"]
        XCTAssertTrue(automatic.waitForExistence(timeout: 10))
        XCTAssertEqual(automatic.value as? String, "0")
        automatic.tap()
        XCTAssertEqual(automatic.value as? String, "1")
        capture(app, "device-sound-settings")
        automatic.tap()
        XCTAssertEqual(automatic.value as? String, "0")
    }

    @MainActor
    func testTraditionalChineseLargeTypeInLightAndDarkAppearance() {
        for dark in [false, true] {
            let app = launch(chinese: true, dark: dark, largeText: true, reducedEffects: true)
            app.buttons["fixture.translation"].tap()
            let orb = app.buttons["lyrics.translation.toggle"]
            XCTAssertTrue(orb.waitForExistence(timeout: 10))
            XCTAssertTrue(orb.isHittable)
            XCTAssertGreaterThanOrEqual(orb.frame.width, 44)
            XCTAssertGreaterThanOrEqual(orb.frame.height, 44)
            orb.tap()
            XCTAssertEqual(orb.value as? String, "開啟")
            capture(app, dark ? "zh-Hant-large-dark" : "zh-Hant-large-light")
            app.navigationBars["Translation control"].buttons.element(boundBy: 0).tap()
            app.buttons["fixture.sound"].tap()
            let device = app.buttons["sound.deviceSettings"]
            reveal(device, in: app)
            device.tap()
            XCTAssertTrue(app.switches["sound.automaticRouting"].waitForExistence(timeout: 10))
            capture(app, dark ? "zh-Hant-sound-large-dark" : "zh-Hant-sound-large-light")
            app.terminate()
        }
    }

    @MainActor
    private func launch(chinese: Bool = false, dark: Bool = false, largeText: Bool = false,
                        reducedEffects: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-KodaUISmokeTests", "-AppleLanguages", chinese ? "(zh-Hant)" : "(en)",
                               "-AppleLocale", chinese ? "zh_TW" : "en_US"]
        if dark { app.launchArguments.append("-KodaUITestDark") }
        if largeText { app.launchArguments.append("-KodaUITestLargeText") }
        if reducedEffects { app.launchArguments.append("-KodaUITestReducedEffects") }
        app.launch()
        XCTAssertTrue(app.buttons["fixture.translation"].waitForExistence(timeout: 20))
        return app
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            if towardTop { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(element.exists && element.isHittable, "Expected a reachable control: \(element)")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
