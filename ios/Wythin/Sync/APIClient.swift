import Foundation
import SwiftData
import SwiftUI

// MARK: - Wire types (Codable)

struct SessionPayload: Codable {
    let id:           String
    let startedAt:    String   // ISO8601
    let endedAt:      String?
    let avgRSAms:     Float?
    let avgCoherence: Float?
    let notes:        String?
    let samples:      [SamplePayload]
}

struct SamplePayload: Codable {
    let ts:         String   // ISO8601
    let meanBPM:    Float?
    let rmssd:      Float?
    let sdnn:       Float?
    let pnn50:      Float?
    let lfHF:       Float?
    let rsaMs:      Float?
    let rsaIdx:     Float?
    let coherence:  Float?
    let cbi:        Float?
    let breathBPM:  Float?
}

struct TickPayload: Codable {
    let userId:   String
    let ts:       String
    let meanBPM:  Float?
    let rmssd:    Float?
    let rsaMs:    Float?
    let coherence: Float?
    let cbi:      Float?
    let breathBPM: Float?
}

struct InsightPayload: Codable {
    let activityType:    String
    let activitySubtype: String?
    let durationMin:     Int?
    let beforeHR: Float?;    let duringHR: Float?;    let afterHR: Float?
    let beforeRSA: Float?;   let duringRSA: Float?;   let afterRSA: Float?
    let beforeSDNN: Float?;  let duringSDNN: Float?;  let afterSDNN: Float?
    let beforeLFHF: Float?;  let duringLFHF: Float?;  let afterLFHF: Float?

    enum CodingKeys: String, CodingKey {
        case activityType    = "activity_type"
        case activitySubtype = "activity_subtype"
        case durationMin     = "duration_min"
        case beforeHR = "before_hr"; case duringHR = "during_hr"; case afterHR = "after_hr"
        case beforeRSA = "before_rsa"; case duringRSA = "during_rsa"; case afterRSA = "after_rsa"
        case beforeSDNN = "before_sdnn"; case duringSDNN = "during_sdnn"; case afterSDNN = "after_sdnn"
        case beforeLFHF = "before_lf_hf"; case duringLFHF = "during_lf_hf"; case afterLFHF = "after_lf_hf"
    }
}

struct MetricTrendPayload: Codable {
    let now:        Float?
    let min:        Float?
    let max:        Float?
    let buckets:    [Float]?
    let slopePct:   Float?
    let volatility: String?
    let shape:      String?

    // NOTE: no day_mean. The live read must never compare to an average —
    // that is Day Potential's job, and withholding the field is the only
    // enforcement that doesn't leak through prompt wording.
    enum CodingKeys: String, CodingKey {
        case now, min, max, buckets, volatility, shape
        case slopePct = "slope_pct"
    }
}

struct MetricComponentPayload: Codable {
    let z: Float?
    let level: String?
}

/// Day-potential request. Carries the locally-computed score and every part
/// that produced it, so the model can explain the number without inventing
/// one.
struct DayPotentialPayload: Codable {
    let mode = "day_potential"
    let score: Int?
    let band: String?
    let anchorHour: Double
    let anchorDurationMin: Int
    let late: Bool
    let confidence: String
    let components: [String: MetricComponentPayload]
    let modifiers: [String: Float]
    let baselineAnchors: Int
    let baselineTarget: Int
    let baselineSufficient: Bool
    /// A score exists but the range is still forming. Distinct from
    /// `!baselineSufficient`, which also covers the first morning — no
    /// reference day, so no score.
    let provisional: Bool
    let recent: [Int]
    let streakCurrent: Int
    let streakBest: Int
    let graceUsed: Bool

    enum CodingKeys: String, CodingKey {
        case mode, score, band, components, modifiers, recent, late, confidence, provisional
        case anchorHour = "anchor_hour"
        case anchorDurationMin = "anchor_duration_min"
        case baselineAnchors = "baseline_anchors"
        case baselineTarget = "baseline_target"
        case baselineSufficient = "baseline_sufficient"
        case streakCurrent = "streak_current"
        case streakBest = "streak_best"
        case graceUsed = "grace_used"
    }
}

struct LiveStateInsightPayload: Codable {
    let mode: String            // always "live_state"
    let windowMinutes: Int
    let metrics: [String: MetricTrendPayload]

