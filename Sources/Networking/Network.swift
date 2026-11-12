import Foundation
import UIKit

/// Multipart form fields for `uploadImage`.
public typealias Params = [String: Any]

/// Message used when the backend gives no usable error body.
public let networkErrorMessage = "An unknown error occured. Please try again later"

/// Failure used when a build disallows backend calls, e.g. Debug running on mocks.
public let networkDisabledMessage = "Network access is disabled; API calls are for the live service only."

public protocol GenericAPI {
    var session: URLSession { get }
    var baseURL: String { get }
    var headers: NetworkHeaderProvider { get }
    /// Called when a response returns 401, so the app can clear the session and
    /// route to auth. Evaluated off the main actor, so it must hop itself.
    var onUnauthorized: @Sendable () -> Void { get }
    /// `false` makes every request fail before it leaves the process. Debug
    /// builds run entirely on mock services and never call the backend.
    var allowsNetworkAccess: Bool { get }
    var codedErrors: Set<String> { get }
    func request<T: Codable>(
        type: T.Type,
        payload: (any Codable)?,
        queryParams: [String: String]?,
        method: Method,
        path: String,
        contentFormat: ContentFormat,
        debug: Bool
    ) async throws -> T
    func uploadImage<T: Codable>(
        type: T.Type,
        image: UIImage?,
        params: Params?,
        method: Method,
        path: String,
        queryParams: [String: String]?,
        imageKey: String,
        debug: Bool
    ) async throws -> T
}

public extension GenericAPI {

    /// Conformers that don't opt out may reach the backend.
    var allowsNetworkAccess: Bool { true }

    var codedErrors: Set<String> { [] }
}

extension GenericAPI {

    public func request<T: Codable>(
        type: T.Type,
        payload: (any Codable)? = nil,
        queryParams: [String: String]? = nil,
        method: Method = .get,
        path: String,
        contentFormat: ContentFormat = .json,
        debug: Bool = false
    )  async throws -> T {

        guard allowsNetworkAccess else {
            throw APIError.requestFailed(description: networkDisabledMessage)
        }

        var urlString = joinedURLString(path: path)

            if let queryParameters = queryParams, !queryParameters.isEmpty {
                var queryItems = [URLQueryItem]()
                for (key, value) in queryParameters {
                    queryItems.append(URLQueryItem(name: key, value: value))
                }

                var urlComponents = URLComponents(string: urlString)
                urlComponents?.queryItems = queryItems
                if let modifiedURL = urlComponents?.url {
                    urlString = modifiedURL.absoluteString
                }
            }

            guard let modifiedURL = URL(string: urlString) else {
                throw APIError.invalidURL
            }

            // Captured before the network suspension so the 401 handler can run
            // without touching `self` after the await.
            let onUnauthorized = onUnauthorized

            var request = URLRequest(url: modifiedURL)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(headers.acceptLanguage(), forHTTPHeaderField: "Accept-Language")

            let authToken = headers.authToken().trimmingCharacters(in: .whitespacesAndNewlines)
            if !authToken.isEmpty {
                let bearer = authToken.lowercased().hasPrefix("bearer ")
                    ? authToken
                    : "Bearer \(authToken)"
                request.setValue(bearer, forHTTPHeaderField: "Authorization")
            }

            let xToken = headers.xToken().trimmingCharacters(in: .whitespacesAndNewlines)
            if !xToken.isEmpty {
                request.setValue(xToken, forHTTPHeaderField: "X-Token")
            }

            let country = headers.country().trimmingCharacters(in: .whitespacesAndNewlines)
            if !country.isEmpty {
                request.setValue(country, forHTTPHeaderField: "x_country")
            }

            if let previewAuthToken = headers.previewAuthToken() {
                request.setValue(previewAuthToken, forHTTPHeaderField: "Authorization")
            }

            // Handle both params and payload based on content format
            switch contentFormat {
            case .json:
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if let payload = payload {
                    do {
                        let encoder = JSONEncoder()
                        request.httpBody = try encoder.encode(payload)
                    } catch {
                        throw APIError.failedSerialization
                    }
                }

            case .urlEncoded:
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                var formDataDict: [String: Any] = [:]

                if let payload = payload {
                    // Convert Codable payload to dictionary for form data
                    do {
                        let encoder = JSONEncoder()
                        let jsonData = try encoder.encode(payload)
                        if let jsonDict = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
                            formDataDict = jsonDict
                        }
                    } catch {
                        throw APIError.failedSerialization
                    }
                }

                if !formDataDict.isEmpty {
                    request.httpBody = formDataDict.percentEncoded()
                }
            }

