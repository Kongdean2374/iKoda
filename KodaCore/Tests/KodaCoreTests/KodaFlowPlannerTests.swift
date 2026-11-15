import Foundation
import Testing
@testable import KodaCore

@Suite struct KodaFlowPlannerTests {
    private func song(_ id: String, seconds: Double?) -> Song {
        Song(id: id, title: id, artistLine: "Source Artist", duration: seconds)
    }

    @Test(arguments: [40, 60, 120])
    func fitsCommonDurationsFromOnlyTheSpecifiedSource(_ minutes: Int) async throws {
        let songs = (0..<100).map { song("source-\($0)", seconds: 240) }
        let plan = try await KodaFlowPlanner.makePlan(sourceID: "PL-source", songs: songs, minutes: minutes, seed: 4)
        #expect(plan.sourceID == "PL-source")
        #expect(plan.estimatedDuration == Double(minutes * 60))
        #expect(Set(plan.songs.map(\.id)).isSubset(of: Set(songs.map(\.id))))
        #expect(Set(plan.songs.map(\.id)).count == plan.songs.count)
    }

    @Test func deterministicSeedAndDifferentArrangements() async throws {
        let songs = (0..<60).map { song("\($0)", seconds: 180) }
        let first = try await KodaFlowPlanner.makePlan(sourceID: "PL", songs: songs, minutes: 60, seed: 1)
        let again = try await KodaFlowPlanner.makePlan(sourceID: "PL", songs: songs, minutes: 60, seed: 1)
        let other = try await KodaFlowPlanner.makePlan(sourceID: "PL", songs: songs, minutes: 60, seed: 2)
        #expect(first == again)
        #expect(first.songs != other.songs)
        #expect(other.estimatedDuration == first.estimatedDuration)
    }

    @Test func sourceShortageDoesNotAddAnythingElse() async throws {
        let songs = [song("a", seconds: 150), song("b", seconds: 200)]
        let plan = try await KodaFlowPlanner.makePlan(sourceID: "PL", songs: songs, minutes: 40, seed: 0)
        #expect(plan.isSourceTooShort)
        #expect(plan.availableDuration == 350)
        #expect(plan.estimatedDuration == 350)
        #expect(Set(plan.songs) == Set(songs))
        #expect(plan.difference == -2050)
    }

    @Test func duplicatesAreExcludedOnlyWithinThePlanAndVersionsRemainDistinct() async throws {
        let original = song("original", seconds: 180)
        let live = song("live", seconds: 210)
        let songs = [original, original, live]
        let plan = try await KodaFlowPlanner.makePlan(sourceID: "PL", songs: songs, minutes: 40, seed: 7)
        #expect(plan.duplicateCount == 1)
        #expect(Set(plan.songs.map(\.id)) == ["original", "live"])
        #expect(songs.count == 3)
    }

    @Test func unknownAndInvalidDurationsCannotPretendToFit() async throws {
        let songs = [song("nil", seconds: nil), song("zero", seconds: 0), song("negative", seconds: -2),
                     song("nan", seconds: .nan), song("inf", seconds: .infinity), song("a", seconds: 180)]
        let plan = try await KodaFlowPlanner.makePlan(sourceID: "PL", songs: songs, minutes: 40, seed: 2)
        #expect(plan.unknownDurationCount == 5)
        #expect(plan.songs.map(\.id) == ["a"])
        #expect(plan.estimatedDuration == 180)
    }

    @Test func laterOccurrenceWithKnownDurationCanStillBeUsed() async throws {
        let plan = try await KodaFlowPlanner.makePlan(sourceID: "PL", songs: [song("a", seconds: nil), song("a", seconds: 180)], minutes: 40, seed: 1)
        #expect(plan.songs.count == 1)
        #expect(plan.unknownDurationCount == 1)
    }

    @Test func closestSingleLongSongIsConsideredWithoutHugeMemory() async throws {
        let plan = try await KodaFlowPlanner.makePlan(sourceID: "PL", songs: [song("long", seconds: 36000), song("closer", seconds: 121)], minutes: 1, seed: 0)
        #expect(plan.songs.map(\.id) == ["closer"])
        #expect(plan.difference == 61)
    }

    @Test func imperfectFitReportsActualFractionalDifference() async throws {
        let plan = try await KodaFlowPlanner.makePlan(sourceID: "PL", songs: [song("a", seconds: 121.5), song("b", seconds: 132.5)], minutes: 3, seed: 0)
        #expect(plan.estimatedDuration == 132.5)
        #expect(plan.difference == -47.5)
    }