    enum CodingKeys: String, CodingKey {
        case mode
        case windowMinutes = "window_minutes"
        case metrics
    }
}

/// One metric's period summary for the macro read. Only aggregate daily means
/// leave the device — never raw samples.
struct MacroTrendEntry: Codable, Equatable {
    let avg:       Double
    let baseline:  Double?
    /// Whether `baseline` is this person's own 90-day median, versus a fixed
    /// physiological norm used when they don't yet have enough history. The
    /// server needs this to avoid claiming personal history it doesn't have.
    let baselineIsPersonal: Bool?
    /// Benefit-signed: positive always means improvement.
    let deltaPct:  Double?
    let daysAbove: Int?
    let daysTotal: Int?
    let direction: String?

    enum CodingKeys: String, CodingKey {
        case avg, baseline, direction
        case baselineIsPersonal = "baseline_is_personal"
        case deltaPct  = "delta_pct"
        case daysAbove = "days_above"
        case daysTotal = "days_total"
    }
}

struct MacroTrendPayload: Codable {
    let mode:       String
    let period:     String
    let rangeLabel: String
    let trends:     [String: MacroTrendEntry]

    enum CodingKeys: String, CodingKey {
        case mode, period, trends
        case rangeLabel = "range_label"
    }

    /// Metrics with no data for the period are omitted rather than sent as
    /// nulls — the model must never be asked to narrate an absent metric.
    init(period: TrackPeriod, rangeLabel: String,
         series: [(spec: TrackMetricSpec, series: TrackSeries)]) {
        self.mode       = "macro_trend"
        self.period     = period.apiValue
        self.rangeLabel = rangeLabel
        self.trends = Dictionary(uniqueKeysWithValues: series.compactMap { pair in
            guard let avg = pair.series.average else { return nil }
            return (pair.spec.trendKey, MacroTrendEntry(
                avg:       avg,
                baseline:  pair.series.reference,
                baselineIsPersonal: pair.series.referenceIsPersonal,
                deltaPct:  pair.series.deltaPct,
                daysAbove: pair.series.betterCount,
                daysTotal: pair.series.presentCount,
                direction: pair.spec.def.direction.apiValue))
        })
    }
}

extension BenefitDirection {
    /// Wire value for the macro-read payload.
    var apiValue: String {
        switch self {
        case .higher: return "higher"
        case .lower:  return "lower"
        case .target: return "target"
        }
    }
}

struct InsightResponse: Codable {
    let text: String
}

struct TokenCreated: Codable, Identifiable {
    let token: String
    let id: String
    let name: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case token, id, name
        case createdAt = "created_at"
    }
}

struct TokenInfo: Codable, Identifiable {
    let id: String
    let name: String?
    let createdAt: String
    let lastUsedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
    }
}

/// Builds the exact `claude mcp add` command for a freshly minted token.
enum MCPSetup {
    static func claudeCommand(serverURL: URL, token: String) -> String {
        var base = serverURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        return "claude mcp add --transport http wythin \(base)/mcp "
             + "--header \"Authorization: Bearer \(token)\""
    }
}

struct MetricSamplePayload: Codable {
    let ts: String
    let mean_bpm, rmssd, sdnn, pnn50, lf_hf, rsa_ms: Float?
    let coherence, cbi, breath_bpm, dfa1, rcmse, pip, dc, vti: Float?
}
struct MetricsUploadPayload: Codable { let samples: [MetricSamplePayload] }

// Read-back of the same fourteen columns `/v1/metrics` stores, for restoring
// a wiped local store from the cloud copy.
struct MetricExportSample: Codable {
    let ts: String
    let mean_bpm, rmssd, sdnn, pnn50, lf_hf, rsa_ms: Float?
    let coherence, cbi, breath_bpm, dfa1, rcmse, pip, dc, vti: Float?
}

struct MetricExportPage: Codable {
    let samples: [MetricExportSample]
    let next_cursor: String?
}
struct MetricsUploadResponse: Codable { let stored: Int }