            request.httpMethod = method.rawValue

            let (data, response) = try await session.data(for: request)

            if debug {
                debugPrint("URL is \(modifiedURL)")
                debugPrint("Content Format: \(contentFormat)")
                if let payload = payload {
                    if let jsonData = try? JSONEncoder().encode(payload),
                       let jsonString = String(data: jsonData, encoding: .utf8) {
                        print("Payload: \(jsonString)")
                    }
                }
                if (queryParams != nil) {
                    print("Query params: \(queryParams ?? [:])")
                }
                print("Method is \(method)")
                print("Headers: \(request.allHTTPHeaderFields ?? [:])")
                if let responseString = String(data: data, encoding: .utf8) {
                    print("Response: \(responseString)")
                }
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.requestFailed(description: "Invalid response")
            }

            if httpResponse.statusCode == 401 {
                onUnauthorized()
            }

            guard httpResponse.statusCode < 500 else {
                if !debug {
                    debugPrint("URL is \(modifiedURL)")
                    if let payload = payload {
                        if let jsonData = try? JSONEncoder().encode(payload),
                           let jsonString = String(data: jsonData, encoding: .utf8) {
                            print("Payload: \(jsonString)")
                        }
                    }
                    if (queryParams != nil) {
                        print("Query params: \(queryParams ?? [:])")
                    }
                    print("Method is \(method)")
                    print("Headers: \(request.allHTTPHeaderFields ?? [:])")
                }

                throw APIError.serverMessage(description: networkErrorMessage)
            }

            if let error = serverError(data: data, statusCode: httpResponse.statusCode, codedErrors: codedErrors) {
                throw error
            }

