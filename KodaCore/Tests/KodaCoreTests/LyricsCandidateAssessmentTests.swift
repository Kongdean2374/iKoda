import Foundation
import Testing
@testable import KodaCore

@Suite struct LyricsCandidateAssessmentTests {
    let song = Song(id: "clock", title: "The Quiet Clock", artistLine: "Fictional Quartet", duration: 120)
    let verses = ["Do not close the window", "Our shadows turn to paper",
                  "I will return at dawn", "Leave a light for me",
                  "Leave a light for me", "The clock forgets the rain"]

    private func version(_ identifier: String, upstream: String? = nil, metadata: LyricsCandidate.Metadata = .init(),
                         texts: [String]? = nil, shift: Double = 0, wordLines: Int = 0, voice: Bool = false) -> LyricsCandidate {
        let lines = (texts ?? verses).enumerated().map { index, text in
            let time = 7 + Double(index) * 10 + shift
            let words = index < wordLines ? text.split(separator: " ").enumerated().map { offset, word in
                LyricWord(text: String(word), start: time + Double(offset) * 0.4, end: time + Double(offset + 1) * 0.4)
            } : []
            let backing = voice ? [LyricWord(text: "ah", start: time - 0.4, end: time + 0.8)] : []
            return LyricLine(id: index, time: time, text: text, words: words, background: backing,
                             end: time + 5, voice: voice && index.isMultiple(of: 2) ? .duet : .lead)
        }
        return LyricsCandidate(song: song, source: identifier, sourceName: identifier, upstream: upstream,
                               metadata: metadata, lyrics: .synced(lines))
    }

    private var trusted: LyricsCandidate {
        version("lrclib", metadata: .init(title: "The Quiet Clock", artist: "Fictional Quartet", duration: 120))
    }

    @Test func trustworthyLineTimingCanVerifyAWordTimedVersionWithoutMetadata() {
        let dynamic = version("youLyPlus", upstream: "qApple", wordLines: 6)
        let assessments = LyricsCandidateEvaluator.evaluate([trusted, dynamic])
        #expect(dynamic.match.confidence == .low)
        #expect(assessments[dynamic.id]?.content == .verified)
        #expect(assessments[dynamic.id]?.independentSources == 1)
        #expect(dynamic.timing.grade == .completeWords)
        #expect(LyricsVersionSelection.recommended([trusted, dynamic], allowLowConfidence: false)?.id == dynamic.id)
    }

    @Test func lateStrongRecommendationAndManualPinLeaveTheDisplayedVersionStable() {
        let dynamic = version("youLyPlus", upstream: "qApple", wordLines: 6)
        var presented = LyricsVersionSelection()
        presented.offer([trusted], finished: false)
        presented.offer([trusted, dynamic], finished: true)
        #expect(presented.current?.id == trusted.id)
        var pinned = LyricsVersionSelection(preferred: dynamic)
        pinned.offer([trusted], finished: true)
        #expect(pinned.current?.id == dynamic.id)
        #expect(pinned.preferred == dynamic.id)
    }

    @Test func wrongWordsOrNegationCannotBeCorroboratedByTiming() {
        let different = version("youLyPlus", upstream: "qApple", texts: ["Open the gallery", "Put out my fire",
            "Count every chair", "Blue river water", "Blue river water", "The next morning"], wordLines: 6)
        let changed = version("youLyPlus", upstream: "qApple",
                              texts: ["Do close the window"] + Array(verses.dropFirst()), wordLines: 6)
        let results = LyricsCandidateEvaluator.evaluate([trusted, different, changed])
        #expect(results[different.id]?.content == .conflict)
        #expect(results[changed.id]?.content == .conflict)
        #expect(LyricsVersionSelection.recommended([trusted, different, changed], allowLowConfidence: true)?.id == trusted.id)
    }

