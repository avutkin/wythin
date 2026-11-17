import XCTest
@testable import Wythin

final class HealthCloudClientTests: XCTestCase {
    private let installationID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let connectionID = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
    private let batchID = UUID(uuidString: "30000000-0000-4000-8000-000000000003")!
    private let streamID = UUID(uuidString: "40000000-0000-4000-8000-000000000004")!

    private func client(_ handler: @escaping (URLRequest) throws -> HealthHTTPFixture) -> HealthCloudClient {
        HealthTestURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HealthTestURLProtocol.self]
        // A shared app session must not leak its legacy credentials to Health.
        configuration.httpAdditionalHeaders = ["X-API-Key": "legacy-secret", "X-User-ID": "legacy-owner"]
        return HealthCloudClient(baseURL: URL(string: "https://health.example.test")!, session: URLSession(configuration: configuration))
    }

    override func tearDown() {
        HealthTestURLProtocol.handler = nil
        super.tearDown()
    }

    func testEnrollmentUsesIndependentAnonymousEndpoint() async throws {
        let client = client { request in
            XCTAssertEqual(request.url?.path, "/v1/health/installations")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-User-ID"))
            XCTAssertEqual(try Self.body(request), Data("{}".utf8))
            return .json("{\"installation_id\":\"10000000-0000-4000-8000-000000000001\",\"credential\":\"installation-secret\"}", status: 201)
        }
        let enrolled = try await client.enroll()
        XCTAssertEqual(enrolled, HealthEnrollment(installationId: installationID, credential: "installation-secret"))
    }

    func testConnectionUsesBearerAndExplicitCloudConsent() async throws {
        let client = client { request in
            XCTAssertEqual(request.url?.path, "/v1/health/apple-health/connections")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer installation-secret")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-User-ID"))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Any])
            XCTAssertEqual(body["stream_id"] as? String, "40000000-0000-4000-8000-000000000004")
            XCTAssertEqual(body["cloud_consent"] as? Bool, true)
            XCTAssertEqual(body["consent_version"] as? String, "1")
            return .json("{\"connection_id\":\"20000000-0000-4000-8000-000000000002\",\"connection_epoch\":3,\"expected_sequence\":12}")
        }
        let connected = try await client.connect(streamId: streamID, credential: "installation-secret")
        XCTAssertEqual(connected.connectionId, connectionID)
        XCTAssertEqual(connected.connectionEpoch, 3)
        XCTAssertEqual(connected.expectedSequence, 12)
    }

    func testBatchRetriesSendFrozenBytesUnchanged() async throws {
        let frozen = Data("{ \"sequence\":12, \"changes\":[] }".utf8)
        let client = client { request in
            XCTAssertEqual(request.url?.path, "/v1/health/apple-health/batches")
            XCTAssertEqual(try Self.body(request), frozen)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer installation-secret")
            return .json("{\"batch_id\":\"30000000-0000-4000-8000-000000000003\",\"sequence\":12,\"connection_epoch\":3,\"server_revision\":42,\"workout_mappings\":{}}")
        }
        let first = try await client.send(batch: frozen, credential: "installation-secret")
        let second = try await client.send(batch: frozen, credential: "installation-secret")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.batchId, batchID)
        XCTAssertEqual(first.sequence, 12)
        XCTAssertEqual(first.connectionEpoch, 3)
        XCTAssertEqual(first.serverRevision, 42)
    }

    func testRestoreEncodesOpaqueCursorAndPreservesTombstonesAndDates() async throws {
        let cursor = "opaque+cursor/=&"
        let client = client { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/health/activities")
            let queries = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(queries?.first(where: { $0.name == "cursor" })?.value, cursor)
            XCTAssertEqual(queries?.first(where: { $0.name == "limit" })?.value, "100")
            return .json("""
            {"items":[{"external_id":"10000000-0000-4000-8000-000000000001","deleted":true,"server_revision":8,"started_at":"2026-11-15T12:00:00Z"},{"external_id":"20000000-0000-4000-8000-000000000002","deleted":false,"server_revision":9,"started_at":"2026-11-15T12:00:00.125Z"}],"next_cursor":"next-token"}
            """)
        }
        let page = try await client.restore(cursor: cursor, credential: "installation-secret")
        struct Item: Decodable { var externalId: UUID; var deleted: Bool; var startedAt: Date }
        let rows = try page.items.map { try HealthCoding.decode(Item.self, from: $0) }
        XCTAssertEqual(page.nextCursor, "next-token")
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].deleted)
        XCTAssertEqual(rows[1].startedAt.timeIntervalSince(rows[0].startedAt), 0.125, accuracy: 0.001)
    }

    func testPurgeAndPauseUseScopedEndpoints() async throws {
        let client = client { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer installation-secret")
            if request.httpMethod == "DELETE" {
                XCTAssertEqual(request.url?.path, "/v1/health/apple-health/data")
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "connection_epoch", value: "3")])
                return .json("{\"connection_epoch\":4}")
            }
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.url?.path, "/v1/health/apple-health/connections/20000000-0000-4000-8000-000000000002")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Bool])
            XCTAssertEqual(body, ["cloud_consent": false])
            return HealthHTTPFixture(status: 204, body: Data())
        }
        let epoch = try await client.purge(epoch: 3, credential: "installation-secret")
        XCTAssertEqual(epoch, 4)
        try await client.pause(connectionId: connectionID, credential: "installation-secret")
    }

    func testRestoreContinuationUsesHasMoreEvenWhenFinalPageRetainsCursor() async throws {
        let client = client { request in
            let queries = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            if queries?.contains(where: { $0.name == "cursor" }) == true {
                return .json("{\"items\":[],\"next_cursor\":\"saved-watermark\",\"has_more\":false}")
            }
            return .json("{\"items\":[],\"next_cursor\":\"next-page\",\"has_more\":true}")
        }
        let first = try await client.restore(cursor: nil, credential: "installation-secret")
        XCTAssertTrue(first.hasMore)
        let last = try await client.restore(cursor: first.nextCursor, credential: "installation-secret")
        XCTAssertEqual(last.nextCursor, "saved-watermark")
        XCTAssertFalse(last.hasMore)
    }

    func testDetailRestoresSampleJSONUnderTheInstallationCredential() async throws {
        let client = client { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/health/activities/10000000-0000-4000-8000-000000000001")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer installation-secret")
            return .json("""
            {"external_id":"10000000-0000-4000-8000-000000000001","deleted":false,"server_revision":8,"samples":[{"external_id":"20000000-0000-4000-8000-000000000002","value":120,"metric":"heart_rate"}]}
            """)
        }
        let detail = try await client.detail(externalId: installationID, credential: "installation-secret")
        let item = try XCTUnwrap(JSONSerialization.jsonObject(with: detail.item) as? [String: Any])
        XCTAssertEqual(item["external_id"] as? String, installationID.uuidString.lowercased())
        XCTAssertEqual(detail.samples.count, 1)
        let sample = try XCTUnwrap(JSONSerialization.jsonObject(with: detail.samples[0]) as? [String: Any])
        XCTAssertEqual(sample["value"] as? Int, 120)
    }

    func testDetailEncodesSampleCursorAndReturnsNextSamplePage() async throws {
        let cursor = "sample+page/=&"
        let client = client { request in
            XCTAssertEqual(request.url?.path, "/v1/health/activities/10000000-0000-4000-8000-000000000001")
            let queries = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(queries?.first(where: { $0.name == "sample_limit" })?.value, "500")
            XCTAssertEqual(queries?.first(where: { $0.name == "samples_cursor" })?.value, cursor)
            return .json("""
            {"external_id":"10000000-0000-4000-8000-000000000001","deleted":false,"server_revision":8,"samples":[],"next_samples_cursor":"sample-page-3"}
            """)
        }
        let detail = try await client.detail(externalId: installationID, credential: "installation-secret", cursor: cursor)
        XCTAssertTrue(detail.samples.isEmpty)
        XCTAssertEqual(detail.nextSamplesCursor, "sample-page-3")
    }

    func testHTTPFailureExposesRetryDelayWithoutSensitiveBody() async throws {
        let client = client { _ in HealthHTTPFixture(status: 429, body: Data("patient-data-and-secret".utf8), headers: ["Retry-After": "120"]) }
        do {
            _ = try await client.enroll()
            XCTFail("Expected rate limit failure")
        } catch let error as HealthCloudError {
            XCTAssertEqual(error.status, 429)
            XCTAssertEqual(error.retryAfter, 120)
            XCTAssertFalse(error.localizedDescription.contains("patient-data"))
        }
    }

    func testMalformedResponseDoesNotExposeServerContents() async throws {
        let client = client { _ in .json("{\"credential\":\"patient-data-and-secret\"}") }
        do {
            _ = try await client.enroll()
            XCTFail("Expected response validation failure")
        } catch let error as HealthCloudError {
            XCTAssertFalse(error.localizedDescription.contains("patient-data"))
            XCTAssertEqual(error.reason, .invalidResponse)
        }
    }

    func testResponsesAreBoundedEvenWithoutContentLength() async throws {
        let client = client { _ in HealthHTTPFixture(status: 200, body: Data(repeating: 65, count: 2 * 1024 * 1024 + 1)) }
        do {
            _ = try await client.enroll()
            XCTFail("Expected response size failure")
        } catch let error as HealthCloudError {
            XCTAssertEqual(error.reason, .responseTooLarge)
        }
    }

    func testInsecureOriginsAndURLCredentialsAreRejectedBeforeSending() async throws {
        HealthTestURLProtocol.handler = { _ in XCTFail("Invalid origin reached network"); return .json("{}") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HealthTestURLProtocol.self]
        for raw in ["http://health.example.test", "https://user:secret@health.example.test", "https://health.example.test?token=secret"] {
            let client = HealthCloudClient(baseURL: URL(string: raw)!, session: URLSession(configuration: configuration))
            do {
                _ = try await client.enroll()
                XCTFail("Expected invalid server")
            } catch let error as HealthCloudError {
                XCTAssertEqual(error.reason, .invalidServer)
            }
        }
    }

    func testRedirectDelegateRefusesCrossOriginCredentialExport() async throws {
        let delegate = HealthCloudRedirectBlocker()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let origin = URL(string: "https://health.example.test/v1/health/activities")!
        let redirected = URLRequest(url: URL(string: "https://attacker.example/collect")!)
        let response = HTTPURLResponse(url: origin, statusCode: 307, httpVersion: nil, headerFields: ["Location": redirected.url!.absoluteString])!
        let task = session.dataTask(with: origin)
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) { permitted in
            XCTAssertNil(permitted)
        }
    }

    func testCredentialNamespaceCanonicalizesOriginAndSeparatesServers() throws {
        let a = try HealthCredentialStore.namespace(for: URL(string: "https://HEALTH.example.test:443/path")!)
        let same = try HealthCredentialStore.namespace(for: URL(string: "https://health.example.test/")!)
        let other = try HealthCredentialStore.namespace(for: URL(string: "https://other.example.test/")!)
        let port = try HealthCredentialStore.namespace(for: URL(string: "https://health.example.test:8443/")!)
        XCTAssertEqual(a, same)
        XCTAssertNotEqual(a, other)
        XCTAssertNotEqual(a, port)
        XCTAssertFalse(a.contains("example.test"))
        XCTAssertThrowsError(try HealthCredentialStore.namespace(for: URL(string: "http://health.example.test")!))
    }

    func testStoredEnrollmentRetainsWriterStreamAndDecodesEnrollmentWithoutIt() throws {
        let oldWire = Data("{\"installation_id\":\"10000000-0000-4000-8000-000000000001\",\"credential\":\"installation-secret\"}".utf8)
        var value = try HealthCoding.decode(HealthEnrollment.self, from: oldWire)
        XCTAssertNil(value.streamId)
        value.streamId = streamID
        let decoded = try HealthCoding.decode(HealthEnrollment.self, from: HealthCoding.encode(value))
        XCTAssertEqual(decoded.streamId, streamID)
        XCTAssertEqual(decoded.installationId, installationID)
        XCTAssertEqual(decoded.credential, "installation-secret")
    }

    private static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if read == 0 { break }
            result.append(contentsOf: buffer.prefix(read))
        }
        return result
    }
}

private struct HealthHTTPFixture {
    var status: Int
    var body: Data
    var headers: [String: String] = [:]
    static func json(_ value: String, status: Int = 200) -> Self {
        Self(status: status, body: Data(value.utf8), headers: ["Content-Type": "application/json"])
    }
}

private final class HealthTestURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> HealthHTTPFixture)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let fixture = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: fixture.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: fixture.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
