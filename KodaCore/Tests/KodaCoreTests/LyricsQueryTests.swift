import Foundation
import Testing
@testable import KodaCore

struct LyricsQueryTests {
    @Test func lookupVariantsPreserveOriginalAndOnlyRemovePresentationMetadata() {
        let query = LyricsQuery(title: "  Song (Official Music Video) [4K]  ", artist: "Artist - Topic",
                                album: "Video Collection", duration: 200)
        let variants = query.variants()
        #expect(variants.first == query)
        #expect(variants.contains(LyricsQuery(title: "Song", artist: "Artist", album: nil, duration: 200)))
        #expect(query.title == "  Song (Official Music Video) [4K]  ")
        #expect(query.album == "Video Collection")
    }

    @Test(arguments: ["Live", "Remix", "Acoustic", "Instrumental", "Remastered", "Live Official Video"])
    func recordingQualifiersAreNeverDiscarded(_ qualifier: String) {
        let query = LyricsQuery(title: "Song (\(qualifier)) [Official Audio]", artist: "Artist", album: nil, duration: 200)
        #expect(query.variants().allSatisfy { $0.title.contains(qualifier) })
        #expect(query.candidateScore(title: "Song", artist: "Artist", duration: 200) == nil)
        #expect(query.candidateScore(title: "Song (\(qualifier))", artist: "Artist", duration: 200) != nil)
    }

    @Test func bilingualChineseArtistCreditGetsBoundedAliasesAndScriptVariants() {
        let query = LyricsQuery(title: "最美的期待【官方MV】", artist: "南征北戰 NZBZ", album: "最美的期待", duration: 237)
        let variants = query.variants()
        #expect(variants.first == query)
        #expect(variants.count <= 6)
        #expect(Set(variants).count == variants.count)
        #expect(variants.contains { $0.title == "最美的期待" && $0.artist == "南征北战" })
        #expect(variants.contains { $0.title == "最美的期待" && $0.artist == "NZBZ" })
        #expect(query.candidateScore(title: "最美的期待", artist: "南征北战", duration: 237) != nil)
        #expect(query.candidateScore(title: "最美的期待", artist: "NZBZ", duration: 237) != nil)
    }

    @Test func latinFirstCreditAndFullWidthMetadataMatchWithoutChangingOriginal() {
        let query = LyricsQuery(title: "Ｈｅｌｌｏ！", artist: "JJ Lin 林俊傑", album: nil, duration: nil)
        #expect(query.candidateScore(title: "hello", artist: "林俊杰", duration: nil) != nil)
        #expect(query.candidateScore(title: "Hello", artist: "JJ Lin", duration: 180) != nil)
        #expect(query.title == "Ｈｅｌｌｏ！")
        #expect(query.artist == "JJ Lin 林俊傑")
    }

    @Test func similarDurationDoesNotPermitWrongTitleOrArtist() {
        let query = LyricsQuery(title: "最美的期待", artist: "南征北战 NZBZ", album: nil, duration: 237)
        #expect(query.candidateScore(title: "最好的期待", artist: "南征北战", duration: 237) == nil)
        #expect(query.candidateScore(title: "最美的期待", artist: "Another Artist", duration: 237) == nil)
        #expect(query.candidateScore(title: "最美的期待 (Live)", artist: "南征北战", duration: 237) == nil)
        #expect(query.candidateScore(title: "", artist: "南征北战", duration: 237) == nil)
        #expect(query.candidateScore(title: "最美的期待", artist: "", duration: 237) == nil)
    }

    @Test func mismatchedRecordingDurationIsRejectedAndCloserRecordingRanksHigher() throws {
        let query = LyricsQuery(title: "Song", artist: "Artist", album: nil, duration: 200)
        let exact = try #require(query.candidateScore(title: "Song", artist: "Artist", duration: 200))
        let near = try #require(query.candidateScore(title: "Song", artist: "Artist", duration: 210))
        #expect(exact > near)
        #expect(query.candidateScore(title: "Song", artist: "Artist", duration: 210.01) == nil)
        #expect(query.candidateScore(title: "Song", artist: "Artist", duration: nil) != nil)
    }

    @Test(arguments: ["南征北战 feat. Adele", "南征北战 & Adele", "A 林俊傑", "Artist One Artist Two"])
    func collaborationsAndArbitraryNamesDoNotBecomeAliases(_ credit: String) {
        let query = LyricsQuery(title: "Song", artist: credit, album: nil, duration: nil)
        #expect(query.candidateScore(title: "Song", artist: "Adele", duration: nil) == nil)
        #expect(query.candidateScore(title: "Song", artist: "林俊傑", duration: nil) == nil)
        #expect(query.candidateScore(title: "Song", artist: "Artist One", duration: nil) == nil)
    }

    @Test func aRealTitleContainingPresentationWordsIsRetained() {
        let query = LyricsQuery(title: "Official Video", artist: "Artist", album: nil, duration: nil)
        #expect(query.variants().allSatisfy { $0.title == "Official Video" })
        #expect(query.candidateScore(title: "Official Audio", artist: "Artist", duration: nil) == nil)
    }

    @Test func successivePresentationSuffixesAreRemovedButRecordingSuffixesRemain() {
        let query = LyricsQuery(title: "Song - Live | Official Video - 4K", artist: "Artist", album: nil, duration: 200)
        #expect(query.variants().contains { $0.title == "Song - Live" })
        #expect(query.candidateScore(title: "Song (Live)", artist: "Artist", duration: 200) != nil)
        #expect(query.candidateScore(title: "Song", artist: "Artist", duration: 200) == nil)
    }

    @Test func completeKnownCollaborationCreditIsAcceptedWithoutGuessingOtherCollaborators() {
        let query = LyricsQuery(title: "Song (Official Audio)", artist: "Artist A", album: "Album", duration: 200,
                                artistCredits: ["Artist A & Artist B"])
        #expect(query.candidateScore(title: "Song", artist: "Artist A & Artist B", duration: 200) != nil)
        #expect(query.candidateScore(title: "Song", artist: "Artist A & Artist C", duration: 200) == nil)
        #expect(query.candidateScore(title: "Song", artist: "Artist B", duration: 200) == nil)
        let variants = query.variants()
        #expect(variants.first == query)
        #expect(variants.contains { $0.title == "Song" && $0.artist == "Artist A & Artist B" })
        #expect(variants.allSatisfy { $0.artistCredits == query.artistCredits })
        #expect(variants.count <= 6)
    }
}