/// Onboarding profile sent to the server (keys match the server's ProfileUpload).
struct ProfilePayload: Codable {
    let first_name: String
    let last_name:  String
    let phone:      String
    let email:      String
    let age_range:  String?
    let gender:     String?
    let height_cm:  Int?
    let weight_kg:  Int?
    let goals:      [String]
    let practices:  [String]
    let devices:    [String]
    /// Self-reported baseline, 0…10 each, nil where the slider was untouched.
    let state_focus:         Int?
    let state_anxiety:       Int?
    let state_energy:        Int?
    let state_sleep_quality: Int?
    let state_stress:        Int?
    /// Data-sharing consents. These travel with the profile so the server can
    /// refuse to process what the user hasn't agreed to — a consent the backend
    /// can't read is not a control, it's a label.
    let consent_share_team:  Bool
    let consent_ai_insights: Bool
}

struct ServerSession: Codable {
    let id:           String
    let startedAt:    String
    let endedAt:      String?
    let avgRSAms:     Float?
    let avgCoherence: Float?
}

struct UploadResponse: Codable {
    let id: String
}

// MARK: - APIClient

struct APIClient {
    let baseURL: URL
    private let session = URLSession.shared
    private let iso = ISO8601DateFormatter()

    // MARK: Sessions

    func uploadSession(_ payload: SessionPayload, userID: String) async throws -> UploadResponse {
        var req = request(path: "/sessions", method: "POST")
        req.addValue(userID, forHTTPHeaderField: "X-User-ID")
        req.httpBody = try JSONEncoder().encode(payload)
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(UploadResponse.self, from: data)
    }

    // MARK: Activities

    func uploadActivity(_ payload: ActivityUploadPayload, userID: String) async throws -> UploadResponse {
        var req = request(path: "/activities", method: "POST")
        req.addValue(userID, forHTTPHeaderField: "X-User-ID")
        req.httpBody = try JSONEncoder().encode(payload)
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(UploadResponse.self, from: data)
    }

    /// Every activity the server holds for this user, newest first.
    ///
    /// The counterpart to the upload, and the reason it was added: upload was
    /// the only direction that existed, so a phone whose local store was gone
    /// had no way to get its own history back.
    func fetchActivities(userID: String) async throws -> [ActivityUploadPayload] {
        var req = request(path: "/activities", method: "GET")
        req.addValue(userID, forHTTPHeaderField: "X-User-ID")
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode([ActivityUploadPayload].self, from: data)
    }

    // MARK: Felt-state check-ins

