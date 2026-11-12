import Foundation

public struct APIClientConfiguration: Equatable {
    public let bootstrapOldToken: String?

    public init(bootstrapOldToken: String?) {
        let value = bootstrapOldToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty, !value.hasPrefix("$(") {
            self.bootstrapOldToken = value
        } else {
            self.bootstrapOldToken = nil
        }
    }

    public static func from(bundle: Bundle = .main) -> APIClientConfiguration {
        APIClientConfiguration(
            bootstrapOldToken: bundle.object(forInfoDictionaryKey: "APIBootstrapOldToken") as? String
        )
    }
}
