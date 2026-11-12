import Testing
import Foundation
@testable import Networking

/// Verifies the auth-hardening contract on the network layer: a 401 response fires
/// the injected `onUnauthorized` closure (which `RootView` uses to clear the session
/// and route to auth), and a successful response does not.
///
/// A `StubURLProtocol` feeds canned responses without a real backend. The stub's
/// state is process-wide static, so the suite is serialized to avoid cross-test
/// races. `onUnauthorized` is a synchronous `@Sendable` closure invoked before the
/// request returns, so a lock-guarded flag box captures whether it fired.
@Suite(.serialized)
struct NetworkUnauthorizedTests {

    @Test func firesOnUnauthorizedFor401() async throws {
        let flag = Flag()
        let network = makeNetwork(onUnauthorized: { flag.set() })

        StubURLProtocol.statusCode = 401
        _ = try? await network.request(type: EmptyBody.self, path: "login")

        #expect(flag.value, "Expected onUnauthorized to fire on a 401 response.")
    }

    @Test func doesNotFireOnUnauthorizedFor200() async throws {
        let flag = Flag()
        let network = makeNetwork(onUnauthorized: { flag.set() })

        StubURLProtocol.statusCode = 200
        _ = try await network.request(type: EmptyBody.self, path: "login")

        #expect(!flag.value, "Expected onUnauthorized not to fire on a 200 response.")
    }

    // MARK: - Helpers

    private func makeNetwork(onUnauthorized: @escaping @Sendable () -> Void) -> Network {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let headers = NetworkHeaderProvider(
            acceptLanguage: { "en" },
            authToken: { "" },
            xToken: { "" },
            previewAuthToken: { nil }
        )
        return Network(
            baseURL: "https://test.example.com",
            configuration: configuration,
            headers: headers,
            onUnauthorized: onUnauthorized
        )
    }
}

/// Decodes from the stub's `{}` body; the request only needs a Codable target.
private struct EmptyBody: Codable {}

/// Lock-guarded boolean so the `@Sendable` `onUnauthorized` can record that it ran.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}

/// Returns a canned HTTP response with `statusCode` and an empty-JSON body, so
/// `Network` can be exercised without a backend.
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
