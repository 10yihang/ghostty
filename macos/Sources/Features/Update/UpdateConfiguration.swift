import Foundation

/// A fork build must identify its own feed and signing key before Sparkle starts.
struct UpdateConfiguration {
    static let feedURLString = "https://github.com/10yihang/ghostty/releases/latest/download/appcast.xml"
    private static let upstreamKey = "wsNcGf5hirwtdXMVnYoxRIX/SqZQLMOsYlD3q3imeok="

    let feedURL: URL

    init(bundle: Bundle) throws {
        guard let value = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !value.isEmpty else {
            throw ConfigurationError(reason: "This build is missing its fork SUFeedURL.")
        }
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com",
              components.path == "/10yihang/ghostty/releases/latest/download/appcast.xml",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url else {
            throw ConfigurationError(reason: "This build must use the HTTPS appcast from 10yihang/ghostty releases.")
        }
        guard let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let keyData = Data(base64Encoded: key), keyData.count == 32 else {
            throw ConfigurationError(reason: "This build is missing a valid fork update signing key.")
        }
        guard keyData != Data(base64Encoded: Self.upstreamKey) else {
            throw ConfigurationError(reason: "This build still uses the upstream update signing key instead of the fork key.")
        }
        self.feedURL = url
    }

    private struct ConfigurationError: LocalizedError {
        let reason: String

        var errorDescription: String? { "Fork updates unavailable. \(reason)" }
        var recoverySuggestion: String? {
            "Install a fork build with its own update feed and signing key. This build will not contact an upstream feed."
        }
    }
}
