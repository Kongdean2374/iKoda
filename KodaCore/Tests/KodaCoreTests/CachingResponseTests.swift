import Foundation
import Testing
@testable import KodaCore

struct CachingResponseTests {
    private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.invalid/audio?token=private")!,
                        statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    @Test func httpStatusSurvivesNSErrorBridgingAndAVFoundationWrapping() throws {
        let statuses: [(Int, PlaybackFailureReason)] = [
            (500, .serviceUnavailable), (502, .serviceUnavailable), (503, .serviceUnavailable),
            (408, .timeout), (401, .authentication), (403, .forbidden),
            (404, .unavailable), (429, .rateLimited)
        ]
        for (status, expected) in statuses {
            do {
                _ = try CachingResponse.acceptedRange(response(status), requested: 0..<1_000, length: 1_000)
                Issue.record("An HTTP failure must not write into the cache")
            } catch {
                let bridged = error as NSError
                #expect(bridged.domain == AudioStreamResponseError.errorDomain)
                #expect(bridged.code == status)
                #expect(bridged.userInfo.isEmpty, "No URL, response body or account metadata crosses the error bridge")
                let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                                      userInfo: [NSUnderlyingErrorKey: bridged])
                #expect(PlaybackFailureReason.classify(wrapped) == expected)
                var policy = PlaybackRecovery()
                let decision = policy.request(for: UUID(), at: 25, error: wrapped, wantsToPlay: true,
                                              network: NetworkSnapshot(status: .online))
                if expected.isRetryable {
                    guard case .retry(let ticket) = decision else { Issue.record("Transient HTTP status should retry"); return }
                    #expect(ticket.position == 25)
                } else {
                    #expect(decision == .stop(expected))
                }
            }
        }
    }

    @Test func nestedTransportAndAccessErrorsKeepTheirActualCause() {
        let timeout = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                              userInfo: [NSUnderlyingErrorKey: URLError(.timedOut) as NSError])
        #expect(PlaybackFailureReason.classify(timeout) == .timeout)
        #expect(PlaybackFailureReason.classify(timeout).isRetryable)
        let forbidden = AudioStreamResponseError.httpStatus(403) as NSError
        let urlWrapper = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse,
                                 userInfo: [NSUnderlyingErrorKey: forbidden])
        let mediaWrapper = NSError(domain: "AVFoundationErrorDomain", code: -11819,
                                   userInfo: [NSUnderlyingErrorKey: urlWrapper])
        #expect(PlaybackFailureReason.classify(mediaWrapper) == .forbidden,
                "A concrete access verdict takes priority over a generic media-services error")
    }

    @Test func validPartialAndIgnoredRangeResponsesKeepTheirCacheOffsets() throws {
        let partial = response(206, headers: ["Content-Type": "audio/mp4", "Content-Range": "bytes 500-999/1000", "Content-Length": "500"])
        #expect(try CachingResponse.acceptedRange(partial, requested: 500..<1_000, length: 1_000) == 500..<1_000)
        let shorter = response(206, headers: ["Content-Range": "bytes 500-749/1000", "Content-Length": "250"])
        #expect(try CachingResponse.acceptedRange(shorter, requested: 500..<1_000, length: 1_000) == 500..<750)
        let full = response(200, headers: ["Content-Type": "application/octet-stream", "Content-Length": "1000"])
        #expect(try CachingResponse.acceptedRange(full, requested: 500..<1_000, length: 1_000) == 0..<1_000)
    }

    @Test func wrongSuccessResponseFormatAndRangeRemainNonretryable() {
        let invalid = [
            response(200, headers: ["Content-Type": "text/html", "Content-Length": "1000"]),
            response(200, headers: ["Content-Type": "audio/mp4", "Content-Length": "500"]),
            response(200, headers: ["Content-Type": "audio/mp4", "Content-Range": "bytes 500-999/1000"]),
            response(206, headers: ["Content-Type": "audio/mp4"]),
            response(206, headers: ["Content-Range": "bytes 0-499/1000", "Content-Length": "500"]),
            response(206, headers: ["Content-Range": "bytes 500-999/2000", "Content-Length": "500"]),
            response(206, headers: ["Content-Range": "bytes 500-999/1000", "Content-Length": "900"]),
            response(206, headers: ["Content-Range": "bytes 500-9223372036854775807/*"])
        ]
        for response in invalid {
            do {
                _ = try CachingResponse.acceptedRange(response, requested: 500..<1_000, length: 1_000)
                Issue.record("Invalid successful-response metadata must not corrupt the cache")
            } catch {
                let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                                      userInfo: [NSUnderlyingErrorKey: error as NSError])
                #expect(PlaybackFailureReason.classify(wrapped) == .unavailable)
                #expect(!PlaybackFailureReason.classify(wrapped).isRetryable)
            }
        }
    }
}
