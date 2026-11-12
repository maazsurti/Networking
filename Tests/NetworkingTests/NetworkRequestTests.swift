import Foundation
import Testing
@testable import Networking

@Suite(.serialized)
struct NetworkRequestTests {
    @Test func normalizesURLAndSendsConfirmedHeadersAndQuery() async throws {
        let network = makeNetwork(
            baseURL: "https://example.com/api/",
            authToken: "member-token",
            xToken: "api-token"
        )

        _ = try await network.request(
            type: EmptyNetworkResponse.self,
            queryParams: ["is_show_in_homepage": "1"],
            path: "login"
        )

        let request = try #require(RequestCaptureURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://example.com/api/login?is_show_in_homepage=1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer member-token")
        #expect(request.value(forHTTPHeaderField: "X-Token") == "api-token")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en")
    }

    @Test func preservesExistingBearerPrefixAndEncodesRefreshBody() async throws {
        let network = makeNetwork(
            baseURL: "https://example.com/api",
            authToken: "Bearer member-token",
            xToken: ""
        )

        _ = try await network.request(
            type: EmptyNetworkResponse.self,
            payload: TokenRefreshRequest(oldToken: "old-token"),
            method: .post,
            path: "auth/token"
        )

        let request = try #require(RequestCaptureURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://example.com/api/auth/token")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer member-token")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["old_token": "old-token"])
    }

    @Test func nonServerErrorStatusUsesBackendErrorMessage() async throws {
        RequestCaptureURLProtocol.responseData = Data(#"{"status":"error","message":"Email already exists"}"#.utf8)
        defer {
            RequestCaptureURLProtocol.statusCode = 200
            RequestCaptureURLProtocol.responseData = Data("{}".utf8)
        }

        let network = makeNetwork(baseURL: "https://example.com/api", authToken: "", xToken: "")
        RequestCaptureURLProtocol.statusCode = 422

        do {
            _ = try await network.request(type: EmptyNetworkResponse.self, path: "login")
            Issue.record("Expected the backend error message to be thrown")
        } catch {
            #expect(error.localizedDescription == "Email already exists")
        }
    }

    @Test func logicalFailureUsesBackendErrorMessage() async throws {
        RequestCaptureURLProtocol.responseData = Data(#"{"success":0,"message":"Invalid coupon"}"#.utf8)
        defer { RequestCaptureURLProtocol.responseData = Data("{}".utf8) }

        let network = makeNetwork(baseURL: "https://example.com/api", authToken: "", xToken: "")

        do {
            _ = try await network.request(type: EmptyNetworkResponse.self, path: "login")
            Issue.record("Expected the backend logical failure message to be thrown")
        } catch {
            #expect(error.localizedDescription == "Invalid coupon")
        }
    }

    @Test func serverErrorStatusUsesGenericErrorMessage() async throws {
        RequestCaptureURLProtocol.responseData = Data(#"{"message":"Service unavailable"}"#.utf8)
        defer {
            RequestCaptureURLProtocol.statusCode = 200
            RequestCaptureURLProtocol.responseData = Data("{}".utf8)
        }

        let network = makeNetwork(baseURL: "https://example.com/api", authToken: "", xToken: "")
        RequestCaptureURLProtocol.statusCode = 500

        do {
            _ = try await network.request(type: EmptyNetworkResponse.self, path: "login")
            Issue.record("Expected the generic server error message to be thrown")
        } catch {
            #expect(error.localizedDescription == "An unknown error occured. Please try again later")
        }
    }

    private func makeNetwork(baseURL: String, authToken: String, xToken: String) -> Network {
        RequestCaptureURLProtocol.lastRequest = nil
        RequestCaptureURLProtocol.requests = []
        RequestCaptureURLProtocol.statusCode = 200
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestCaptureURLProtocol.self]
        return Network(
            baseURL: baseURL,
            configuration: configuration,
            headers: NetworkHeaderProvider(
                acceptLanguage: { "en" },
                authToken: { authToken },
                xToken: { xToken },
                previewAuthToken: { nil }
            )
        )
    }
}

private struct EmptyNetworkResponse: Codable {}

private struct TokenRefreshRequest: Codable {
    let oldToken: String

    enum CodingKeys: String, CodingKey {
        case oldToken = "old_token"
    }
}

private final class RequestCaptureURLProtocol: URLProtocol {
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var responseData = Data("{}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var capturedRequest = request
        if capturedRequest.httpBody == nil, let stream = capturedRequest.httpBodyStream {
            stream.open()
            var body = Data()
            let bufferSize = 1024
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: bufferSize)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            stream.close()
            capturedRequest.httpBody = body
        }
        Self.lastRequest = capturedRequest
        Self.requests.append(capturedRequest)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
