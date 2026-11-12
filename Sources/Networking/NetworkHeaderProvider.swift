import Foundation

/// Per-request header values injected into `Network`, so the network layer reads
/// closures instead of globals. Closures are evaluated at request time, so
/// language and auth changes are picked up live. The app supplies real closures;
/// tests pass fakes without touching `UserDefaults`.
public struct NetworkHeaderProvider {
    /// `Accept-Language` value: "ar" or "en".
    public var acceptLanguage: () -> String
    /// Stored auth token, empty when none.
    public var authToken: () -> String
    /// API session token sent as `X-Token`, empty until caller configures one.
    public var xToken: () -> String
    /// Country identifier sent as `x_country` to country-scoped collection APIs.
    public var country: () -> String
    /// `Authorization` bearer used only in preview-debug builds, `nil` otherwise.
    public var previewAuthToken: () -> String?

    public init(
        acceptLanguage: @escaping () -> String,
        authToken: @escaping () -> String,
        xToken: @escaping () -> String,
        country: @escaping () -> String = { "91" },
        previewAuthToken: @escaping () -> String?
    ) {
        self.acceptLanguage = acceptLanguage
        self.authToken = authToken
        self.xToken = xToken
        self.country = country
        self.previewAuthToken = previewAuthToken
    }

    /// Neutral defaults: no language preference, no auth, no country override.
    public static var neutral: NetworkHeaderProvider {
        NetworkHeaderProvider(
            acceptLanguage: { "en" },
            authToken: { "" },
            xToken: { "" },
            previewAuthToken: { nil }
        )
    }
}
