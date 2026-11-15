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
        // Creation reports the saved local playlist. Undo is available for destructive
        // edits, not for creating a new playlist, which retains its normal Delete action.
        let saved = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@",
            "Created “UI Merged” with ")).firstMatch
        reveal(saved, in: app, towardTop: true)
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
    func testSleepTimerPresetsStartRealCountdownsAndCanBeCancelled() {
        let app = launch()
        app.buttons["fixture.sleep"].tap()
        let duration = app.buttons["sleep.timer.duration"]
        XCTAssertTrue(duration.waitForExistence(timeout: 10))
        for minutes in [30, 60, 90, 120, 180] {
            reveal(duration, in: app, towardTop: true)
            duration.tap()
            app.buttons["sleep.timer.duration.\(minutes)"].tap()
            let start = app.buttons["sleep.timer.start"]
            reveal(start, in: app)
            start.tap()
            let remaining = app.staticTexts["sleep.timer.remaining"]
            reveal(remaining, in: app, towardTop: true)
            let seconds = countdownSeconds(remaining.label)
            XCTAssertLessThanOrEqual(seconds, minutes * 60)
            XCTAssertGreaterThan(seconds, minutes * 60 - 60)
            XCTAssertTrue(app.staticTexts["sleep.timer.deadline"].exists)
            // End-of-song needs a real current occurrence. This fixture never resolves
            // an audio stream just to make a UI switch look functional.
            let endOfSong = app.buttons["sleep.timer.endOfSong"]
            reveal(endOfSong, in: app)
            XCTAssertFalse(endOfSong.isEnabled)
            let cancel = app.buttons["sleep.timer.cancel"]
            reveal(cancel, in: app, towardTop: true)
            cancel.tap()
            XCTAssertFalse(app.staticTexts["sleep.timer.remaining"].exists)
        }
    }

    @MainActor
    func testSleepTimerCustomDurationExtendResetAndExpiryChoices() {
        let app = launch()
        app.buttons["fixture.sleep"].tap()
        let expiry = app.buttons["sleep.timer.expiryAction"]
        reveal(expiry, in: app)
        XCTAssertEqual(expiry.value as? String, "Finish Playback Session")
        // Selecting an action changes only expiry behavior, not the schedule mode.
        expiry.tap()
        app.buttons["sleep.expiry.pause"].tap()
        XCTAssertEqual(expiry.value as? String, "Pause Playback")
        expiry.tap()
        app.buttons["sleep.expiry.finish"].tap()
        XCTAssertEqual(expiry.value as? String, "Finish Playback Session")
        let duration = app.buttons["sleep.timer.duration"]
        reveal(duration, in: app, towardTop: true)
        duration.tap()
        app.buttons["sleep.timer.custom"].tap()
        let minutes = app.textFields["sleep.timer.custom.minutes"]
        XCTAssertTrue(minutes.waitForExistence(timeout: 10))
        minutes.tap()
        let existing = (minutes.value as? String) ?? ""
        if !existing.isEmpty { minutes.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count)) }
        minutes.typeText("17")
        app.buttons["sleep.timer.keyboard.done"].tap()
        let start = app.buttons["sleep.timer.start"]
        reveal(start, in: app)
        start.tap()
        let remaining = app.staticTexts["sleep.timer.remaining"]
        reveal(remaining, in: app, towardTop: true)
        let initial = countdownSeconds(remaining.label)
        XCTAssertGreaterThan(initial, 16 * 60)
        XCTAssertLessThanOrEqual(initial, 17 * 60)
        let initialDeadline = app.staticTexts["sleep.timer.deadline"].label
        reveal(expiry, in: app)
        expiry.tap()
        app.buttons["sleep.expiry.pause"].tap()
        XCTAssertEqual(expiry.value as? String, "Pause Playback")
        reveal(remaining, in: app, towardTop: true)
        XCTAssertEqual(app.staticTexts["sleep.timer.deadline"].label, initialDeadline)
        XCTAssertGreaterThan(countdownSeconds(remaining.label), initial - 60,
                             "Changing expiry behavior must not replace the countdown")
        let beforeExtension = countdownSeconds(remaining.label)
        let extend = app.buttons["sleep.timer.extend"]
        reveal(extend, in: app)
        extend.tap()
        reveal(remaining, in: app, towardTop: true)
        XCTAssertGreaterThan(countdownSeconds(remaining.label), beforeExtension + 14 * 60)
        let reset = app.buttons["sleep.timer.reset"]
        reveal(reset, in: app)
        reset.tap()
        reveal(remaining, in: app, towardTop: true)
        XCTAssertGreaterThan(countdownSeconds(remaining.label), 16 * 60)
        XCTAssertLessThanOrEqual(countdownSeconds(remaining.label), 17 * 60)
        capture(app, "sleep-custom-countdown")
        let cancel = app.buttons["sleep.timer.cancel"]
        reveal(cancel, in: app)
        cancel.tap()
        XCTAssertFalse(app.staticTexts["sleep.timer.remaining"].exists)
    }

    @MainActor
    func testSleepTimerTraditionalChineseLargeTypeInBothAppearances() {
        for dark in [false, true] {
            let app = launch(chinese: true, dark: dark, largeText: true)
            app.buttons["fixture.sleep"].tap()
            let start = app.buttons["sleep.timer.start"]
            reveal(start, in: app)
            start.tap()
            let remaining = app.staticTexts["sleep.timer.remaining"]
            reveal(remaining, in: app, towardTop: true)
            XCTAssertGreaterThan(countdownSeconds(remaining.label), 0)
            capture(app, dark ? "zh-Hant-sleep-large-dark" : "zh-Hant-sleep-large-light")
            let cancel = app.buttons["sleep.timer.cancel"]
            reveal(cancel, in: app)
            XCTAssertTrue(cancel.isHittable)
            cancel.tap()
            app.terminate()
        }
    }

    @MainActor
    func testSystemAccessibilityPreferencesReachTheRealControls() throws {
        // EnvironmentValues exposes these settings read-only. Exercise Apple's real
        // Settings app instead of injecting an override that cannot represent the system.
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        var originalMotion: Bool?
        var originalTransparency: Bool?
        defer {
            if let originalTransparency {
                _ = try? setSystemAccessibility("Reduce Transparency", in: "Display & Text Size",
                                                enabled: originalTransparency, settings: settings)
            }
            if let originalMotion {
                _ = try? setSystemAccessibility("Reduce Motion", in: "Motion", enabled: originalMotion, settings: settings)
            }
            settings.terminate()
        }
        originalMotion = try setSystemAccessibility("Reduce Motion", in: "Motion", enabled: true, settings: settings)
        originalTransparency = try setSystemAccessibility("Reduce Transparency", in: "Display & Text Size",
                                                           enabled: true, settings: settings)
        let app = launch()
        let motion = app.staticTexts["fixture.accessibility.reduceMotion"]
        reveal(motion, in: app)
        XCTAssertEqual(motion.label, "enabled")
        let transparency = app.staticTexts["fixture.accessibility.reduceTransparency"]
        reveal(transparency, in: app)
        XCTAssertEqual(transparency.label, "enabled")
        let translation = app.buttons["fixture.translation"]
        reveal(translation, in: app, towardTop: true)
        translation.tap()
        let orb = app.buttons["lyrics.translation.toggle"]
        XCTAssertTrue(orb.waitForExistence(timeout: 10))
        orb.tap()
        XCTAssertEqual(orb.value as? String, "On")
        orb.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["lyrics.translation.done"].waitForExistence(timeout: 10))
        capture(app, "system-reduced-motion-and-transparency")
        app.buttons["lyrics.translation.done"].tap()
        XCTAssertEqual(orb.value as? String, "On")
        app.terminate()
    }

    @MainActor
    func testTraditionalChineseLargeTypeInLightAndDarkAppearance() {
        for dark in [false, true] {
            let app = launch(chinese: true, dark: dark, largeText: true)
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
    private func launch(chinese: Bool = false, dark: Bool = false, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-KodaUISmokeTests", "-AppleLanguages", chinese ? "(zh-Hant)" : "(en)",
                               "-AppleLocale", chinese ? "zh_TW" : "en_US"]
        if dark { app.launchArguments.append("-KodaUITestDark") }
        if largeText { app.launchArguments.append("-KodaUITestLargeText") }
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

    private func countdownSeconds(_ value: String, file: StaticString = #filePath, line: UInt = #line) -> Int {
        let parts = value.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard (2...3).contains(parts.count) else {
            XCTFail("Expected a real minute/second countdown, received: \(value)", file: file, line: line)
            return 0
        }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    @MainActor
    private func setSystemAccessibility(_ title: String, in page: String, enabled: Bool,
                                        settings: XCUIApplication) throws -> Bool {
        settings.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        settings.launch()
        // Settings may restore the previously visited detail page between launches.
        for _ in 0..<8 {
            if settings.navigationBars["Settings"].exists { break }
            let back = settings.navigationBars.buttons.element(boundBy: 0)
            guard back.exists && back.isHittable else { break }
            back.tap()
        }
        func open(_ label: String) throws {
            let row = settings.staticTexts.matching(identifier: label).firstMatch
            for _ in 0..<8 {
                if row.exists && row.isHittable { row.tap(); return }
                settings.swipeUp()
            }
            throw XCTSkip("This Simulator does not expose the Settings → Accessibility → \(label) page; system preference interaction was not validated.")
        }
        try open("Accessibility")
        try open(page)
        let toggle = settings.switches.matching(identifier: title).firstMatch
        for _ in 0..<8 {
            if toggle.exists && toggle.isHittable { break }
            settings.swipeUp()
        }
        guard toggle.exists && toggle.isHittable else {
            throw XCTSkip("This Simulator does not expose the \(title) system switch; system preference interaction was not validated.")
        }
        let original = toggle.value as? String == "1"
        if original != enabled { toggle.tap() }
        XCTAssertEqual(toggle.value as? String, enabled ? "1" : "0")
        return original
    }
}
