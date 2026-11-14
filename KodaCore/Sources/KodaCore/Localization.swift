import Foundation

/// KodaCore is a Swift package, so its text belongs to its own resource bundle,
/// not the host application's main bundle. Keep lookup and bundle tests aligned.
enum KodaLocalization {
    static let bundle = Bundle.module
}
