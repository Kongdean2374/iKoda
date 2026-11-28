import Foundation

public enum LyricsTranslationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case quick, quality
    public var id: Self { self }

}
