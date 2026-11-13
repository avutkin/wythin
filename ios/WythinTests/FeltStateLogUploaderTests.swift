import XCTest
import SwiftData
@testable import Wythin

/// Real SwiftData persistence with only the network boundary replaced.
final class FeltStateLogUploaderTests: XCTestCase {

    private var defaults: UserDefaults!
    private let defaultsSuite = "FeltStateLogUploaderTests"
    private let watermarkKey = "feltStateLogs.lastUploadedTimestamp"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: defaultsSuite)!
        defaults.removePersistentDomain(forName: defaultsSuite)
        UserDefaults.standard.removeObject(forKey: watermarkKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: watermarkKey)
        defaults.removePersistentDomain(forName: defaultsSuite)
        super.tearDown()
    }

    private func makeContext() -> ModelContext {
        let schema = Schema([FeltStateLog.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private final class RecordingClient: FeltStateAPIClient, @unchecked Sendable {
        var baseURL = URL(string: "https://checkins.invalid")!
        var payloads: [FeltStateUploadPayload] = []
        func uploadFeltStateLog(_ payload: FeltStateUploadPayload, userID: String) async throws {
            payloads.append(payload)
        }
    }

    private final class FailingClient: FeltStateAPIClient, @unchecked Sendable {
        let baseURL = URL(string: "https://checkins.invalid")!
        struct Boom: Error {}
        func uploadFeltStateLog(_ payload: FeltStateUploadPayload, userID: String) async throws {
            throw Boom()
        }
    }

    @MainActor
    func testAcknowledgedAnswerIsNotResentByANewUploader() async {
        let context = makeContext()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        context.insert(FeltStateLog(timestamp: t, kind: "moment", focus: 40, energy: nil, stress: 20,
                                    mood: 71, anxiety: nil, sleep: nil, dayKey: "2027-01-15",
                                    timezone: "America/Los_Angeles", wornMinutes: 13.2, stateKey: nil))
        let client = RecordingClient()

        await FeltStateLogUploader(client: client, userID: "u", defaults: defaults).flushPending(context: context)

        XCTAssertEqual(client.payloads.count, 1)
        await FeltStateLogUploader(client: client, userID: "u", defaults: defaults).flushPending(context: context)
        XCTAssertEqual(client.payloads.count, 1)
    }

    @MainActor
    func testFailedUploadRemainsPendingForANewUploader() async {
        let context = makeContext()
        context.insert(FeltStateLog(timestamp: .now, kind: "moment", focus: 40, energy: nil, stress: nil,
                                    mood: nil, anxiety: nil, sleep: nil, dayKey: nil, timezone: nil,
                                    wornMinutes: nil, stateKey: nil))

        await FeltStateLogUploader(client: FailingClient(), userID: "u", defaults: defaults).flushPending(context: context)

        let client = RecordingClient()
        await FeltStateLogUploader(client: client, userID: "u", defaults: defaults).flushPending(context: context)
        XCTAssertEqual(client.payloads.count, 1)
    }

    private func log(at time: Date) -> FeltStateLog {
        FeltStateLog(timestamp: time, kind: "moment", focus: 60, energy: nil, stress: nil,
                     mood: nil, anxiety: nil, sleep: nil, dayKey: nil, timezone: nil,
                     wornMinutes: nil, stateKey: nil)
    }

    @MainActor
    func testLegacyWatermarkCannotSuppressHistoricalBackfill() async {
        let context = makeContext()
        let entry = log(at: Date(timeIntervalSince1970: 1_800_000_000))
        context.insert(entry)
        UserDefaults.standard.set(entry.timestamp.addingTimeInterval(100), forKey: watermarkKey)
        let client = RecordingClient()
        await FeltStateLogUploader(client: client, userID: "legacy", defaults: defaults).flushPending(context: context)
        XCTAssertEqual(client.payloads.map(\.id), [entry.id.uuidString])
    }

    @MainActor
    func testOlderAnswerAddedAfterSuccessfulUploadStillUploads() async {
        let context = makeContext()
        let newest = log(at: Date(timeIntervalSince1970: 1_800_000_000))
        context.insert(newest)
        let client = RecordingClient()
        let uploader = FeltStateLogUploader(client: client, userID: "restored", defaults: defaults)
        await uploader.flushPending(context: context)
        let restored = log(at: newest.timestamp.addingTimeInterval(-3600))
        context.insert(restored)
        await uploader.flushPending(context: context)
        XCTAssertEqual(client.payloads.map(\.id), [newest.id.uuidString, restored.id.uuidString])
    }

    private final class FailSecondClient: FeltStateAPIClient, @unchecked Sendable {
        let baseURL = URL(string: "https://checkins.invalid")!
        var attempts: [String] = []
        var accepted: [String] = []
        func uploadFeltStateLog(_ payload: FeltStateUploadPayload, userID: String) async throws {
            attempts.append(payload.id)
            if attempts.count == 2 { throw URLError(.networkConnectionLost) }
            accepted.append(payload.id)
        }
    }

    @MainActor
    func testInterruptedAnswersWithIdenticalTimestampsRetryTheUnacknowledgedAnswer() async {
        let context = makeContext()
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let a = log(at: time), b = log(at: time)
        context.insert(a); context.insert(b)
        let client = FailSecondClient()
        let uploader = FeltStateLogUploader(client: client, userID: "same-time", defaults: defaults)
        await uploader.flushPending(context: context)
        await uploader.flushPending(context: context)
        XCTAssertEqual(Set(client.accepted), Set([a.id.uuidString, b.id.uuidString]))
        XCTAssertEqual(client.accepted.count, 2)
    }

    @MainActor
    func testCloudOptOutKeepsAnswersPendingUntilEnabled() async {
        let context = makeContext()
        let entry = log(at: .now)
        context.insert(entry)
        defaults.set(false, forKey: "cloudSyncEnabled")
        let client = RecordingClient()
        let uploader = FeltStateLogUploader(client: client, userID: "u", defaults: defaults)
        await uploader.flushPending(context: context)
        XCTAssertTrue(client.payloads.isEmpty)
        XCTAssertNil(entry.uploadedDestination)
        defaults.set(true, forKey: "cloudSyncEnabled")
        await uploader.flushPending(context: context)
        XCTAssertEqual(client.payloads.map(\.id), [entry.id.uuidString])
    }

    @MainActor
    func testReceiptsBelongToTheActualServerAndIdentity() async {
        let context = makeContext()
        context.insert(log(at: .now))
        let client = RecordingClient()
        await FeltStateLogUploader(client: client, userID: "u1", defaults: defaults).flushPending(context: context)
        await FeltStateLogUploader(client: client, userID: "u2", defaults: defaults).flushPending(context: context)
        client.baseURL = URL(string: "https://other-server.invalid")!
        await FeltStateLogUploader(client: client, userID: "u2", defaults: defaults).flushPending(context: context)
        XCTAssertEqual(client.payloads.count, 3)
    }

    @MainActor
    func testReceiptScopePreservesTheExactTransmittedIdentity() async {
        let context = makeContext()
        context.insert(log(at: .now))
        let client = RecordingClient()
        let upper = "AAAAAAAA-0000-0000-0000-000000000001"
        await FeltStateLogUploader(client: client, userID: upper, defaults: defaults).flushPending(context: context)
        await FeltStateLogUploader(client: client, userID: upper.lowercased(), defaults: defaults).flushPending(context: context)
        XCTAssertEqual(client.payloads.count, 2, "the server treats device IDs as case-sensitive text")
    }

    private final class RejectOneClient: FeltStateAPIClient, @unchecked Sendable {
        let baseURL = URL(string: "https://checkins.invalid")!
        var rejectedID: String = ""
        var accepted: [String] = []
        func uploadFeltStateLog(_ payload: FeltStateUploadPayload, userID: String) async throws {
            if payload.id == rejectedID { throw FeltStateUploadError.httpStatus(422) }
            accepted.append(payload.id)
        }
    }

    @MainActor
    func testOneRejectedAnswerDoesNotBlockLaterValidAnswersOrBecomeAcknowledged() async {
        let context = makeContext()
        let rejected = log(at: Date(timeIntervalSince1970: 100)), valid = log(at: .now)
        context.insert(rejected); context.insert(valid)
        let client = RejectOneClient()
        client.rejectedID = rejected.id.uuidString
        let uploader = FeltStateLogUploader(client: client, userID: "u", defaults: defaults)
        await uploader.flushPending(context: context)
        XCTAssertEqual(client.accepted, [valid.id.uuidString])
        XCTAssertNil(rejected.uploadedDestination)
        XCTAssertNotNil(valid.uploadedDestination)
        XCTAssertNotNil(uploader.lastError)
        client.rejectedID = ""
        await uploader.flushPending(context: context)
        XCTAssertEqual(client.accepted, [valid.id.uuidString, rejected.id.uuidString])
        XCTAssertNil(uploader.lastError)
    }

    @MainActor
    private final class PausedClient: FeltStateAPIClient {
        let baseURL = URL(string: "https://checkins.invalid")!
        var ids: [String] = []
        var continuation: CheckedContinuation<Void, Never>?
        func uploadFeltStateLog(_ payload: FeltStateUploadPayload, userID: String) async throws {
            ids.append(payload.id)
            if ids.count == 1 { await withCheckedContinuation { continuation = $0 } }
        }
    }

    @MainActor
    func testConcurrentTriggerPicksUpNewAnswerWithoutDuplicateRequests() async {
        let context = makeContext()
        let first = log(at: Date(timeIntervalSince1970: 100)), second = log(at: .now)
        context.insert(first)
        let client = PausedClient()
        let uploader = FeltStateLogUploader(client: client, userID: "u", defaults: defaults)
        let task = Task { await uploader.flushPending(context: context) }
        for _ in 0..<100 where client.continuation == nil { await Task.yield() }
        guard let continuation = client.continuation else { XCTFail("first request never started"); task.cancel(); return }
        context.insert(second)
        await uploader.flushPending(context: context)
        XCTAssertEqual(client.ids, [first.id.uuidString])
        continuation.resume()
        await task.value
        XCTAssertEqual(client.ids, [first.id.uuidString, second.id.uuidString])
    }

    @MainActor
    func testTurningSyncOffDuringRequestStopsTheNextAnswer() async {
        let context = makeContext()
        context.insert(log(at: Date(timeIntervalSince1970: 100)))
        context.insert(log(at: .now))
        let client = PausedClient()
        let uploader = FeltStateLogUploader(client: client, userID: "u", defaults: defaults)
        let task = Task { await uploader.flushPending(context: context) }
        for _ in 0..<100 where client.continuation == nil { await Task.yield() }
        guard let continuation = client.continuation else { XCTFail("first request never started"); task.cancel(); return }
        defaults.set(false, forKey: "cloudSyncEnabled")
        continuation.resume()
        await task.value
        XCTAssertEqual(client.ids.count, 1)
        defaults.set(true, forKey: "cloudSyncEnabled")
        await uploader.flushPending(context: context)
        XCTAssertEqual(client.ids.count, 2)
    }

    func testHTTPResponseMustContainAValidReceiptBeforeAcknowledging() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeltStateReceiptURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let payload = FeltStateUploadPayload(from: log(at: .now))
        for scenario in ["empty", "html", "missing-id", "zero-id", "wrong-type", "server-error", "conflict"] {
            let client = APIClient(baseURL: URL(string: "https://\(scenario).checkin-test.invalid")!, session: session)
            do {
                try await client.uploadFeltStateLog(payload, userID: "u")
                XCTFail("\(scenario) must remain pending")
            } catch { /* no server acknowledgement */ }
        }
        let client = APIClient(baseURL: URL(string: "https://valid.checkin-test.invalid")!, session: session)
        try await client.uploadFeltStateLog(payload, userID: "u")
    }

    /// The wire shape the server was built against: snake_case keys, `kind`
    /// always present, and an untouched scale absent-or-null — never 50.
    func testPayloadEncodesTheServersKeysAndKeepsUntouchedNull() throws {
        let log = FeltStateLog(timestamp: Date(timeIntervalSince1970: 0), kind: "previous_day",
                               focus: 60, energy: nil, stress: 30, mood: nil, anxiety: 10, sleep: 35,
                               dayKey: "2026-09-13", timezone: "Europe/Lisbon", wornMinutes: nil,
                               stateKey: nil)
        let data = try JSONEncoder().encode(FeltStateUploadPayload(from: log))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["kind"] as? String, "previous_day")
        XCTAssertEqual(json["day_key"] as? String, "2026-09-13")
        XCTAssertEqual(json["timezone"] as? String, "Europe/Lisbon")
        XCTAssertEqual(json["sleep"] as? Double, 35)
        XCTAssertEqual(json["anxiety"] as? Double, 10)
        XCTAssertEqual(json["id"] as? String, log.id.uuidString)
        XCTAssertTrue(json["energy"] == nil || json["energy"] is NSNull, "untouched must not become a number")
        XCTAssertTrue(json["worn_minutes"] == nil || json["worn_minutes"] is NSNull)
        XCTAssertNil(json["dayKey"], "camelCase must not leak onto the wire")
    }

    /// A row from the August build has no kind; it is a moment.
    func testARowWithoutAKindUploadsAsAMoment() throws {
        let log = FeltStateLog(timestamp: .now, kind: nil, focus: 1, energy: nil, stress: nil, mood: nil,
                               anxiety: nil, sleep: nil, dayKey: nil, timezone: nil, wornMinutes: nil,
                               stateKey: nil)
        let data = try JSONEncoder().encode(FeltStateUploadPayload(from: log))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["kind"] as? String, "moment")
    }
}

private final class FeltStateReceiptURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".checkin-test.invalid") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let scenario = request.url!.host!.components(separatedBy: ".")[0]
        let code = scenario == "server-error" ? 503 : scenario == "conflict" ? 409 : 200
        let bodies = ["empty": "", "html": "<html>OK</html>", "missing-id": "{}",
                      "zero-id": "{\"id\":\"0\"}", "wrong-type": "{\"id\":123}"]
        let body = bodies[scenario] ?? "{\"id\":\"123\"}"
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