    @Test func exactSubsetDoesNotReuseTheSameOccurrenceThroughParentLinks() async throws {
        let songs = [song("a", seconds: 37), song("b", seconds: 83), song("c", seconds: 121), song("d", seconds: 59), song("e", seconds: 44)]
        for seed in UInt64(0)..<20 {
            let plan = try await KodaFlowPlanner.makePlan(sourceID: "PL", songs: songs, minutes: 3, seed: seed)
            #expect(plan.estimatedDuration == 180)
            #expect(Set(plan.songs.map(\.id)).count == plan.songs.count)
            #expect(plan.songs.reduce(0.0) { $0 + ($1.duration ?? 0) } == plan.estimatedDuration)
        }
    }

    @Test func largeSourceRemainsBoundedAndUsesLaterSongs() async throws {
        let songs = (0..<5000).map { song("\($0)", seconds: Double(170 + $0 % 41)) }
        let plan = try await KodaFlowPlanner.makePlan(sourceID: "PL", songs: songs, minutes: 120, seed: 99)
        #expect(abs(plan.difference) < 30)
        #expect(plan.songs.contains { Int($0.id)! > 1000 })
        #expect(Set(plan.songs.map(\.id)).count == plan.songs.count)
    }

    @Test func cancellationNeverReturnsAPartialPlan() async throws {
        let songs = (0..<20000).map { song("\($0)", seconds: 317.123) }
        let task = Task { try await KodaFlowPlanner.makePlan(sourceID: "PL", songs: songs, minutes: 719, seed: 1) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled planning returned a plan") }
        catch is CancellationError {}
    }

    @Test func invalidInputsAreRejected() async {
        for minutes in [0, -1, 721, Int.max] {
            await #expect(throws: KodaFlowPlanner.PlanningError.invalidTarget) {
                try await KodaFlowPlanner.makePlan(sourceID: "PL", songs: [song("a", seconds: 100)], minutes: minutes, seed: 1)
            }
        }
        await #expect(throws: KodaFlowPlanner.PlanningError.missingSource) {
            try await KodaFlowPlanner.makePlan(sourceID: " ", songs: [], minutes: 40, seed: 1)
        }
        await #expect(throws: KodaFlowPlanner.PlanningError.noKnownDurations) {
            try await KodaFlowPlanner.makePlan(sourceID: "PL", songs: [], minutes: 40, seed: 1)
        }
    }
}

@Suite struct HomePlaylistPreferencesTests {
    private var playlists: [PlaylistSummary] { ["a", "b", "c"].map { PlaylistSummary(id: $0, title: "Same title") } }

    @Test func cloudIDsRatherThanNamesDetermineDisplayIdentity() {
        var prefs = HomePlaylistPreferences()
        prefs.togglePin("b")
        #expect(prefs.sorted(playlists).map(\.id) == ["b", "a", "c"])
        #expect(playlists.map(\.id) == ["a", "b", "c"])
    }

    @Test func movingStaysWithinPinnedGroupAndRetainsRemoteSources() {
        var prefs = HomePlaylistPreferences(pinnedIDs: ["a", "b"])
        prefs.move("b", by: -1, in: playlists)
        #expect(prefs.sorted(playlists).map(\.id) == ["b", "a", "c"])
        prefs.move("c", by: -1, in: playlists)
        #expect(prefs.isPinned("c") == false)
        #expect(prefs.sorted(playlists).map(\.id) == ["b", "a", "c"])
    }

    @Test func duplicatePreferenceIDsAreNormalizedAndMissingCloudEntriesDoNotAppear() {
        let prefs = HomePlaylistPreferences(pinnedIDs: ["a", "a", "missing", ""], order: ["c", "c", "b"])
        #expect(prefs.sorted(playlists + [playlists[0]]).map(\.id) == ["a", "c", "b"])
        #expect(prefs.pinnedIDs == ["a", "missing"])
    }

    @Test func persistenceIsScopedToTheProfile() throws {
        let name = "Koda.HomePreferences.Tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let a = UUID(), b = UUID()
        var prefs = HomePlaylistPreferences()
        prefs.togglePin("b"); prefs.save(profileID: a, defaults: defaults)
        #expect(HomePlaylistPreferences.load(profileID: a, defaults: defaults) == prefs)
        #expect(HomePlaylistPreferences.load(profileID: b, defaults: defaults) == .init())
        defaults.set(Data("bad".utf8), forKey: "koda.home.cloudPlaylistDisplay.v1.\(b.uuidString)")
        #expect(HomePlaylistPreferences.load(profileID: b, defaults: defaults) == .init())
    }
}
