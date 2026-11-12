# Networking

A small async/await HTTP client for iOS apps that talk to a JSON REST backend, plus a two-type
logging module (`Diagnostics`) it and other packages share.

## Products

- **`Networking`** — `Network` (a `URLSession` client), the `GenericAPI` protocol, `APIError`,
  `NetworkHeaderProvider` and `APIClientConfiguration`.
- **`Diagnostics`** — the `Log` protocol, `LogLevel` and `ConsoleLog`.

## Install

```swift
.package(url: "https://github.com/maazsurti/Networking.git", from: "1.0.0")
```

## Use

```swift
import Networking

let network = Network(
    baseURL: "https://api.example.com/v1",
    configuration: .default,
    headers: NetworkHeaderProvider(
        acceptLanguage: { "en" },
        authToken: { session.token },
        xToken: { "" },
        previewAuthToken: { nil }
    ),
    onUnauthorized: { Task { @MainActor in session.expire() } }
)

let profile = try await network.request(type: ProfileResponse.self, path: "user/profile")

let saved = try await network.request(
    type: SaveResponse.self,
    payload: update,
    method: .post,
    path: "user/profile"
)
```

Requests take a `path` relative to `baseURL`. An app that keeps its routes in an enum adds a
one-line overload that forwards the enum's path:

```swift
extension GenericAPI {
    func request<T: Codable>(type: T.Type, payload: (any Codable)? = nil,
                             queryParams: [String: String]? = nil, method: Method = .get,
                             with endpoint: Endpoint) async throws -> T {
        try await request(type: type, payload: payload, queryParams: queryParams,
                          method: method, path: endpoint.path)
    }
}
```

### What the client does for you

- Sends `Authorization: Bearer <token>` when a token is present (an existing `Bearer ` prefix is
  kept), plus `X-Token`, `Accept-Language` and `x_country` from the header provider.
- Encodes the payload as JSON or `application/x-www-form-urlencoded`; `uploadImage` sends
  `multipart/form-data` with a JPEG part.
- Calls `onUnauthorized` on a 401.
- Turns failures into `APIError`: a 422 `errors` map becomes `.validationErrors` (one message per
  field, also on `validationMessages`), a backend `message` becomes `.serverMessage`, and a 5xx
  becomes a generic message. A 2xx body whose `success` is `0`/`false` or whose `status` is
  `error`/`failed` is treated as a failure too.
- `codedErrors: ["CART_ITEM_UNAVAILABLE"]` turns a 4xx whose body `code` is in the set into
  `.coded(code:description:)`, for failures the app reacts to rather than only shows. Codes not in
  the set stay `.serverMessage`.
- `allowsNetworkAccess: false` fails every request before it leaves the process, for builds that
  must run on mocks.

## Requirements

iOS 17+, Swift 6 tools (Swift 5 language mode).
