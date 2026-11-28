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
        expectValue("Off", from: orb)
        orb.tap()
        expectValue("On", from: orb)
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
        expectValue("On", from: orb, because: "Releasing a long press must not also toggle")
        orb.tap()
        expectValue("Off", from: orb)
        orb.tap()
        expectValue("On", from: orb)
    }

    @MainActor
    func testCloudSongSelectionAndDeselectAll() {
        let app = launch()
        reveal(app.buttons["fixture.selection"], in: app)
        app.buttons["fixture.selection"].tap()
        let row = app.buttons["playlist.row.0"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        expectSelectionCount(0, in: app)
        row.tap()
        expectSelectionCount(1, in: app)
        app.buttons["playlist.selection.menu"].tap()
        app.buttons["playlist.selectAll"].tap()
        expectSelectionCount(2, in: app)
        expectState(app.buttons["playlist.actions.menu"], matching: NSPredicate(format: "exists == true AND enabled == true"))
        capture(app, "playlist-selection")
        app.buttons["playlist.selection.menu"].tap()
        app.buttons["playlist.deselectAll"].tap()
        expectSelectionCount(0, in: app)
        expectState(app.buttons["playlist.actions.menu"], matching: NSPredicate(format: "exists == true AND enabled == false"))
    }

    @MainActor
    func testMergingCloudPlaylistsPreservesSourcesAndExcludesExactDuplicates() {
        let app = launch()
        reveal(app.buttons["fixture.merge"], in: app)
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
            expectState(choice, matching: NSPredicate(format: "selected == true"))
        }
        let prepare = app.buttons["playlist.merge.prepare"]
        reveal(prepare, in: app)
        expectState(prepare, matching: NSPredicate(format: "enabled == true"))
        prepare.tap()
        let create = app.buttons["playlist.merge.create"]
        reveal(create, in: app)
        capture(app, "playlist-merge-preview")
        create.tap()
        // iOS 27 may expose the native confirmation action as both a wrapper
        // and a child button with the same identifier. They perform one action.
        let confirm = app.buttons.matching(identifier: "playlist.merge.confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        // The production coordinator must complete a remote read-back. The service
        // boundary is a deterministic actor, not a second local userPlaylist store.
        let saved = app.staticTexts["playlist.merge.result"]
        // The result is the final Form section. Searching toward the header can
        // never reveal it on a compact display after operation status is inserted.
        reveal(saved, in: app)
        XCTAssertTrue(saved.label.hasPrefix("Created “UI Merged” with "))
        app.navigationBars.buttons["Done"].tap()
        let localCount = app.staticTexts["fixture.localPlaylistCount"]
        reveal(localCount, in: app)
        XCTAssertEqual(localCount.label, "0")
        // The newly created row shifts the last source below a compact viewport.
        // Materialize each lazy List row before checking the unchanged contents.
        for (title, count) in [("UI Merged", 3), ("Fixture Alpha", 2), ("Fixture Beta", 2)] {
            let entry = app.staticTexts["fixture.playlist.\(title)"]
            reveal(entry, in: app)
            XCTAssertEqual(entry.label, "\(title): \(count)")
        }
    }

    @MainActor
    func testCloudCreationConfirmsRemoteResultWithoutLocalPlaylist() {
        let app = launch()
        reveal(app.buttons["fixture.cloud.create"], in: app)
        app.buttons["fixture.cloud.create"].tap()
        let name = app.textFields["cloud.create.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeText("UI Cloud Created\n")
        let create = app.buttons["cloud.create.submit"]
        reveal(create, in: app)
        create.tap()
        XCTAssertTrue(control("cloud.create.confirmed", in: app).waitForExistence(timeout: 10))
        capture(app, "cloud-playlist-confirmed")
        app.navigationBars.buttons["Done"].tap()
        let saved = app.staticTexts["fixture.playlist.UI Cloud Created"]
        reveal(saved, in: app)
        XCTAssertEqual(saved.label, "UI Cloud Created: 1")
        XCTAssertEqual(app.staticTexts["fixture.localPlaylistCount"].label, "0")
    }

    @MainActor
    func testCloudReadbackFailureCanBeConfirmedWithoutDuplicatingSongs() {
        let app = launch(extraArguments: ["-KodaUITestCloudReadbackFailure"])
        reveal(app.buttons["fixture.cloud.create"], in: app)
        app.buttons["fixture.cloud.create"].tap()
        let name = app.textFields["cloud.create.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeText("UI Retry\n")
        let create = app.buttons["cloud.create.submit"]
        reveal(create, in: app)
        create.tap()
        let retry = app.buttons["cloud.operation.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertFalse(control("cloud.create.confirmed", in: app).exists,
                       "A possibly completed write must not look confirmed before read-back")
        retry.tap()
        let detail = app.staticTexts["cloud.operation.detail"]
        expectState(detail, matching: NSPredicate(format: "label == %@", "Confirmed in YouTube Music."))
        app.navigationBars.buttons["Done"].tap()
        let saved = app.staticTexts["fixture.playlist.UI Retry"]
        reveal(saved, in: app)
        XCTAssertEqual(saved.label, "UI Retry: 1", "A retry verifies the prior write before sending another add")
        XCTAssertEqual(app.staticTexts["fixture.localPlaylistCount"].label, "0")
    }

    @MainActor
    func testCloudHomeShowsDirectPlaybackControlsWithoutLocalPlaylists() {
        let app = launch()
        reveal(app.buttons["fixture.home"], in: app)
        app.buttons["fixture.home"].tap()
        XCTAssertTrue(control("home.cloud.title", in: app).waitForExistence(timeout: 10))
        let play = app.buttons["home.cloud.play.PLui-alpha"]
        let shuffle = app.buttons["home.cloud.shuffle.PLui-alpha"]
        reveal(play, in: app)
        XCTAssertTrue(play.isEnabled)
        XCTAssertTrue(shuffle.isEnabled)
        XCTAssertGreaterThanOrEqual(play.frame.height, 44)
        XCTAssertGreaterThanOrEqual(shuffle.frame.height, 44)
        XCTAssertTrue(app.buttons["home.cloud.create"].exists)
        capture(app, "cloud-home-direct-controls")
        // Stream playback is covered by queue/Flow logic tests, not fabricated here.
    }

    @MainActor
    func testCachedHomeSurvivesRefreshFailureAndReentry() {
        let app = launch(extraArguments: ["-KodaUITestCatalogFailure"])
        let count = app.staticTexts["fixture.cloud.requestCount"]
        expectState(count, matching: NSPredicate(format: "label == %@", "1"))
        reveal(app.buttons["fixture.home"], in: app)
        app.buttons["fixture.home"].tap()
        reveal(control("home.cloud.error", in: app), in: app, towardTop: true)
        let play = app.buttons["home.cloud.play.PLui-alpha"]
        reveal(play, in: app)
        XCTAssertTrue(play.isEnabled, "A refresh failure must not discard the known cloud playlist")
        let recent = app.buttons["home.listening.song.ui-smoke-a"]
        reveal(recent, in: app)
        XCTAssertTrue(recent.isEnabled, "Real listening history must remain available outside collapsed recommendations")
        capture(app, "home-cached-playlists-refresh-failed")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        reveal(count, in: app, towardTop: true)
        expectState(count, matching: NSPredicate(format: "label == %@", "1"))
        reveal(app.buttons["fixture.home"], in: app)
        app.buttons["fixture.home"].tap()
        XCTAssertTrue(control("home.cloud.error", in: app).waitForExistence(timeout: 10))
        let retry = app.buttons["home.cloud.retry"]
        reveal(retry, in: app, towardTop: true)
        retry.tap()
        reveal(play, in: app)
        XCTAssertTrue(play.isEnabled)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        reveal(count, in: app, towardTop: true)
        expectState(count, matching: NSPredicate(format: "label == %@", "2"),
                    because: "Only explicit Retry should fetch again while the cached catalog is fresh")
    }

    @MainActor
    func testLibraryReentryKeepsFreshCatalogWithoutNetworkRequests() {
        let app = launch()
        for _ in 0..<2 {
            reveal(app.buttons["fixture.library"], in: app)
            app.buttons["fixture.library"].tap()
            let playlist = app.staticTexts.matching(NSPredicate(format: "label == %@", "Fixture Alpha")).firstMatch
            reveal(playlist, in: app)
            XCTAssertTrue(playlist.exists)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            let count = app.staticTexts["fixture.cloud.requestCount"]
            reveal(count, in: app, towardTop: true)
            expectState(count, matching: NSPredicate(format: "label == %@", "0"),
                        because: "Entering Library must reuse the fresh account catalog")
        }
    }

    @MainActor
    func testLibraryPullWaitsForOneSharedAccountSyncAndAppliesConfirmedRemoval() {
        let app = launch(extraArguments: ["-KodaUITestAccountSync"])
        reveal(app.buttons["fixture.library"], in: app)
        app.buttons["fixture.library"].tap()
        pullLibraryToRefresh(in: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        expectAccountFixture("readCount", "1", in: app)
        expectAccountFixture("state", "waiting", in: app)
        reveal(app.buttons["fixture.account.join"], in: app)
        app.buttons["fixture.account.join"].tap()
        expectAccountFixture("joined", "2", in: app, towardTop: true)
        expectAccountFixture("completed", "0", in: app)
        expectAccountFixture("readCount", "1", in: app, towardTop: true)
        reveal(app.buttons["fixture.account.release"], in: app)
        app.buttons["fixture.account.release"].tap()
        expectAccountFixture("completed", "2", in: app, towardTop: true)
        expectAccountFixture("state", "idle", in: app)
        expectAccountFixture("liked", "ui-smoke-a,ui-smoke-c", in: app)
        expectAccountFixture("queue", "unchanged", in: app)
        expectAccountFixture("readCount", "1", in: app, towardTop: true)
        capture(app, "library-shared-refresh-confirmed-removal")
    }

    @MainActor
    func testLibraryRefreshFailureKeepsLikesCachedPlaylistsAndQueue() {
        let app = launch(extraArguments: ["-KodaUITestAccountSync", "-KodaUITestAccountSyncFailure"])
        reveal(app.buttons["fixture.library"], in: app)
        app.buttons["fixture.library"].tap()
        pullLibraryToRefresh(in: app)
        let error = app.staticTexts["library.sync.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        reveal(error, in: app, towardTop: true)
        expectState(error, matching: NSPredicate(format: "label == %@", "Check your connection and try again."))
        let cached = app.staticTexts["Fixture Alpha"]
        reveal(cached, in: app)
        XCTAssertTrue(cached.exists, "A failed full sync must retain the cached playlist")
        capture(app, "library-sync-failure-preserves-cache")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        expectAccountFixture("readCount", "1", in: app)
        expectAccountFixture("state", "idle", in: app)
        expectAccountFixture("liked", "ui-smoke-a,ui-smoke-b,ui-smoke-c", in: app)
        expectAccountFixture("queue", "unchanged", in: app)
    }

    @MainActor
    func testLibraryPullDuringCloudRenameRunsAfterTheWriteWithoutCancellingIt() {
        let app = launch(extraArguments: ["-KodaUITestAccountSync"])
        reveal(app.buttons["fixture.account.mutationStart"], in: app)
        app.buttons["fixture.account.mutationStart"].tap()
        expectAccountFixture("mutationState", "running", in: app, towardTop: true)
        reveal(app.buttons["fixture.library"], in: app, towardTop: true)
        app.buttons["fixture.library"].tap()
        pullLibraryToRefresh(in: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        expectAccountFixture("readCount", "0", in: app)
        expectAccountFixture("state", "waiting", in: app)
        reveal(app.buttons["fixture.account.join"], in: app)
        app.buttons["fixture.account.join"].tap()
        expectAccountFixture("completed", "0", in: app, towardTop: true)
        reveal(app.buttons["fixture.account.mutationRelease"], in: app)
        app.buttons["fixture.account.mutationRelease"].tap()
        expectAccountFixture("mutationState", "succeeded", in: app, towardTop: true)
        expectAccountFixture("readCount", "1", in: app, towardTop: true)
        expectAccountFixture("completed", "2", in: app)
        expectAccountFixture("state", "idle", in: app)
        expectAccountFixture("queue", "unchanged", in: app)
        let renamed = app.staticTexts["fixture.playlist.UI renamed"]
        reveal(renamed, in: app)
        expectState(renamed, matching: NSPredicate(format: "label == %@", "UI renamed: 2"))
        capture(app, "library-refresh-after-cloud-write")
    }

    @MainActor
    func testAccountSwitchAwayAndBackRejectsTheOldRefreshResponse() {
        let app = launch(extraArguments: ["-KodaUITestAccountSync"])
        reveal(app.buttons["fixture.library"], in: app)
        app.buttons["fixture.library"].tap()
        pullLibraryToRefresh(in: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        expectAccountFixture("readCount", "1", in: app)
        reveal(app.buttons["fixture.account.profileSwitch"], in: app)
        app.buttons["fixture.account.profileSwitch"].tap()
        expectAccountFixture("profileCycle", "switched", in: app, towardTop: true)
        reveal(app.buttons["fixture.account.release"], in: app, towardTop: true)
        app.buttons["fixture.account.release"].tap()
        expectAccountFixture("profileCycle", "new-refresh", in: app)
        expectAccountFixture("readCount", "2", in: app, towardTop: true)
        expectAccountFixture("liked", "ui-after-switch", in: app)
        reveal(app.buttons["fixture.account.release"], in: app)
        app.buttons["fixture.account.release"].tap()
        expectAccountFixture("profileCycle", "settled", in: app)
        expectAccountFixture("profileValid", "valid", in: app)
        let catalogReads = app.staticTexts["fixture.account.catalogReads"]
        reveal(catalogReads, in: app)
        expectState(catalogReads, matching: NSPredicate(format: "label MATCHES %@", "[1-9][0-9]*"),
                    because: "The switched profile's catalog must still use the isolated service")
        expectAccountFixture("switchedSnapshotRows", "2", in: app)
        expectAccountFixture("liked", "ui-after-switch", in: app, towardTop: true)
        expectAccountFixture("queue", "unchanged", in: app)
        capture(app, "account-switch-rejects-old-refresh")
    }

    @MainActor
    func testPlaylistReentryImmediatelyUsesCompleteCachedSnapshot() {
        let app = launch()
        for _ in 0..<2 {
            reveal(app.buttons["fixture.playlist.cached"], in: app)
            app.buttons["fixture.playlist.cached"].tap()
            let firstSong = control("playlist.song.0", in: app)
            reveal(firstSong, in: app)
            XCTAssertTrue(firstSong.exists)
            XCTAssertFalse(control("playlist.cache.retry", in: app).exists)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            let count = app.staticTexts["fixture.snapshot.requestCount"]
            reveal(count, in: app, towardTop: true)
            expectState(count, matching: NSPredicate(format: "label == %@", "0"),
                        because: "A fresh complete snapshot must not be fetched again on navigation")
        }
    }

    @MainActor
    func testFlowPreviewUsesOnlyItsCloudSourceAndDoesNotStartPlayback() {
        let app = launch()
        reveal(app.buttons["fixture.flow"], in: app)
        app.buttons["fixture.flow"].tap()
        XCTAssertTrue(control("flow.source.title", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(control("flow.preview.count", in: app).exists)
        app.buttons["flow.arrange"].tap()
        XCTAssertTrue(control("flow.preview.count", in: app).waitForExistence(timeout: 10))
        reveal(control("flow.shortage", in: app), in: app)
        let start = app.buttons["flow.start"]
        reveal(start, in: app)
        XCTAssertTrue(start.isEnabled)
        reveal(control("flow.song.ui-smoke-a", in: app), in: app)
        reveal(control("flow.song.ui-smoke-b", in: app), in: app)
        XCTAssertFalse(control("flow.song.ui-smoke-c", in: app).exists,
                       "Another playlist's song must not fill a short Flow")
        capture(app, "flow-source-preview")
        app.navigationBars.buttons["Done"].tap()
        reveal(app.staticTexts["fixture.playlist.Fixture Alpha"], in: app)
        XCTAssertEqual(app.staticTexts["fixture.playlist.Fixture Alpha"].label, "Fixture Alpha: 2")
        XCTAssertEqual(app.staticTexts["fixture.localPlaylistCount"].label, "0")
    }

    @MainActor
    func testCloudHomeAndFlowUseTraditionalChineseAtLargeTextSize() {
        let app = launch(chinese: true, dark: true, largeText: true)
        let home = app.buttons["fixture.home"]
        reveal(home, in: app)
        home.tap()
        let title = control("home.cloud.title", in: app)
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "我的 YouTube Music 播放清單")
        let play = app.buttons["home.cloud.play.PLui-alpha"]
        reveal(play, in: app)
        XCTAssertTrue(play.label.contains("播放"))
        XCTAssertGreaterThanOrEqual(play.frame.height, 44)
        capture(app, "cloud-home-zh-Hant-large-dark")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        reveal(app.buttons["fixture.flow"], in: app)
        app.buttons["fixture.flow"].tap()
        let arrange = app.buttons["flow.arrange"]
        reveal(arrange, in: app)
        XCTAssertEqual(arrange.label, "安排 Flow")
        arrange.tap()
        let start = app.buttons["flow.start"]
        reveal(start, in: app)
        XCTAssertEqual(start.label, "開始播放 Flow")
        XCTAssertTrue(start.isEnabled)
        capture(app, "flow-zh-Hant-large-dark")
    }

    @MainActor
    func testSelectingLargeCloudPlaylistIncludesAllSixHundredRows() {
        let app = launch(extraArguments: ["-KodaUITestLargePlaylist"])
        reveal(app.buttons["fixture.selection"], in: app)
        app.buttons["fixture.selection"].tap()
        XCTAssertTrue(app.buttons["playlist.row.0"].waitForExistence(timeout: 10))
        app.buttons["playlist.selection.menu"].tap()
        app.buttons["playlist.selectAll"].tap()
        expectSelectionCount(600, in: app)
        app.buttons["playlist.selection.menu"].tap()
        app.buttons["playlist.deselectAll"].tap()
        expectSelectionCount(0, in: app)
    }

    @MainActor
    func testMusicCatcherRequiresVersionSelectionBeforeVerifiedLike() {
        let app = launch()
        let entry = app.buttons["fixture.catcher"]
        reveal(entry, in: app)
        entry.tap()
        app.buttons["catcher.start"].tap()
        let candidate = app.buttons["catcher.candidate.ui-smoke-a"]
        reveal(candidate, in: app)
        XCTAssertFalse(app.buttons["catcher.like"].exists, "Recognition alone must not select or save a song")
        candidate.tap()
        let like = app.buttons["catcher.like"]
        reveal(like, in: app)
        like.tap()
        XCTAssertTrue(app.staticTexts["Saved to YouTube Music"].waitForExistence(timeout: 10))
        expectState(like, matching: NSPredicate(format: "enabled == false"))
        capture(app, "catcher-version-confirmed")
        let add = app.buttons["catcher.add"]
        reveal(add, in: app)
        add.tap()
        let destination = app.buttons["cloud.destination.PLui-beta"]
        reveal(destination, in: app)
        XCTAssertFalse(app.buttons["cloud.destination.PLui-read-only"].exists)
        destination.tap()
        let confirm = app.buttons["Add Songs"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        XCTAssertTrue(app.buttons["catcher.add"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Done"].tap()
        let savedPlaylist = app.staticTexts["fixture.playlist.Fixture Beta"]
        reveal(savedPlaylist, in: app)
        XCTAssertEqual(savedPlaylist.label, "Fixture Beta: 3")
    }

    @MainActor
    func testMusicCatcherCancellationAndNoMatchRemainRecoverable() {
        let app = launch(extraArguments: ["-KodaUITestRecognitionWaiting"])
        reveal(app.buttons["fixture.catcher"], in: app)
        app.buttons["fixture.catcher"].tap()
        app.buttons["catcher.start"].tap()
        let cancel = app.buttons["catcher.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        XCTAssertTrue(app.buttons["catcher.start"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["catcher.candidate.ui-smoke-a"].exists)
        app.terminate()

        let noMatch = launch(extraArguments: ["-KodaUITestRecognitionNoMatch"])
        reveal(noMatch.buttons["fixture.catcher"], in: noMatch)
        noMatch.buttons["fixture.catcher"].tap()
        noMatch.buttons["catcher.start"].tap()
        XCTAssertTrue(control("catcher.failure", in: noMatch).waitForExistence(timeout: 10))
        XCTAssertTrue(noMatch.buttons["catcher.start"].isEnabled)
        XCTAssertFalse(noMatch.buttons["catcher.like"].exists)
        capture(noMatch, "catcher-no-match")
        noMatch.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(noMatch.buttons["fixture.catcher"].waitForExistence(timeout: 10))
        noMatch.terminate()

        let denied = launch(extraArguments: ["-KodaUITestRecognitionDenied"])
        reveal(denied.buttons["fixture.catcher"], in: denied)
        denied.buttons["fixture.catcher"].tap()
        denied.buttons["catcher.start"].tap()
        XCTAssertTrue(control("catcher.failure", in: denied).waitForExistence(timeout: 10))
        XCTAssertTrue(denied.buttons["Open Settings"].exists)
        XCTAssertFalse(denied.buttons["catcher.cancel"].exists)
        XCTAssertFalse(denied.buttons["catcher.like"].exists)
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
        tapSwitchThumb(automatic)
        expectValue("1", from: automatic)
        capture(app, "device-sound-settings")
        tapSwitchThumb(automatic)
        expectValue("0", from: automatic)
    }

    @MainActor
    func testSleepTimerPresetsStartRealCountdownsAndCanBeCancelled() {
        let app = launch()
        app.buttons["fixture.sleep"].tap()
        let duration = control("sleep.timer.duration", in: app)
        XCTAssertTrue(duration.waitForExistence(timeout: 10))
        for minutes in [30, 60, 90, 120, 180] {
            reveal(duration, in: app, towardTop: true)
            duration.tap()
            control("sleep.timer.duration.\(minutes)", in: app).tap()
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
            expectState(app.staticTexts["sleep.timer.remaining"], matching: NSPredicate(format: "exists == false"))
        }
    }

    @MainActor
    func testSleepTimerCustomDurationExtendResetAndExpiryChoices() {
        let app = launch()
        app.buttons["fixture.sleep"].tap()
        let expiry = control("sleep.timer.expiryAction", in: app)
        reveal(expiry, in: app)
        expectValue("Finish Playback Session", from: expiry)
        // Selecting an action changes only expiry behavior, not the schedule mode.
        expiry.tap()
        control("sleep.expiry.pause", in: app).tap()
        expectValue("Pause Playback", from: expiry)
        expiry.tap()
        control("sleep.expiry.finish", in: app).tap()
        expectValue("Finish Playback Session", from: expiry)
        let duration = control("sleep.timer.duration", in: app)
        reveal(duration, in: app, towardTop: true)
        duration.tap()
        control("sleep.timer.custom", in: app).tap()
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
        control("sleep.expiry.pause", in: app).tap()
        expectValue("Pause Playback", from: expiry)
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
        expectState(app.staticTexts["sleep.timer.remaining"], matching: NSPredicate(format: "exists == false"))
    }

    @MainActor
    func testSleepTimerTraditionalChineseLargeTypeInBothAppearances() {
        for dark in [false, true] {
            let app = launch(chinese: true, dark: dark, largeText: true)
            expectAppearance(dark ? "dark" : "light", in: app)
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
        expectValue("On", from: orb)
        orb.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["lyrics.translation.done"].waitForExistence(timeout: 10))
        capture(app, "system-reduced-motion-and-transparency")
        app.buttons["lyrics.translation.done"].tap()
        expectValue("On", from: orb)
        app.terminate()
    }

    @MainActor
    func testTraditionalChineseLargeTypeInLightAndDarkAppearance() {
        for dark in [false, true] {
            let app = launch(chinese: true, dark: dark, largeText: true)
            expectAppearance(dark ? "dark" : "light", in: app)
            app.buttons["fixture.translation"].tap()
            let orb = app.buttons["lyrics.translation.toggle"]
            XCTAssertTrue(orb.waitForExistence(timeout: 10))
            XCTAssertTrue(orb.isHittable)
            XCTAssertGreaterThanOrEqual(orb.frame.width, 44)
            XCTAssertGreaterThanOrEqual(orb.frame.height, 44)
            orb.tap()
            expectValue("開啟", from: orb)
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
                        extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-KodaUISmokeTests", "-AppleLanguages", chinese ? "(zh-Hant)" : "(en)",
                               "-AppleLocale", chinese ? "zh_TW" : "en_US"]
        if dark { app.launchArguments.append("-KodaUITestDark") }
        if largeText { app.launchArguments.append("-KodaUITestLargeText") }
        app.launchArguments += extraArguments
        if app.state != .notRunning {
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "The previous Koda process must terminate before launch")
        }
        app.launch()
        XCTAssertTrue(app.buttons["fixture.translation"].waitForExistence(timeout: 20))
        expectState(app.buttons["fixture.translation"], matching: NSPredicate(format: "enabled == true"),
                    because: "The offline fixture must finish preparing before interaction")
        return app
    }

    @MainActor
    func testAdvancedLyricsPreviewSelectionAndTiming() {
        let app = launch(extraArguments: ["-KodaUITestAdvancedLyrics"])
        let entry = app.buttons["fixture.lyrics.versions"]
        reveal(entry, in: app)
        entry.tap()
        let candidate = app.buttons.matching(identifier: "lyrics.candidate.youLyPlus").firstMatch
        reveal(candidate, in: app)
        XCTAssertTrue(candidate.exists)
        candidate.tap()
        let apply = app.buttons["lyrics.candidate.use"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10))
        apply.tap()
        let calibration = app.buttons["lyrics.candidate.calibrate"]
        reveal(calibration, in: app)
        calibration.tap()
        let increment = app.buttons["lyrics.calibration.0.5"]
        XCTAssertTrue(increment.waitForExistence(timeout: 10))
        increment.tap()
        app.buttons["lyrics.calibration.save"].tap()
        XCTAssertTrue(calibration.waitForExistence(timeout: 10))
        calibration.tap()
        XCTAssertTrue(increment.waitForExistence(timeout: 10))
        let delay = app.descendants(matching: .any).matching(identifier: "lyrics.calibration.value").firstMatch
        XCTAssertEqual(delay.value as? String, "+0.5")
        app.buttons["lyrics.calibration.save"].tap()
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        let current = app.buttons["lyrics.current.version"]
        expectState(current, matching: NSPredicate(format: "label CONTAINS %@", "YouLyPlus"))
    }

    @MainActor
    func testAdvancedLyricsManualSearchAndEdit() {
        let app = launch(extraArguments: ["-KodaUITestAdvancedLyrics"])
        let entry = app.buttons["fixture.lyrics.versions"]
        reveal(entry, in: app)
        entry.tap()
        let search = app.buttons["lyrics.sources.manual"]
        reveal(search, in: app)
        search.tap()
        let submit = app.buttons["lyrics.manual.submit"]
        reveal(submit, in: app)
        submit.tap()
        let candidate = app.buttons.matching(identifier: "lyrics.candidate.lrclib").firstMatch
        reveal(candidate, in: app)
        candidate.tap()
        let edit = app.buttons["lyrics.candidate.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        let field = app.textFields["lyrics.edit.line.0"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Our edited translation")
        app.buttons["lyrics.edit.save"].tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "Our edited translation")
    }

    @MainActor
    func testCompactBilingualPlayerKeepsPlaybackAndOffersDiagnostics() throws {
        let app = launch(largeText: true, extraArguments: ["-KodaUITestCompactLyrics"])
        let demo = app.buttons["fixture.lyrics.player"]
        reveal(demo, in: app)
        XCTAssertTrue(demo.exists)
        demo.tap()
        let lyrics = app.buttons["player.panel.lyrics"]
        XCTAssertTrue(lyrics.waitForExistence(timeout: 10))
        lyrics.tap()
        let orb = app.buttons["lyrics.translation.toggle"]
        let source = app.buttons["lyrics.sources.open"]
        let controls = app.buttons["lyrics.player.controls"]
        let position = app.descendants(matching: .any).matching(identifier: "player.position").firstMatch
        let volume = app.descendants(matching: .any).matching(identifier: "player.volume").firstMatch
        XCTAssertTrue(orb.waitForExistence(timeout: 10))
        XCTAssertTrue(source.exists)
        XCTAssertEqual(orb.frame.width, source.frame.width, accuracy: 1)
        XCTAssertEqual(orb.frame.height, source.frame.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(orb.frame.width, 44)
        XCTAssertFalse(controls.exists)
        XCTAssertTrue(volume.exists)
        XCTAssertTrue(app.buttons["Pause"].exists)
        let initial = try XCTUnwrap(position.value as? String)
        orb.tap()
        XCTAssertTrue(controls.waitForExistence(timeout: 10))
        XCTAssertFalse(volume.exists)
        let translatedLine = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", "我們等著晨光")).firstMatch
        XCTAssertTrue(translatedLine.waitForExistence(timeout: 10))
        controls.tap()
        XCTAssertTrue(volume.waitForExistence(timeout: 10))
        controls.tap()
        XCTAssertFalse(volume.exists)
        XCTAssertTrue(app.buttons["Pause"].exists)
        func elapsed(_ text: String) -> Int {
            text.split(separator: " ").first?.split(separator: ":").compactMap { Int($0) }
                .reduce(0) { $0 * 60 + $1 } ?? -1
        }
        let after = try XCTUnwrap(position.value as? String)
        XCTAssertGreaterThan(elapsed(after), elapsed(initial))

        orb.press(forDuration: 0.8)
        let link = app.buttons["lyrics.translation.diagnostics"]
        reveal(link, in: app)
        XCTAssertTrue(link.exists)
        link.tap()
        let origin = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "Lyrics Provider Translation (1)", "Lyrics Provider Translation (1)")).firstMatch
        XCTAssertTrue(origin.waitForExistence(timeout: 10))
        let appleLanguagePairs = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", "Apple Translation Language Pairs")).firstMatch
        reveal(appleLanguagePairs, in: app)
        XCTAssertTrue(appleLanguagePairs.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["lyrics.translation.done"].tap()
        XCTAssertTrue(controls.waitForExistence(timeout: 10))

        app.buttons["player.panel.queue"].tap()
        XCTAssertTrue(volume.waitForExistence(timeout: 10))
        XCTAssertFalse(controls.exists)
        lyrics.tap()
        XCTAssertTrue(controls.waitForExistence(timeout: 10))
        orb.tap()
        XCTAssertTrue(volume.waitForExistence(timeout: 10))
        XCTAssertFalse(controls.exists)
        XCTAssertTrue(app.buttons["Pause"].exists)
    }

    @MainActor
    func testImmersiveTouchLockInLandscapeKeepsPlaybackAndRequiresVisibleUnlock() throws {
        let app = launch(extraArguments: ["-KodaUITestCompactLyrics"])
        defer { XCUIDevice.shared.orientation = .portrait }
        let demo = app.buttons["fixture.lyrics.player"]
        reveal(demo, in: app)
        XCTAssertTrue(demo.exists)
        demo.tap()

        let more = app.buttons["player.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let entry = app.buttons["Immersive Listening"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        let lock = app.buttons["immersive.lock.lock"]
        let unlock = app.buttons["immersive.lock.unlock"]
        let transport = app.buttons["immersive.transport"]
        if !lock.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap() }
        XCTAssertTrue(lock.waitForExistence(timeout: 10))
        XCTAssertTrue(transport.exists)
        XCTAssertEqual(transport.label, "Pause")
        lock.tap()
        XCTAssertTrue(unlock.waitForExistence(timeout: 4))
        XCTAssertFalse(transport.exists)
        XCTAssertFalse(app.buttons["immersive.settings"].exists)
        XCTAssertTrue(unlock.waitForNonExistence(timeout: 8))
        // This is the former lock's position. The first touch may reveal the
        // button but must not unlock, pause, or activate another control.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(unlock.waitForExistence(timeout: 4))
        XCTAssertFalse(transport.exists)
        unlock.tap()
        XCTAssertTrue(transport.waitForExistence(timeout: 4))
        XCTAssertEqual(transport.label, "Pause")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 5))
    }

    @MainActor
    private func pullLibraryToRefresh(in app: XCUIApplication) {
        let scroll = app.scrollViews["library.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        // Work from the visible scroll body. The AX scroll frame can extend
        // under the large navigation title on compact simulators.
        let frame = scroll.frame.intersection(app.windows.firstMatch.frame)
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let startY = max(frame.minY + frame.height * 0.34, app.navigationBars.firstMatch.frame.maxY + 35)
        let start = origin.withOffset(CGVector(dx: frame.minX + 13, dy: startY))
        let end = origin.withOffset(CGVector(dx: frame.minX + 13, dy: frame.maxY - 55))
        start.press(forDuration: 0.08, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.35)
    }

    @MainActor
    private func expectAccountFixture(_ field: String, _ value: String, in app: XCUIApplication,
                                      towardTop: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.staticTexts["fixture.account.\(field)"]
        reveal(element, in: app, towardTop: towardTop)
        expectState(element, matching: NSPredicate(format: "label == %@", value), file: file, line: line)
    }

    @MainActor
    private func expectSelectionCount(_ count: Int, in app: XCUIApplication,
                                      file: StaticString = #filePath, line: UInt = #line) {
        // Native menus can temporarily invalidate the AX tree. Resolve a fresh
        // exact query on each state instead of retaining the pre-menu leaf.
        let matchingCount = app.staticTexts.matching(identifier: "playlist.selection.count")
            .matching(NSPredicate(format: "label == %@", "\(count) selected")).firstMatch
        XCTAssertTrue(matchingCount.waitForExistence(timeout: 8),
                      "Expected the visible selection count to be \(count)", file: file, line: line)
    }

    @MainActor
    private func expectAppearance(_ appearance: String, in app: XCUIApplication,
                                  file: StaticString = #filePath, line: UInt = #line) {
        // The fixture reads the actual SwiftUI environment, not its launch argument.
        let probe = app.staticTexts.matching(identifier: "fixture.appearance")
            .matching(NSPredicate(format: "label == %@", appearance)).firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 8),
                      "Expected the actual \(appearance) color scheme", file: file, line: line)
    }

    @MainActor
    private func control(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        // Native Picker presentations can expose their labels as a button, menu item
        // or selection row. Match the production identifier, not a platform AX role.
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func expectValue(_ value: String, from element: XCUIElement, because reason: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        expectState(element, matching: NSPredicate(format: "value == %@", value),
                    because: reason, file: file, line: line)
    }

    @MainActor
    private func expectState(_ element: XCUIElement, matching predicate: NSPredicate, because reason: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        // Event delivery, SwiftUI rendering and accessibility snapshots complete at
        // different times. Observe the requested state, without retrying the gesture.
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: 8)
        if result != .completed {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "state-expectation-timeout"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertEqual(result, .completed,
                       "Expected \(predicate) for \(element). \(reason)", file: file, line: line)
    }

    @MainActor
    private func tapSwitchThumb(_ toggle: XCUIElement) {
        // On iOS 27 the switch AX frame includes its entire Form/Settings row.
        // A center tap hits the label; target the visible trailing switch instead.
        XCTAssertTrue(toggle.exists && toggle.isHittable && toggle.isEnabled)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
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
        // SwiftUI LabeledContent exposes a combined localized AX label, for example
        // "Time Remaining, 17:00" or "剩餘時間、30:00". Extract its time value while
        // keeping the duration assertions exact; never discard a failed numeric part.
        guard let range = value.range(of: #"(?<![0-9:])[0-9]+:[0-9]{2}(?::[0-9]{2})?(?![0-9:])"#,
                                      options: .regularExpression) else {
            XCTFail("Expected a real minute/second countdown, received: \(value)", file: file, line: line)
            return 0
        }
        let components = value[range].split(separator: ":")
        let parts = components.compactMap { Int($0) }
        guard (2...3).contains(parts.count), parts.count == components.count,
              parts.dropFirst().allSatisfy({ $0 < 60 }) else {
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
        if original != enabled { tapSwitchThumb(toggle) }
        expectValue(enabled ? "1" : "0", from: toggle)
        return original
    }
}