    func uploadFeltStateLog(_ payload: FeltStateUploadPayload, userID: String) async throws {
        var req = request(path: "/felt-state-logs", method: "POST")
        req.addValue(userID, forHTTPHeaderField: "X-User-ID")
        req.httpBody = try JSONEncoder().encode(payload)
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func fetchSessions(userID: String) async throws -> [ServerSession] {
        var req = request(path: "/sessions", method: "GET")
        req.addValue(userID, forHTTPHeaderField: "X-User-ID")
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode([ServerSession].self, from: data)
    }

    // MARK: Access tokens

    func createToken(name: String, userID: String) async throws -> TokenCreated {
        var req = request(path: "/v1/tokens", method: "POST")
        req.addValue(userID, forHTTPHeaderField: "X-User-ID")
        req.httpBody = try JSONEncoder().encode(["name": name])
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(TokenCreated.self, from: data)
    }

    func listTokens(userID: String) async throws -> [TokenInfo] {
        var req = request(path: "/v1/tokens", method: "GET")
        req.addValue(userID, forHTTPHeaderField: "X-User-ID")
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode([TokenInfo].self, from: data)
    }

    func revokeToken(id: String, userID: String) async throws {
        var req = request(path: "/v1/tokens/\(id)", method: "DELETE")
        req.addValue(userID, forHTTPHeaderField: "X-User-ID")
        _ = try await session.data(for: req)
    }

    // MARK: Continuous metric sync

    func uploadMetrics(_ payload: MetricsUploadPayload, userID: String) async throws -> MetricsUploadResponse {
        var req = request(path: "/v1/metrics", method: "POST")
        req.addValue(userID, forHTTPHeaderField: "X-User-ID")
        req.httpBody = try JSONEncoder().encode(payload)
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(MetricsUploadResponse.self, from: data)
    }

    func uploadUsage(_ payload: UsageUploadPayload, userID: String) async throws {
        var req = request(path: "/v1/usage", method: "POST")
        req.addValue(userID, forHTTPHeaderField: "X-User-ID")
        req.httpBody = try JSONEncoder().encode(payload)
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func deleteMyData(token: String) async throws {
        var req = request(path: "/v1/me/data", method: "DELETE")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await session.data(for: req)
    }

    func uploadProfile(_ payload: ProfilePayload, userID: String) async throws {
        var req = request(path: "/v1/profile", method: "POST")
        req.addValue(userID, forHTTPHeaderField: "X-User-ID")
        req.httpBody = try JSONEncoder().encode(payload)
        // Check the status: URLSession does not throw on 4xx/5xx, so without
        // this a rejected upload looks like success and MetricsSyncer marks the
        // profile synced for the launch — which is how every profile uploaded
        // before /v1/profile was deployed got silently dropped.
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    // MARK: Insights

    func generateInsight(_ payload: InsightPayload) async throws -> InsightResponse {
        var req = request(path: "/insights", method: "POST")
        req.addValue(DeviceIdentity.current, forHTTPHeaderField: "X-User-ID")
        req.httpBody = try JSONEncoder().encode(payload)
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(InsightResponse.self, from: data)
    }

    func generateDayPotentialInsight(_ payload: DayPotentialPayload) async throws -> InsightResponse {
        var req = request(path: "/insights", method: "POST")
        req.addValue(DeviceIdentity.current, forHTTPHeaderField: "X-User-ID")
        req.httpBody = try JSONEncoder().encode(payload)
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(InsightResponse.self, from: data)
    }

    func generateLiveStateInsight(_ payload: LiveStateInsightPayload) async throws -> InsightResponse {
        var req = request(path: "/insights", method: "POST")
        req.addValue(DeviceIdentity.current, forHTTPHeaderField: "X-User-ID")
        req.httpBody = try JSONEncoder().encode(payload)
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(InsightResponse.self, from: data)
    }

    func generateMacroTrendInsight(_ payload: MacroTrendPayload) async throws -> InsightResponse {
        var req = request(path: "/insights", method: "POST")
        req.addValue(DeviceIdentity.current, forHTTPHeaderField: "X-User-ID")
        req.httpBody = try JSONEncoder().encode(payload)
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(InsightResponse.self, from: data)
    }

    // MARK: Helpers

    // MARK: Cloud restore

    /// One page of this user's own samples, oldest first. `cursor` is the
    /// previous page's `next_cursor`, an ISO timestamp whose "+00:00" offset
    /// must be percent-encoded by hand — URLQueryItem leaves "+" bare, and
    /// the server would read it back as a space.
    func exportMetrics(cursor: String?, userID: String) async throws -> MetricExportPage {
        var comps = URLComponents(url: baseURL.appendingPathComponent("/v1/metrics/export"),
                                  resolvingAgainstBaseURL: false)!
        var query = "limit=5000"
        if let cursor,
           let enc = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            query += "&cursor=\(enc)"
        }
        comps.percentEncodedQuery = query
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue(APIConfig.apiKey, forHTTPHeaderField: "X-API-Key")
        req.addValue(userID, forHTTPHeaderField: "X-User-ID")
        req.timeoutInterval = 60
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(MetricExportPage.self, from: data)
    }

    /// Every activity this user has uploaded. Same payload shape as the
    /// upload direction, so restore round-trips through one struct.
    func fetchActivities(userID: String) async throws -> [ActivityUploadPayload] {
        var req = request(path: "/activities", method: "GET")
        req.addValue(userID, forHTTPHeaderField: "X-User-ID")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([ActivityUploadPayload].self, from: data)
    }

    private func request(path: String, method: String) -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.httpMethod = method
        r.addValue("application/json", forHTTPHeaderField: "Content-Type")
        r.addValue(APIConfig.apiKey, forHTTPHeaderField: "X-API-Key")
        r.timeoutInterval = 15
        return r
    }
}

// MARK: - MetricSyncService
//
// Opt-in, incremental uploader for continuous HRV metrics. Reads a batch of
// `HRVSample` rows newer than the last-synced watermark, uploads them, and
// only advances the watermark on success — so a failed upload is retried
// (not skipped) on the next call. No-ops entirely while the user has the
// cloud-sync toggle off.

@MainActor
final class MetricSyncService {
    private let client: APIClient
    private let userID: String
    private let container: ModelContainer
    @AppStorage("cloudSyncEnabled") private var enabled = true
    @AppStorage("metricsLastSyncedAt") private var lastSyncedISO = ""
    /// The profile the server last *accepted*, as canonical JSON. Persisted, so
    /// a rejected upload is retried on the next sync rather than waiting for a
    /// relaunch, and an edited profile re-uploads on its own.
    @AppStorage("profileLastSynced") private var syncedProfile = ""
    private let iso = ISO8601DateFormatter()
    private let batch = 2000
    private var isSyncing = false

