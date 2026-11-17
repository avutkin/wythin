import Foundation

struct HealthEnrollment: Codable, Equatable, Sendable {
    var installationId: UUID
    var credential: String
    /// Retained with the installation secret across reinstall to resume its writer stream.
    var streamId: UUID? = nil
}

struct HealthConnectionResponse: Codable, Equatable, Sendable {
    var connectionId: UUID
    var connectionEpoch: Int
    var expectedSequence: Int
}

struct HealthBatchAck: Codable, Equatable, Sendable {
    var batchId: UUID
    var sequence: Int
    var connectionEpoch: Int
    var serverRevision: Int
}

struct HealthRestorePage: Sendable {
    var items: [Data]
    var nextCursor: String?
    var hasMore: Bool = false
}

struct HealthRestoreDetail: Sendable {
    var item: Data
    var samples: [Data]
    var nextSamplesCursor: String? = nil
}

protocol HealthCloudTransport: Sendable {
    func enroll() async throws -> HealthEnrollment
    func connect(streamId: UUID, credential: String) async throws -> HealthConnectionResponse
    func send(batch: Data, credential: String) async throws -> HealthBatchAck
    func restore(cursor: String?, credential: String) async throws -> HealthRestorePage
    func detail(externalId: UUID, credential: String, cursor: String?) async throws -> HealthRestoreDetail
    func purge(epoch: Int, credential: String) async throws -> Int
    func pause(connectionId: UUID, credential: String) async throws
}

/// Deliberately excludes response bodies, URLs and credentials from user-visible errors.
struct HealthCloudError: Error, LocalizedError, Sendable {
    enum Reason: Sendable { case http, invalidServer, invalidCredential, invalidResponse, responseTooLarge, requestTooLarge, network }
    let status: Int
    let retryAfter: TimeInterval?
    let reason: Reason

    init(status: Int, retryAfter: TimeInterval? = nil) {
        self.status = status
        self.retryAfter = retryAfter
        self.reason = .http
    }

    init(reason: Reason) {
        self.status = 0
        self.retryAfter = nil
        self.reason = reason
    }

    var errorDescription: String? {
        switch reason {
        case .http: return "Health cloud request failed (HTTP \(status))."
        case .invalidServer: return "Health cloud requires a valid secure server address."
        case .invalidCredential: return "Health cloud credential is unavailable or invalid."
        case .invalidResponse: return "Health cloud returned an invalid response."
        case .responseTooLarge: return "Health cloud response exceeded the size limit."
        case .requestTooLarge: return "Health cloud batch exceeded the size limit."
        case .network: return "Health cloud could not connect. Try again when online."
        }
    }
}

/// Shared by transport and Keychain so a credential belongs to exactly one origin.
enum HealthServerOrigin {
    static func url(for server: URL) throws -> URL {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw HealthCloudError(reason: .invalidServer)
        }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard scheme == "https" || (scheme == "http" && local) else {
            throw HealthCloudError(reason: .invalidServer)
        }
        components.scheme = scheme
        components.host = host
        if components.port == (scheme == "https" ? 443 : 80) { components.port = nil }
        components.path = ""
        guard let origin = components.url else { throw HealthCloudError(reason: .invalidServer) }
        return origin
    }
}

final class HealthCloudRedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Even a same-origin redirect is not part of the Health API contract.
        completionHandler(nil)
    }
}

