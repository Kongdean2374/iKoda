import Foundation

/// Stable NSError bridging for AVAssetResourceLoader. Only a status or a fixed validation
/// code crosses into AVFoundation; no response body, request URL or account data is retained.
enum AudioStreamResponseError: Error, CustomNSError, Equatable, Sendable {
    case httpStatus(Int)
    case invalidResponse
    case invalidRange
    case unsupportedContentType

    static let errorDomain = "Koda.AudioStreamResponse"

    var errorCode: Int {
        switch self {
        case .httpStatus(let status): status
        case .invalidResponse: -1
        case .invalidRange: -2
        case .unsupportedContentType: -3
        }
    }

    var errorUserInfo: [String: Any] { [:] }
}

/// Validates metadata before a response is allowed to write bytes into the audio cache.
/// A server may ignore Range and send the full file with HTTP 200; its offset then resets.
enum CachingResponse {
    static func acceptedRange(_ response: URLResponse?, requested: Range<Int64>, length: Int64) throws -> Range<Int64> {
        guard let response = response as? HTTPURLResponse else { throw AudioStreamResponseError.invalidResponse }
        guard response.statusCode == 200 || response.statusCode == 206 else {
            throw AudioStreamResponseError.httpStatus(response.statusCode)
        }
        guard length > 0, requested.lowerBound >= 0, requested.upperBound <= length else {
            throw AudioStreamResponseError.invalidRange
        }
        if let type = response.mimeType?.lowercased(), !type.hasPrefix("audio/"),
           !["application/octet-stream", "binary/octet-stream", "application/mp4", "video/mp4", "video/webm"].contains(type) {
            throw AudioStreamResponseError.unsupportedContentType
        }
        if response.statusCode == 200 {
            guard response.expectedContentLength < 0 || response.expectedContentLength == length else {
                throw AudioStreamResponseError.invalidRange
            }
            // Partial bytes labeled as a full response would corrupt the beginning of the cache.
            if let header = response.value(forHTTPHeaderField: "Content-Range") {
                guard try contentRange(header, requested: 0..<length, length: length) == 0..<length else {
                    throw AudioStreamResponseError.invalidRange
                }
            }
            return 0..<length
        }
        guard let header = response.value(forHTTPHeaderField: "Content-Range") else {
            throw AudioStreamResponseError.invalidRange
        }
        let range = try contentRange(header, requested: requested, length: length)
        guard response.expectedContentLength < 0 || response.expectedContentLength == range.upperBound - range.lowerBound else {
            throw AudioStreamResponseError.invalidRange
        }
        return range
    }

    private static func contentRange(_ header: String, requested: Range<Int64>, length: Int64) throws -> Range<Int64> {
        let components = header.split(whereSeparator: \.isWhitespace)
        guard components.count == 2, components[0].lowercased() == "bytes" else {
            throw AudioStreamResponseError.invalidRange
        }
        let intervalAndTotal = components[1].split(separator: "/", omittingEmptySubsequences: false)
        guard intervalAndTotal.count == 2 else { throw AudioStreamResponseError.invalidRange }
        let bounds = intervalAndTotal[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let first = Int64(bounds[0]), let last = Int64(bounds[1]),
              first == requested.lowerBound, last >= first, last < requested.upperBound, last < length,
              intervalAndTotal[1] == "*" || Int64(intervalAndTotal[1]) == length else {
            throw AudioStreamResponseError.invalidRange
        }
        return first..<(last + 1)
    }
}