    /// Sorted keys so the same answers always encode to the same bytes — the
    /// comparison above is only meaningful if the encoding is stable.
    private static let profileEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    init(client: APIClient, userID: String, container: ModelContainer) {
        self.client = client; self.userID = userID; self.container = container
    }

    func syncIfEnabled() async {
        guard enabled else { return }
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        // Push the onboarding profile whenever what we hold differs from what the
        // server last accepted — every sync, not once per launch. Marking it
        // synced only after a real success means a rejected upload retries on
        // the next tick (~120 s) instead of needing the app relaunched, which is
        // how five days of profiles were lost to a 404 nobody noticed.
        // Gated by the cloud-sync toggle above (it carries PII).
        let p = ClientProfileStore().load()
        let profile = ProfilePayload(
            first_name: p.firstName, last_name: p.lastName,
            phone: p.phone, email: p.email, age_range: p.ageRange, gender: p.gender,
            height_cm: p.heightCm, weight_kg: p.weightKg,
            goals: p.goals, practices: p.practices, devices: p.devices,
            state_focus: p.state.focus, state_anxiety: p.state.anxiety,
            state_energy: p.state.energy, state_sleep_quality: p.state.sleepQuality,
            state_stress: p.state.stress,
            consent_share_team: OnboardingConsent.shareWithTeam(),
            consent_ai_insights: OnboardingConsent.aiInsights())
        if let encoded = try? Self.profileEncoder.encode(profile) {
            let canonical = String(decoding: encoded, as: UTF8.self)
            if canonical != syncedProfile,
               (try? await client.uploadProfile(profile, userID: userID)) != nil {
                syncedProfile = canonical
            }
        }

        let after = iso.date(from: lastSyncedISO) ?? Date.distantPast
        let ctx = ModelContext(container)
        var desc = FetchDescriptor<HRVSample>(
            predicate: #Predicate { $0.timestamp > after },
            sortBy: [SortDescriptor(\.timestamp)])
        desc.fetchLimit = batch
        guard let samples = try? ctx.fetch(desc), !samples.isEmpty else { return }
        let payload = MetricsUploadPayload(samples: samples.map { s in
            MetricSamplePayload(ts: iso.string(from: s.timestamp),
                mean_bpm: s.meanBPM, rmssd: s.rmssd, sdnn: s.sdnn, pnn50: s.pnn50,
                lf_hf: s.lfHF, rsa_ms: s.rsaMs, coherence: s.coherence, cbi: s.cbi,
                breath_bpm: s.breathBPM, dfa1: s.dfa1, rcmse: s.rcmse, pip: s.pip,
                dc: s.dc, vti: s.vti) })
        if (try? await client.uploadMetrics(payload, userID: userID)) != nil,
           let last = samples.last {
            lastSyncedISO = iso.string(from: last.timestamp)
        }
    }
}

// MARK: - API configuration

/// Shared secret the server requires as `X-API-Key`. A first-layer gate so the
/// API isn't open to anyone who learns the URL. Compiled into the app (a
/// determined attacker could extract it) — acceptable for this layer; per-user
/// auth would replace it for a larger user base.
enum APIConfig {
    static let apiKey = "fdc505a043b42cfa5d1353563fcf5412c0dee0bf2cc11301d82f6423da09bdbd"
}

// MARK: - DeviceIdentity

/// The anonymous per-install id sent as `X-User-ID`.
///
/// Every other endpoint receives this as a parameter from the caller. The
/// insight calls can't: they run behind `InsightAPIClient`, whose signatures are
/// shared with test fakes, and threading an id through four call sites to reach
/// a value that is a process-wide constant would be churn for nothing. So they
/// read it here — the same key `AppEnvironment` uses, stated once so the two
/// can't drift onto different ids and split one user in two.
enum DeviceIdentity {
    static let defaultsKey = "userID"