    @Test func equalLyricsWithShiftedTimelineOrDifferentISRCDoNotVerifyARecording() {
        let shifted = version("youLyPlus", upstream: "qApple", shift: 6, wordLines: 6)
        #expect(LyricsCandidateEvaluator.evaluate([trusted, shifted])[shifted.id]?.content == .differentRecording)
        let known = version("lrclib", metadata: .init(title: "The Quiet Clock", artist: "Fictional Quartet",
            duration: 120, recordingID: "US-ABC-21-00001"))
        let other = version("youLyPlus", upstream: "qApple", metadata: .init(recordingID: "US-ABC-21-00002"), wordLines: 6)
        #expect(LyricsCandidateEvaluator.evaluate([known, other])[other.id]?.content == .differentRecording)
    }

    @Test func explicitArtistConflictCannotBeOverriddenByMatchingText() {
        let other = version("youLyPlus", upstream: "qApple", metadata: .init(title: song.title, artist: "Another Band"), wordLines: 6)
        #expect(other.match.confidence == .conflict)
        #expect(LyricsVersionSelection.recommended([trusted, other], allowLowConfidence: true)?.id == trusted.id)
    }

    @Test func missingOneRepeatedChorusDoesNotCountAsCrossVerification() {
        let long = verses + verses + verses
        let reference = version("lrclib", metadata: trusted.metadata, texts: long)
        let omitted = version("youLyPlus", upstream: "qApple", texts: verses + verses, wordLines: 12)
        #expect(LyricsCandidateEvaluator.evaluate([reference, omitted])[omitted.id]?.content != .verified)
    }

    @Test func wordCoverageChecksTheTextAndAllowsOverlappingBackgroundVoices() {
        let partial = version("youLyPlus", upstream: "qApple", wordLines: 1)
        let complete = version("youLyPlus", upstream: "qApple", wordLines: 6, voice: true)
        #expect(partial.timing.grade == .partialWords)
        #expect(partial.timing.timedLines == 1)
        #expect(partial.timing.untimedWordLines == 5)
        #expect(complete.timing.grade == .completeWords)
        #expect(complete.timing.wordCoverage == 1)
        #expect(complete.timing.voicedLines == 6)
        #expect(complete.timing.invalidTimes == 0)
        let badTime = LyricTimingQuality.measure(.synced([
            LyricLine(id: 0, time: 199, text: "Too late", words: [.init(text: "Different", start: 197, end: .infinity)])
        ]), duration: 120)
        #expect(badTime.invalidTimes >= 2)
        #expect(badTime.wordCoverage == 0)
    }

    @Test func mirrorsAndUnverifiedCataloguesCannotCreateIndependentAgreement() {
        let known = version("YouLyPlus", upstream: "qApple", metadata: trusted.metadata)
        let mirror = version("Better Lyrics", upstream: "Apple Music", wordLines: 6)
        let another = version("custom", wordLines: 6)
        let results = LyricsCandidateEvaluator.evaluate([known, mirror, another])
        #expect(results[mirror.id]?.independentSources == 0)
        #expect(results[another.id]?.content == .unconfirmed)
        #expect(LyricsVersionSelection.recommended([known, mirror, another], allowLowConfidence: false)?.id == known.id)
    }

    @Test func normalizationAllowsPunctuationAndWrappingWithoutLosingWordOrder() {
        let lines = ["DO NOT CLOSE THE WINDOW!", "Our shadows turn to paper.", "I will return at dawn",
                     "Leave a light for me.", "Leave a light for me.", "THE CLOCK FORGETS THE RAIN."]
        let normalized = version("youLyPlus", upstream: "qApple", texts: lines, wordLines: 6)
        let result = LyricsCandidateEvaluator.evaluate([trusted, normalized])[normalized.id]
        #expect(result?.similarity == 1)
        #expect(result?.content == .verified)
        let wrapped = LyricsCandidate(song: song, source: "youLyPlus", sourceName: "YouLyPlus", upstream: "qApple",
            metadata: .init(), lyrics: .plain(lines.joined(separator: " ")))
        #expect(LyricsCandidateEvaluator.evaluate([trusted, wrapped])[wrapped.id]?.content == .textAgrees)
    }
}