            do {
                let decoder = JSONDecoder()
                return try decoder.decode(type, from: data)
            } catch let error as DecodingError {
                switch error {
                case .typeMismatch(let key, let value):
                    print("Type mismatch for key: \(key), expected type: \(value), Error: \(error.localizedDescription)")
                case .valueNotFound(let key, let value):
                    print("Value not found for key: \(key), expected type: \(value), Error: \(error.localizedDescription)")
                case .keyNotFound(let key, let context):
                    print("Key not found: \(key.stringValue)")
                    print("CodingPath: \(context.codingPath.map(\.stringValue).joined(separator: " -> "))")
                    print("Error: \(error.localizedDescription)")
                case .dataCorrupted(let context):
                    print("Data corrupted: \(context.debugDescription)")
                @unknown default:
                    print("Unhandled decoding error: \(error.localizedDescription)")
                }

                if debug {
                    if let responseString = String(data: data, encoding: .utf8) {
                        print("Response: \(responseString)")
                    }
                }

                debugPrint("URL is \(modifiedURL)")

                throw APIError.jsonConversionFailure(description: error.localizedDescription)
            }
        }

    public func uploadImage<T: Codable>(
        type: T.Type,
        image: UIImage? = nil,
        params: Params?,
        method: Method,
        path: String,
        queryParams: [String: String]? = nil,
        imageKey: String,
        debug: Bool = false
    ) async throws -> T {

        guard allowsNetworkAccess else {
            throw APIError.requestFailed(description: networkDisabledMessage)
        }

        var urlString = joinedURLString(path: path)

        if let queryParameters = queryParams, !queryParameters.isEmpty {
            let queryItems = queryParameters.map { URLQueryItem(name: $0.key, value: $0.value) }
            var urlComponents = URLComponents(string: urlString)
            urlComponents?.queryItems = queryItems
            urlString = urlComponents?.url?.absoluteString ?? urlString
        }

        guard let url = URL(string: urlString) else {
            throw APIError.invalidURL
        }

        // Captured before the network suspension so the 401 handler can run
        // without touching `self` after the await.
        let onUnauthorized = onUnauthorized
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(headers.acceptLanguage(), forHTTPHeaderField: "Accept-Language")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let authToken = headers.authToken().trimmingCharacters(in: .whitespacesAndNewlines)
        if !authToken.isEmpty {
            let bearer = authToken.lowercased().hasPrefix("bearer ")
                ? authToken
                : "Bearer \(authToken)"
            request.setValue(bearer, forHTTPHeaderField: "Authorization")
        }

        let xToken = headers.xToken().trimmingCharacters(in: .whitespacesAndNewlines)
        if !xToken.isEmpty {
            request.setValue(xToken, forHTTPHeaderField: "X-Token")
        }

        if let previewAuthToken = headers.previewAuthToken() {
            request.setValue(previewAuthToken, forHTTPHeaderField: "Authorization")
        }

        request.httpBody = Self.multipartBody(boundary: boundary, image: image, imageKey: imageKey, params: params)

        let (data, response) = try await session.data(for: request)

        if debug {
            print("Params: \(params ?? [:])")
            print("Query params: \(queryParams ?? [:])")
            print("Headers: \(request.allHTTPHeaderFields ?? [:])")
            debugPrint("URL is \(url)")
            if let responseString = String(data: data, encoding: .utf8) {
                print("Response: \(responseString)")
            }
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.requestFailed(description: "Invalid response")
        }

        if httpResponse.statusCode == 401 {
            onUnauthorized()
        }

        guard httpResponse.statusCode < 500 else {
            throw APIError.serverMessage(description: networkErrorMessage)
        }

        if let error = serverError(data: data, statusCode: httpResponse.statusCode, codedErrors: codedErrors) {
            throw error
        }

        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.jsonConversionFailure(description: error.localizedDescription)
        }
    }

    /// Builds a `multipart/form-data` body: a text part per `params` entry, then a
    /// JPEG file part for `image` when present.
    private static func multipartBody(boundary: String, image: UIImage?, imageKey: String, params: Params?) -> Data {
        var body = Data()
        let lineBreak = "\r\n"

        if let params {
            for (key, value) in params {
                body.append("--\(boundary)\(lineBreak)")
                body.append("Content-Disposition: form-data; name=\"\(key)\"\(lineBreak)\(lineBreak)")
                body.append("\(value)\(lineBreak)")
            }
        }

        if let imageData = image?.jpegData(compressionQuality: 0.5) {
            body.append("--\(boundary)\(lineBreak)")
            body.append("Content-Disposition: form-data; name=\"\(imageKey)\"; filename=\"\(UUID().uuidString).jpg\"\(lineBreak)")
            body.append("Content-Type: image/jpeg\(lineBreak)\(lineBreak)")
            body.append(imageData)
            body.append(lineBreak)
        }

        body.append("--\(boundary)--\(lineBreak)")
        return body
    }

    private func joinedURLString(path: String) -> String {
        baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/"
            + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

public final class Network: GenericAPI {
    public var session: URLSession
    public let baseURL: String
    public let headers: NetworkHeaderProvider
    public var onUnauthorized: @Sendable () -> Void
    public let allowsNetworkAccess: Bool
    public let codedErrors: Set<String>

    public init(
        baseURL: String,
        configuration: URLSessionConfiguration,
        headers: NetworkHeaderProvider = .neutral,
        onUnauthorized: @escaping @Sendable () -> Void = {},
        allowsNetworkAccess: Bool = true,
        codedErrors: Set<String> = []
    ) {
        self.baseURL = baseURL
        self.session = URLSession(configuration: configuration)
        self.headers = headers
        self.onUnauthorized = onUnauthorized
        self.allowsNetworkAccess = allowsNetworkAccess
        self.codedErrors = codedErrors
    }
}

private extension Data {
    /// Appends the UTF-8 bytes of `string`, used while assembling a multipart body.
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}

extension Dictionary {
    func percentEncoded() -> Data? {
        map { key, value in
            let escapedKey = "\(key)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let escapedValue = "\(value)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            return escapedKey + "=" + escapedValue
        }
        .joined(separator: "&")
        .data(using: .utf8)
    }
}

/// Maps a non-success response body to an ``APIError``. A form-submission
/// validation failure (HTTP 422) carries a per-field `errors` map
/// (`{"street": ["Please enter street name"]}`); that becomes
/// ``APIError/validationErrors`` so the caller can surface one message per
/// failing field. Otherwise the backend `message` is used, falling back through
/// the logical-failure checks for non-4xx envelopes.
private func serverError(data: Data, statusCode: Int, codedErrors: Set<String>) -> APIError? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

    if statusCode >= 400, let errors = object["errors"] as? [String: Any], !errors.isEmpty {
        let messages = errors.compactMap { _, value -> String? in
            if let strings = value as? [String] { return strings.first }
            if let string = value as? String { return string }
            return nil
        }
        let cleaned = messages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleaned.isEmpty { return .validationErrors(cleaned) }
    }

    guard let message = (object["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !message.isEmpty else {
        return nil
    }

    if statusCode >= 400 {
        if let code = object["code"] as? String, codedErrors.contains(code) {
            return .coded(code: code, description: message)
        }
        return .serverMessage(description: message)
    }

    let status = (object["status"] as? String)?.lowercased()
    let failedStatus = ["error", "failed", "failure"].contains(status)
    let failedSuccess: Bool = switch object["success"] {
    case let value as Bool: !value
    case let value as Int: value == 0
    case let value as String: ["0", "false", "error", "failed", "failure"].contains(value.lowercased())
    default: false
    }

    guard failedStatus || failedSuccess else { return nil }
    return .serverMessage(description: message)
}

public func apiResponseError(message: String? = nil) -> APIError {
    let message = message?.trimmingCharacters(in: .whitespacesAndNewlines)
    return .serverMessage(description: message.flatMap { $0.isEmpty ? nil : $0 } ?? "The request failed.")
}

public enum APIError: Error {
    case requestFailed(description: String)
    case invalidData
    case invalidURL
    case responseUnsuccessful(description: String)
    case serverMessage(description: String)
    case coded(code: String, description: String)
    case validationErrors([String])
    case jsonConversionFailure(description: String)
    case jsonParsingFailure
    case failedSerialization
    case noInternet
    case noData

    public var customDescription: String {
        switch self {
        case let .requestFailed(description): return "Request Failed: \(description)"
        case .invalidData: return "Invalid Data"
        case .invalidURL: return "Invalid URL"
        case let .responseUnsuccessful(description): return "Unsuccessful: \(description)"
        case let .serverMessage(description): return description
        case let .coded(_, description): return description
        case let .validationErrors(messages): return messages.joined(separator: "\n")
        case let .jsonConversionFailure(description): return "JSON Conversion Failure: \(description)"
        case .jsonParsingFailure: return "JSON Parsing Failure"
        case .failedSerialization: return "Serialization failed."
        case .noInternet: return "No internet connection"
        case .noData: return "The required data is empty"
        }
    }
}

public extension APIError {
    var validationMessages: [String] {
        if case let .validationErrors(messages) = self { return messages }
        return []
    }
}

extension APIError: LocalizedError {
    public var errorDescription: String? {
        customDescription
    }
}

public enum ContentFormat {
    case json
    case urlEncoded
}

public enum Method: String {
    case get = "GET"
    case post = "POST"
    case delete = "DELETE"
    case patch = "PATCH"
}