    static var current: String {
        if let id = UserDefaults.standard.string(forKey: defaultsKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: defaultsKey)
        return id
    }
}

// MARK: - InsightAPIClient

/// Narrow protocol over `APIClient.generateInsight` and `APIClient.generateLiveStateInsight` so
/// `InsightGenerator` can be tested with a fake instead of a real network call.
protocol InsightAPIClient {
    func generateInsight(_ payload: InsightPayload) async throws -> InsightResponse
    func generateLiveStateInsight(_ payload: LiveStateInsightPayload) async throws -> InsightResponse
}

extension APIClient: InsightAPIClient {}

/// Narrow protocol over `APIClient.uploadUsage` so `UsageUploader` can be
/// tested with a fake instead of a real network call.
protocol UsageAPIClient {
    func uploadUsage(_ payload: UsageUploadPayload, userID: String) async throws
}

extension APIClient: UsageAPIClient {}

// MARK: - Payload builders

extension SessionPayload {
    init(from session: HRVSession) {
        let iso = ISO8601DateFormatter()
        self.id          = session.id.uuidString
        self.startedAt   = iso.string(from: session.startedAt)
        self.endedAt     = session.endedAt.map { iso.string(from: $0) }
        self.avgRSAms    = session.avgRSAms
        self.avgCoherence = session.avgCoherence
        self.notes       = session.notes
        self.samples     = session.samples.map { SamplePayload(from: $0) }
    }
}

extension SamplePayload {
    init(from s: HRVSample) {
        let iso = ISO8601DateFormatter()
        self.ts        = iso.string(from: s.timestamp)
        self.meanBPM   = s.meanBPM
        self.rmssd     = s.rmssd
        self.sdnn      = s.sdnn
        self.pnn50     = s.pnn50
        self.lfHF      = s.lfHF
        self.rsaMs     = s.rsaMs
        self.rsaIdx    = s.rsaIdx
        self.coherence = s.coherence
        self.cbi       = s.cbi
        self.breathBPM = s.breathBPM
    }
}

extension TickPayload {
    init(from tick: MetricsTick, userID: String) {
        let iso = ISO8601DateFormatter()
        self.userId    = userID
        self.ts        = iso.string(from: tick.timestamp)
        self.meanBPM   = tick.meanBPM
        self.rmssd     = tick.rmssd
        self.rsaMs     = tick.rsaMs
        self.coherence = tick.coherenceScore
        self.cbi       = tick.cbi
        self.breathBPM = tick.breathBPM
    }
}

extension InsightPayload {
    init(from entry: ActivityLog) {
        self.activityType    = entry.activityType
        self.activitySubtype = entry.activitySubtype
        self.durationMin     = entry.duration.map { Int($0 / 60) }
        self.beforeHR   = entry.beforeHR;   self.duringHR   = entry.duringHR;   self.afterHR   = entry.afterHR
        self.beforeRSA  = entry.beforeRSA;  self.duringRSA  = entry.duringRSA;  self.afterRSA  = entry.afterRSA
        self.beforeSDNN = entry.beforeSDNN; self.duringSDNN = entry.duringSDNN; self.afterSDNN = entry.afterSDNN
        self.beforeLFHF = entry.beforeLFHF; self.duringLFHF = entry.duringLFHF; self.afterLFHF = entry.afterLFHF
    }
}

extension MetricTrendPayload {
    init(from trend: MetricTrend) {
        self.now        = trend.end
        self.min        = trend.min
        self.max        = trend.max
        self.buckets    = trend.buckets
        self.slopePct   = trend.slopePct
        self.volatility = trend.volatility
        self.shape      = trend.shape
    }
}

extension LiveStateInsightPayload {
    init(windowMinutes: Int, trends: [String: MetricTrend]) {
        self.mode = "live_state"
        self.windowMinutes = windowMinutes
        self.metrics = trends.mapValues { MetricTrendPayload(from: $0) }
    }
}

// MARK: - Usage telemetry payloads

struct UsageEventPayload: Codable {
    let clientEventId: String
    let eventType:     String
    let ts:            String
    let durationMs:    Int

    enum CodingKeys: String, CodingKey {
        case clientEventId = "client_event_id"
        case eventType     = "event_type"
        case ts
        case durationMs    = "duration_ms"
    }
}

struct UsageUploadPayload: Codable {
    let events: [UsageEventPayload]
}
