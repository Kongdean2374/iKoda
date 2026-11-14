import Foundation

/// Positive evidence of an invalid local file. A generic unavailable/error verdict alone
/// cannot prove corruption: authorization, networking and audio-session errors retain bytes.
enum LocalAudioFailure {
    static func isConfirmed(_ error: Error?) -> Bool {
        guard let error else { return false }
        return verdict(error as NSError, depth: 0) == true
    }

    private static func verdict(_ error: NSError, depth: Int) -> Bool? {
        guard depth < 5 else { return nil }
        if error.domain == AudioStreamResponseError.errorDomain { return false }
        if error.domain == NSURLErrorDomain {
            return [NSURLErrorFileDoesNotExist, NSURLErrorCannotDecodeRawData, NSURLErrorCannotDecodeContentData].contains(error.code)
        }
        if error.domain == NSCocoaErrorDomain {
            return [NSFileReadNoSuchFileError, NSFileReadCorruptFileError, NSFileNoSuchFileError].contains(error.code)
        }
        if error.domain == NSPOSIXErrorDomain { return false }
        if error.domain == NSOSStatusErrorDomain, [-54, -5000].contains(error.code) { return false }
        if error.domain == "AVFoundationErrorDomain",
           [-11819, -11831, -11833, -11835, -11836, -11838, -11839].contains(error.code) { return false }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           let underlyingVerdict = verdict(underlying, depth: depth + 1) { return underlyingVerdict }
        if error.domain == "AVFoundationErrorDomain" {
            // Public AVError codes: decodeFailed, invalidSourceMedia,
            // fileFormatNotRecognized and fileFailedToParse. Decoder availability,
            // protected/unauthorized content and media-services resets are not corruption.
            return [-11821, -11822, -11828, -11829].contains(error.code)
        }
        return nil
    }
}
