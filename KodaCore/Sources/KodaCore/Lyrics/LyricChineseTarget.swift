import Foundation

/// An identifier is a policy preference. The caller still checks support for
/// each complete source/target pair and strategy with LanguageAvailability.
public enum LyricChineseTarget {
    public static let preferred = ["zh-Hant-TW", "zh-TW", "zh-Hant"]

    public static func tier(_ identifier: String) -> Int {
        let tag = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        switch tag {
        case "zh-hant-tw": return 0
        case "zh-tw": return 1
        case "zh-hant": return 2
        case "zh", "zh-hans", "zh-cn", "zh-hans-cn": return 3
        case "zh-hk", "zh-hant-hk", "yue", "yue-hant", "yue-hk", "yue-hant-hk": return 5
        default: return 4
        }
    }

    public static func ordered(_ supported: [String]) -> [String] {
        var seen = Set<String>()
        return (preferred + supported)
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted { (tier($0), $0) < (tier($1), $1) }
    }

    public static func choose(_ routes: [AppleLyricDiagnostics.LanguageRoute], prefersQuality: Bool)
        -> AppleLyricDiagnostics.LanguageRoute? {
        func rank(_ route: AppleLyricDiagnostics.LanguageRoute) -> (Int, Int, Int, String) {
            let target = route.target ?? ""
            let preference = tier(target)
            // A downloadable Taiwan pair takes precedence over installed
            // Hong Kong wording. For the remaining fallbacks favor ready packs.
            return (preference <= 2 ? 0 : 1, route.support == .available ? 0 : 1, preference, target)
        }
        let supported = routes.filter { $0.support == .available || $0.support == .download }
        return supported.min {
            let left = rank($0), right = rank($1)
            if left != right { return left < right }
            return prefersQuality && $0.strategy == .highFidelity && $1.strategy != .highFidelity
        }
    }

    public static func namespace(for routes: [AppleLyricDiagnostics.LanguageRoute]) -> String {
        routes.sorted { $0.source < $1.source }.map {
            "\($0.source):\($0.target ?? "unavailable"):\($0.strategy?.rawValue ?? "standard")"
        }.joined(separator: ",")
    }
}
