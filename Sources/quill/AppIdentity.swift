import Foundation

/// Bundle metadata, not the executable's filename, distinguishes installations.
enum AppIdentity {
    static let identifier = Bundle.main.bundleIdentifier ?? {
        preconditionFailure("Missing embedded bundle identifier")
    }()
    static let isLocal = Bundle.main.object(forInfoDictionaryKey: "QuillVariant") as? String == "local"
    static let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? ProcessInfo.processInfo.processName
}