final class HealthCloudClient: HealthCloudTransport, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let redirectBlocker = HealthCloudRedirectBlocker()
    private static let maximumBytes = 2 * 1024 * 1024

    init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        // Retain injected protocol classes for testing, but never inherit legacy
        // authentication headers, cookies, caches or a credential storage policy.
        let configuration = session?.configuration ?? URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [:]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    func enroll() async throws -> HealthEnrollment {
        let data = try await request("POST", path: "/v1/health/installations", body: Data("{}".utf8))
        let value: HealthEnrollment = try decode(data)
        guard Self.validCredential(value.credential) else { throw HealthCloudError(reason: .invalidResponse) }
        return value
    }

    func connect(streamId: UUID, credential: String) async throws -> HealthConnectionResponse {
        struct Body: Encodable { let streamId: UUID; let cloudConsent = true; let consentVersion = "1" }
        let data = try await request("POST", path: "/v1/health/apple-health/connections", credential: credential,
                                     body: HealthCoding.encode(Body(streamId: streamId)))
        let value: HealthConnectionResponse = try decode(data)
        guard value.connectionEpoch > 0, value.expectedSequence > 0 else { throw HealthCloudError(reason: .invalidResponse) }
        return value
    }

    func send(batch: Data, credential: String) async throws -> HealthBatchAck {
        guard batch.count <= Self.maximumBytes else { throw HealthCloudError(reason: .requestTooLarge) }
        let data = try await request("POST", path: "/v1/health/apple-health/batches", credential: credential, body: batch)
        let value: HealthBatchAck = try decode(data)
        guard value.sequence > 0, value.connectionEpoch > 0, value.serverRevision >= 0 else { throw HealthCloudError(reason: .invalidResponse) }
        return value
    }

    func restore(cursor: String?, credential: String) async throws -> HealthRestorePage {
        var query = [URLQueryItem(name: "limit", value: "100")]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let data = try await request("GET", path: "/v1/health/activities", credential: credential, query: query)
        do {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = root["items"] as? [[String: Any]], items.count <= 100,
                  root["has_more"] == nil || root["has_more"] is Bool,
                  root["next_cursor"] == nil || root["next_cursor"] is NSNull || root["next_cursor"] is String else {
                throw HealthCloudError(reason: .invalidResponse)
            }
            return HealthRestorePage(items: try items.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) },
                                     nextCursor: root["next_cursor"] as? String,
                                     hasMore: root["has_more"] as? Bool ?? false)
        } catch { throw HealthCloudError(reason: .invalidResponse) }
    }

    func purge(epoch: Int, credential: String) async throws -> Int {
        struct Response: Decodable { var connectionEpoch: Int }
        let data = try await request("DELETE", path: "/v1/health/apple-health/data", credential: credential,
                                     query: [URLQueryItem(name: "connection_epoch", value: String(epoch))])
        let value: Response = try decode(data)
        guard value.connectionEpoch > 0 else { throw HealthCloudError(reason: .invalidResponse) }
        return value.connectionEpoch
    }

    func detail(externalId: UUID, credential: String, cursor: String? = nil) async throws -> HealthRestoreDetail {
        var query = [URLQueryItem(name: "sample_limit", value: "500")]
        if let cursor { query.append(URLQueryItem(name: "samples_cursor", value: cursor)) }
        let data = try await request("GET", path: "/v1/health/activities/\(externalId.uuidString.lowercased())", credential: credential, query: query)
        do {
            guard let item = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let samples = item["samples"] as? [[String: Any]], samples.count <= 500,
                  item["next_samples_cursor"] == nil || item["next_samples_cursor"] is NSNull || item["next_samples_cursor"] is String else {
                throw HealthCloudError(reason: .invalidResponse)
            }
            return HealthRestoreDetail(item: data,
                                       samples: try samples.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) },
                                       nextSamplesCursor: item["next_samples_cursor"] as? String)
        } catch { throw HealthCloudError(reason: .invalidResponse) }
    }

    func pause(connectionId: UUID, credential: String) async throws {
        _ = try await request("PATCH", path: "/v1/health/apple-health/connections/\(connectionId.uuidString.lowercased())",
                              credential: credential, body: Data("{\"cloud_consent\":false}".utf8))
    }

    private func request(_ method: String, path: String, credential: String? = nil,
                         body: Data? = nil, query: [URLQueryItem] = []) async throws -> Data {
        let origin = try HealthServerOrigin.url(for: baseURL)
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            throw HealthCloudError(reason: .invalidServer)
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw HealthCloudError(reason: .invalidServer) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let credential {
            guard Self.validCredential(credential) else { throw HealthCloudError(reason: .invalidCredential) }
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: redirectBlocker)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw HealthCloudError(reason: .invalidResponse) }
            guard (200..<300).contains(http.statusCode) else {
                throw HealthCloudError(status: http.statusCode, retryAfter: Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After")))
            }
            guard http.expectedContentLength <= Self.maximumBytes else { throw HealthCloudError(reason: .responseTooLarge) }
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.maximumBytes else { throw HealthCloudError(reason: .responseTooLarge) }
                data.append(byte)
            }
            return data
        } catch let error as HealthCloudError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw HealthCloudError(reason: .network)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try HealthCoding.decode(T.self, from: data) }
        catch { throw HealthCloudError(reason: .invalidResponse) }
    }

    private static func validCredential(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && value.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
    }

    private static func retryDelay(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 { return seconds }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return format.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }
}
