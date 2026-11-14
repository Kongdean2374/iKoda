import Foundation

/// A user-selected lyrics endpoint. Only song metadata is substituted; Koda never adds
/// lyric text, account credentials or authentication headers to the request.
public struct CustomLyricsSource: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var urlTemplate: String
    public var isEnabled: Bool

    public static let maximumCount = 5
    private static let maximumTemplateLength = 4_096
    private static let maximumRequestLength = 16_384
    private static let placeholders: Set<String> = ["title", "artist", "album", "duration"]
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public init(id: UUID = UUID(), name: String, urlTemplate: String, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.urlTemplate = urlTemplate
        self.isEnabled = isEnabled
    }

    public enum ValidationError: Error, Equatable, LocalizedError, Sendable {
        case invalidName, invalidURL, invalidPlaceholder, missingMetadataPlaceholder, urlTooLong

        public var errorDescription: String? {
            switch self {
            case .invalidName:
                NSLocalizedString("Enter a source name with 1–80 characters.", bundle: KodaLocalization.bundle, comment: "")
            case .invalidURL:
                NSLocalizedString("Use an HTTPS URL without a username, password, or fragment.", bundle: KodaLocalization.bundle, comment: "")
            case .invalidPlaceholder:
                NSLocalizedString("Use only {title}, {artist}, {album}, and {duration} placeholders.", bundle: KodaLocalization.bundle, comment: "")
            case .missingMetadataPlaceholder:
                NSLocalizedString("Include {title} or {artist} in the URL path or query.", bundle: KodaLocalization.bundle, comment: "")
            case .urlTooLong:
                NSLocalizedString("The lyrics source URL is too long.", bundle: KodaLocalization.bundle, comment: "")
            }
        }
    }

    /// Returns a normalized copy suitable for persistence. Errors contain fixed local text,
    /// never an endpoint, query value or server response.
    public func validated() throws -> Self {
        var source = self
        source.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        source.urlTemplate = urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.name.isEmpty, source.name.count <= 80 else { throw ValidationError.invalidName }
        guard source.urlTemplate.count <= Self.maximumTemplateLength else { throw ValidationError.urlTooLong }
        _ = try Self.buildURL(source.urlTemplate, values: ["title": "title", "artist": "artist", "album": "album", "duration": "180"])
        return source
    }

    /// Each substitution uses only RFC 3986 unreserved characters, making the same template
    /// safe in a path segment or query value. A title containing '/', '&', '=' or '%' cannot
    /// change the endpoint's host, path structure or other query parameters.
    public func requestURL(title: String, artist: String, album: String?, duration: TimeInterval?) throws -> URL {
        let source = try validated()
        let seconds: String
        if let duration, duration.isFinite, duration > 0 {
            seconds = String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), duration)
        } else {
            seconds = ""
        }
        return try Self.buildURL(source.urlTemplate, values: ["title": title, "artist": artist, "album": album ?? "", "duration": seconds])
    }

    private static func buildURL(_ template: String, values: [String: String]) throws -> URL {
        guard !template.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let schemeEnd = template.range(of: "://") else { throw ValidationError.invalidURL }
        let authority = template[schemeEnd.upperBound...].prefix { !"/?#".contains($0) }
        guard !authority.contains("{"), !authority.contains("}") else { throw ValidationError.invalidURL }

        let matcher = try NSRegularExpression(pattern: #"\{([^{}]*)\}"#)
        let matches = matcher.matches(in: template, range: NSRange(template.startIndex..., in: template))
        var names = Set<String>()
        var remainder = template
        var resolved = template
        // Replace from the end so UTF-16 ranges remain valid after percent encoding.
        for match in matches.reversed() {
            guard let nameRange = Range(match.range(at: 1), in: template),
                  let tokenRange = Range(match.range, in: template) else { throw ValidationError.invalidPlaceholder }
            let name = String(template[nameRange])
            guard placeholders.contains(name), let value = values[name],
                  let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved) else { throw ValidationError.invalidPlaceholder }
            names.insert(name)
            let token = String(template[tokenRange])
            remainder = remainder.replacingOccurrences(of: token, with: "")
            resolved.replaceSubrange(tokenRange, with: encoded)
        }
        guard !remainder.contains("{"), !remainder.contains("}") else { throw ValidationError.invalidPlaceholder }
        guard names.contains("title") || names.contains("artist") else { throw ValidationError.missingMetadataPlaceholder }
        guard resolved.count <= maximumRequestLength else { throw ValidationError.urlTooLong }
        guard let components = URLComponents(string: resolved), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil,
              let url = components.url else { throw ValidationError.invalidURL }
        return url
    }
}
