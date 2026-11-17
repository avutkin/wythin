import Foundation
import SwiftData
import SwiftUI
import CryptoKit
import UIKit

// MARK: - Wire types (Codable)

struct SessionPayload: Codable {
    let id:           String
    let startedAt:    String   // ISO8601
    let endedAt:      String?
    let avgRSAms:     Float?
    let avgCoherence: Float?
    let notes:        String?
    let samples:      [SamplePayload]

    enum CodingKeys: String, CodingKey {
        case id, notes, samples
        case startedAt = "started_at", endedAt = "ended_at"
        case avgRSAms = "avg_rsa_ms", avgCoherence = "avg_coherence"
    }
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
    var stressBalance: Float? = nil

    enum CodingKeys: String, CodingKey {
        case ts, rmssd, sdnn, pnn50, coherence, cbi
        case meanBPM = "mean_bpm", lfHF = "lf_hf", rsaMs = "rsa_ms", rsaIdx = "rsa_idx"
        case breathBPM = "breath_bpm", stressBalance = "stress_balance"
    }
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
    // The rest of what the session detail charts. The read is printed under
    // those charts, so it is written from the same numbers rather than from a
    // four-metric subset of them. The raw LF/HF ratio is deliberately not sent
    // at all: it climbs during slow paced breathing, and a coach handed it
    // calls the calmest thing you can do sympathetic activation.
    let beforeRMSSD: Float?; let duringRMSSD: Float?; let afterRMSSD: Float?
    let beforeDC: Float?;    let duringDC: Float?;    let afterDC: Float?
    let beforeRCMSE: Float?; let duringRCMSE: Float?; let afterRCMSE: Float?
    let beforePIP: Float?;   let duringPIP: Float?;   let afterPIP: Float?
    let beforeDFA1: Float?;  let duringDFA1: Float?;  let afterDFA1: Float?
    let beforeStress: Float?; let duringStress: Float?; let afterStress: Float?
    let beforeBreath: Float?; let duringBreath: Float?; let afterBreath: Float?

    /// What this session is being compared against, and how many sessions are
    /// behind that comparison.
    ///
    /// Without these the read could only narrate the chart the person is
    /// already looking at — "your Pulse decreased" under a line visibly going
    /// down. The screen itself shows "vs 2mo −4%"; the coach was the only part
    /// of it that could not see that number, so it had nothing to say that the
    /// charts had not already said.
    let peerGroup: String?
    let peerSessions: Int?
    /// The person's own recent average DURING value per metric, same peer
    /// group. Absent when they have no history to compare against yet.
    let usualHR: Float?; let usualRSA: Float?; let usualSDNN: Float?
    let usualRMSSD: Float?; let usualDC: Float?; let usualRCMSE: Float?
    let usualPIP: Float?; let usualDFA1: Float?; let usualStress: Float?
    let usualBreath: Float?

    enum CodingKeys: String, CodingKey {
        case peerGroup = "peer_group"; case peerSessions = "peer_sessions"
        case usualHR = "usual_hr"; case usualRSA = "usual_rsa"; case usualSDNN = "usual_sdnn"
        case usualRMSSD = "usual_rmssd"; case usualDC = "usual_dc"; case usualRCMSE = "usual_rcmse"
        case usualPIP = "usual_pip"; case usualDFA1 = "usual_dfa1"; case usualStress = "usual_stress"
        case usualBreath = "usual_breath"
        case activityType    = "activity_type"
        case activitySubtype = "activity_subtype"
        case durationMin     = "duration_min"
        case beforeHR = "before_hr"; case duringHR = "during_hr"; case afterHR = "after_hr"
        case beforeRSA = "before_rsa"; case duringRSA = "during_rsa"; case afterRSA = "after_rsa"
        case beforeSDNN = "before_sdnn"; case duringSDNN = "during_sdnn"; case afterSDNN = "after_sdnn"
        case beforeRMSSD = "before_rmssd"; case duringRMSSD = "during_rmssd"; case afterRMSSD = "after_rmssd"
        case beforeDC = "before_dc"; case duringDC = "during_dc"; case afterDC = "after_dc"
        case beforeRCMSE = "before_rcmse"; case duringRCMSE = "during_rcmse"; case afterRCMSE = "after_rcmse"
        case beforePIP = "before_pip"; case duringPIP = "during_pip"; case afterPIP = "after_pip"
        case beforeDFA1 = "before_dfa1"; case duringDFA1 = "during_dfa1"; case afterDFA1 = "after_dfa1"
        case beforeStress = "before_stress"; case duringStress = "during_stress"; case afterStress = "after_stress"
        case beforeBreath = "before_breath"; case duringBreath = "during_breath"; case afterBreath = "after_breath"
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
    /// Stillness, in mg. Sent because the sleep pipeline's every gate is
    /// relative to it and it was the one channel that never left the device —
    /// so a night that scored wrong could only be examined with the phone in
    /// hand, and the tools in tools/ could not reproduce what the device did.
    let motion: Float?
    /// How trustworthy this tick is, read on-device: 1 − the fraction of RR
    /// intervals dropped as implausible, that fraction itself, and the ECG
    /// artifact tier (0 poor … 2 good). Sent for the same reason motion is —
    /// a night that read 160 bpm with RMSSD 150 ms for ten hours (2026-10-24)
    /// looked, on its stored numbers alone, like an outlier night rather than
    /// what it was: bad strap contact for most of it.
    let signal_quality: Float?
    let rr_invalid_rate: Float?
    let ecg_quality_tier: Int?
    var timezone: String? = nil
    var stress_balance: Float? = nil
}
extension MetricSamplePayload {
    var hasStoredValue: Bool {
        [mean_bpm, rmssd, sdnn, pnn50, lf_hf, rsa_ms, coherence, cbi,
         breath_bpm, dfa1, rcmse, pip, dc, vti, motion, signal_quality,
         rr_invalid_rate, stress_balance].contains { $0 != nil } || ecg_quality_tier != nil
    }
}
struct MetricsUploadPayload: Codable { let samples: [MetricSamplePayload] }

// Read-back of the scalar columns `/v1/metrics` stores, for restoring
// a wiped local store from the cloud copy.
struct MetricExportSample: Codable {
    let ts: String
    let mean_bpm, rmssd, sdnn, pnn50, lf_hf, rsa_ms: Float?
    let coherence, cbi, breath_bpm, dfa1, rcmse, pip, dc, vti: Float?
    /// Optional so a page written before motion was carried still decodes.
    let motion: Float?
    /// Optional for the same reason: a page written before quality was
    /// carried still decodes, with these nil.
    let signal_quality: Float?
    let rr_invalid_rate: Float?
    let ecg_quality_tier: Int?
    var timezone: String? = nil
    var stress_balance: Float? = nil
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
    /// The phone's IANA time zone, so the dashboard shows this person's day in
    /// their own clock. Travels with the profile because the profile is the one
    /// thing re-sent whenever it changes — a new zone is a changed profile.
    let timezone:            String
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
    private let session: URLSession
    private let iso = ISO8601DateFormatter()

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

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

    // MARK: Felt-state check-ins

    func uploadFeltStateLog(_ payload: FeltStateUploadPayload, userID: String) async throws {
        var req = request(path: "/felt-state-logs", method: "POST")
        req.addValue(userID, forHTTPHeaderField: "X-User-ID")
        req.httpBody = try JSONEncoder().encode(payload)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw FeltStateUploadError.invalidReceipt }
        guard (200..<300).contains(http.statusCode) else {
            throw FeltStateUploadError.httpStatus(http.statusCode)
        }
        guard let receipt = try? JSONDecoder().decode(UploadResponse.self, from: data),
              let id = Int64(receipt.id), id > 0 else {
            throw FeltStateUploadError.invalidReceipt
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

    func rawChunkRequest(_ file: URL, userID: String) throws -> URLRequest {
        let bytes = try Data(contentsOf: file)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let id = file.deletingPathExtension().lastPathComponent
        var req = request(path: "/v1/raw/chunks/\(id)", method: "POST")
        req.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        req.setValue(userID, forHTTPHeaderField: "X-User-ID")
        req.setValue(digest, forHTTPHeaderField: "X-Chunk-SHA256")
        req.timeoutInterval = 120
        return req
    }

    func uploadMetrics(_ payload: MetricsUploadPayload, userID: String) async throws -> MetricsUploadResponse {
        var req = metricUploadRequest(userID: userID)
        req.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let stored = payload.samples.filter(\.hasStoredValue).count
        try MetricUploadReceipt.validate(data, stored: stored, skipped: payload.samples.count - stored)
        return try JSONDecoder().decode(MetricsUploadResponse.self, from: data)
    }

    func metricUploadRequest(userID: String) -> URLRequest {
        var req = request(path: "/v1/metrics", method: "POST")
        req.setValue(userID, forHTTPHeaderField: "X-User-ID")
        req.timeoutInterval = 120
        return req
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

    func generateSleepInsight(_ payload: SleepInsightPayload) async throws -> InsightResponse {
        var req = request(path: "/insights", method: "POST")
        // Without this header the server cannot check consent, and a request
        // whose consent cannot be checked is refused rather than waved through.
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

/// Uses a background URLSession so an already queued upload continues when
/// iOS suspends or relaunches the app. The journal remains the durable queue;
/// a file is removed only after a digest-verified server response.
@MainActor
@Observable
final class RawChunkSyncService: NSObject, URLSessionTaskDelegate {
    static let sessionIdentifier = "com.wythin.polar.raw-upload"
    static var active: RawChunkSyncService?
    static var pendingBackgroundCompletionHandler: (() -> Void)?
    private let client: APIClient
    private let userID: String
    private let journal: RawPacketJournal
    nonisolated private let completionGroup = DispatchGroup()
    private var session: URLSession!
    private var isSyncing = false
    private(set) var pendingCount = 0
    private(set) var lastUploadedAt: Date?
    private(set) var lastError: String?
    private var backgroundCompletionHandler: (() -> Void)?

    init(client: APIClient, userID: String, journal: RawPacketJournal) {
        self.client = client
        self.userID = userID
        self.journal = journal
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        Self.active = self
        if let pending = Self.pendingBackgroundCompletionHandler {
            backgroundCompletionHandler = pending
            Self.pendingBackgroundCompletionHandler = nil
        }
    }

    func syncIfEnabled() async {
        pendingCount = (try? journal.pendingChunks().count) ?? 0
        guard !isSyncing else { return }
        guard (UserDefaults.standard.object(forKey: "cloudSyncEnabled") as? Bool ?? true),
              UserDefaults.standard.bool(forKey: "rawCloudSyncEnabled") else {
            for task in await currentTasks() { task.cancel() }
            lastError = nil
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try journal.seal()
            let tasks = await currentTasks()
            let inFlight = Set(tasks.compactMap { $0.originalRequest?.url?.lastPathComponent.lowercased() })
            let available = max(0, 4 - tasks.count)
            var scheduled = 0
            let chunks = try journal.pendingChunks()
            pendingCount = chunks.count
            for file in chunks where scheduled < available {
                let id = file.deletingPathExtension().lastPathComponent.lowercased()
                guard !inFlight.contains(id) else { continue }
                let request = try client.rawChunkRequest(file, userID: userID)
                let task = session.uploadTask(with: request, fromFile: file)
                task.resume()
                scheduled += 1
            }
        } catch {
            lastError = error.localizedDescription
            pendingCount = (try? journal.pendingChunks().count) ?? pendingCount
        }
    }

    private func currentTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
    }

    func handleBackgroundEvents(completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        completionGroup.enter()
        Task { @MainActor in
            await self.finish(task, error: error)
            self.completionGroup.leave()
        }
    }

    private func finish(_ task: URLSessionTask, error: Error?) async {
        if let error {
            let enabled = (UserDefaults.standard.object(forKey: "cloudSyncEnabled") as? Bool ?? true)
                && UserDefaults.standard.bool(forKey: "rawCloudSyncEnabled")
            if !enabled { return }
            lastError = error.localizedDescription
            return
        }
        guard let response = task.response as? HTTPURLResponse,
              response.statusCode == 200,
              let id = task.originalRequest?.url?.lastPathComponent.lowercased(),
              let file = try? journal.pendingChunks().first(where: {
                  $0.deletingPathExtension().lastPathComponent.lowercased() == id
              }),
              let bytes = try? Data(contentsOf: file) else {
            lastError = "Raw archive did not acknowledge the upload"
            return
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard response.value(forHTTPHeaderField: "X-Chunk-SHA256") == digest,
              response.value(forHTTPHeaderField: "X-Chunk-Bytes") == String(bytes.count) else {
            lastError = "Raw archive integrity check failed"
            return
        }
        do {
            try journal.acknowledge(file)
            pendingCount = max(0, pendingCount - 1)
            lastUploadedAt = Date()
            lastError = nil
            Task { await syncIfEnabled() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        completionGroup.notify(queue: .main) {
            Task { @MainActor in
                self.backgroundCompletionHandler?()
                self.backgroundCompletionHandler = nil
            }
        }
    }
}

// MARK: - MetricSyncService

/// Saved rows are the durable pending marker. Bounded immutable batches are
/// handed to a system background session; neither retry nor the final tail
/// depends on another measurement. The 30-second coalescing timer is protected
/// by a finite UIKit allowance and is flushed synchronously on its expiry.
@MainActor
@Observable
final class MetricSyncService: NSObject, URLSessionDataDelegate {
    static let sessionIdentifier = "com.wythin.metrics-upload"
    static var active: MetricSyncService?
    static var pendingBackgroundCompletionHandler: (() -> Void)?
    private let client: APIClient
    private let userID: String
    private let container: ModelContainer
    private let batch: Int
    private let queueDirectory: URL
    private let now: () -> Date
    private let coalescingInterval: TimeInterval
    private let usesBackgroundSession: Bool
    private var queue: MetricUploadQueue?
    private var session: URLSession!
    private var reconciled = false
    private var isSyncing = false
    private var syncRequested = false
    private var profileUploadTask: Task<Bool, Never>?
    private var blockedForStorage = false
    private var consentPauseLogged = false
    private var tasksByBatch: [UUID: URLSessionTask] = [:]
    private var coalescingTimer: Timer?
    private var retryTimer: Timer?
    private var allowance: UIBackgroundTaskIdentifier = .invalid
    private var unlockObserver: NSObjectProtocol?
    private var backgroundCompletionHandler: (() -> Void)?
    nonisolated private let completionGroup = DispatchGroup()
    nonisolated private let responseBodies = MetricUploadResponseBodies()
    private(set) var lastUploadedAt: Date?
    private(set) var lastSavedAt: Date?
    private(set) var lastError: String?
    private(set) var pendingCount = 0
    private var enabled: Bool { UserDefaults.standard.object(forKey: "cloudSyncEnabled") as? Bool ?? true }
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let profileEncoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return encoder
    }()

    init(client: APIClient, userID: String, container: ModelContainer,
         batchSize: Int = 2000, queueDirectory: URL? = nil,
         sessionConfiguration: URLSessionConfiguration? = nil,
         sessionFactory: ((URLSessionConfiguration, URLSessionDelegate) -> URLSession)? = nil,
         coalescingInterval: TimeInterval = 30, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.userID = userID
        self.container = container
        self.batch = min(max(batchSize, 1), 5000)
        self.now = now
        self.coalescingInterval = max(0, coalescingInterval)
        self.usesBackgroundSession = sessionConfiguration == nil
        let namespace = SHA256.hash(data: Data(userID.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        self.queueDirectory = queueDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MetricUploads/\(namespace)", isDirectory: true)
        let uploaded = UserDefaults.standard.double(forKey: "metricsLastUploadAtEpoch")
        self.lastUploadedAt = uploaded > 0 ? Date(timeIntervalSince1970: uploaded) : nil
        super.init()
        let configuration = sessionConfiguration ?? Self.backgroundConfiguration()
        session = sessionFactory?(configuration, self)
            ?? URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        if usesBackgroundSession {
            Self.active = self
            backgroundCompletionHandler = Self.pendingBackgroundCompletionHandler
            Self.pendingBackgroundCompletionHandler = nil
        }
    }

    static func backgroundConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        // Background sessions always wait for connectivity; their file tasks
        // also survive suspension and a system-initiated process termination.
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = 3
        return configuration
    }

    func start() {
        if unlockObserver == nil {
            unlockObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in await self?.syncIfEnabled() }
                }
        }
        beginAllowance()
        Task { await syncIfEnabled() }
    }

    /// UI consent changes cancel known tasks synchronously, then enumerate
    /// restored tasks too. Unsent rows and immutable files remain on device.
    func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "cloudSyncEnabled")
        if value {
            consentPauseLogged = false
            BLEDiag.log("METRIC_SYNC consent=on")
            start()
        } else {
            pauseForConsent()
            Task { await syncIfEnabled() }
        }
    }

    /// Call immediately after the SwiftData save succeeds. No asynchronous
    /// task or per-sample file is necessary to make that pending marker durable.
    func savedMetricsDidChange() {
        lastSavedAt = now()
        guard enabled else { pauseForConsent(); return }
        consentPauseLogged = false
        guard coalescingTimer == nil else { return }
        beginAllowance()
        if usesBackgroundSession, allowance == .invalid,
           UIApplication.shared.applicationState != .active {
            flush()
            return
        }
        coalescingTimer = Timer.scheduledTimer(withTimeInterval: max(0.01, coalescingInterval), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushAndEndAllowance() }
        }
    }

    /// Synchronous: file persistence and uploadTask.resume happen before the
    /// app returns its lifecycle/expiration callback to iOS.
    func applicationDidEnterBackground() { flushAndEndAllowance() }

    func syncIfEnabled() async {
        // Even when disabled, enumerate restored system tasks before returning.
        // Cancelling only the in-memory map would miss uploads across relaunch.
        if !enabled { pauseForConsent() }
        guard !isSyncing else { syncRequested = true; return }
        isSyncing = true
        syncRequested = false
        blockedForStorage = false
        defer {
            isSyncing = false
            // Coalesce any number of requests during reconciliation/profile I/O
            // into one follow-up. Only an external request sets this flag.
            if syncRequested {
                syncRequested = false
                Task { await syncIfEnabled() }
            }
        }
        if !reconciled {
            let tasks = await withCheckedContinuation { continuation in
                session.getAllTasks { continuation.resume(returning: $0) }
            }
            for task in tasks {
                guard let description = task.taskDescription, let id = UUID(uuidString: description),
                      task.state == .running || task.state == .suspended else { task.cancel(); continue }
                if tasksByBatch[id] != nil { task.cancel() }
                else { tasksByBatch[id] = task }
            }
            reconciled = true
        }
        guard enabled else {
            pauseForConsent()
            if let queue = try? openQueue() {
                pendingCount = (try? ModelContext(container).fetchCount(pendingDescriptor(queue.migrationBoundary))) ?? pendingCount
            }
            return
        }
        flushAndEndAllowance()
        await syncProfileIfNeeded()
    }

    private func beginAllowance() {
        guard usesBackgroundSession, allowance == .invalid else { return }
        allowance = UIApplication.shared.beginBackgroundTask(withName: "Save metric upload tail") { [weak self] in
            // UIKit invokes this on the main thread. Do not launch an async
            // Task here: the handoff must finish before the allowance ends.
            MainActor.assumeIsolated { self?.flushAndEndAllowance(expiring: true) }
        }
    }

    private func flushAndEndAllowance(expiring: Bool = false) {
        coalescingTimer?.invalidate(); coalescingTimer = nil
        flush()
        // A normal lifecycle callback can precede getAllTasks. Keep the finite
        // allowance through that reconciliation; expiry must still end it.
        if allowance != .invalid && (reconciled || expiring || !enabled) {
            UIApplication.shared.endBackgroundTask(allowance)
            allowance = .invalid
        }
    }

    private func pauseForConsent() {
        coalescingTimer?.invalidate(); coalescingTimer = nil
        retryTimer?.invalidate(); retryTimer = nil
        profileUploadTask?.cancel()
        for task in tasksByBatch.values { task.cancel() }
        tasksByBatch.removeAll()
        if allowance != .invalid { UIApplication.shared.endBackgroundTask(allowance); allowance = .invalid }
        lastError = nil
        if !consentPauseLogged {
            BLEDiag.log("METRIC_SYNC consent=off pending=\(pendingCount)")
            consentPauseLogged = true
        }
    }

    private func openQueue() throws -> MetricUploadQueue {
        if let queue { return queue }
        let defaults = UserDefaults.standard
        let epoch = defaults.double(forKey: "metricsLastSyncedEpoch")
        let legacy = defaults.string(forKey: "metricsLastSyncedAt") ?? ""
        let boundary = epoch > 0 ? Date(timeIntervalSince1970: epoch)
            : (iso.date(from: legacy) ?? ISO8601DateFormatter().date(from: legacy) ?? .distantPast)
        let opened = try MetricUploadQueue(root: queueDirectory, migrationBoundary: boundary)
        queue = opened
        return opened
    }

    private func pendingDescriptor(_ boundary: Date) -> FetchDescriptor<HRVSample> {
        FetchDescriptor<HRVSample>(predicate: #Predicate {
            $0.cloudUploadState == 0 || ($0.cloudUploadState == nil && $0.timestamp >= boundary)
        }, sortBy: [SortDescriptor(\.timestamp)])
    }

    private func flush() {
        guard enabled else { pauseForConsent(); return }
        guard !blockedForStorage else { return }
        do {
            let queue = try openQueue()
            let context = ModelContext(container)
            try applyReceipts(queue, context: context)
            // Three immutable files bound disk duplication and keep a backlog
            // moving in parallel without a new app wake for each individual row.
            while queue.entries.count < 3 {
                let represented = Set(queue.entries.flatMap(\.members))
                var descriptor = pendingDescriptor(queue.migrationBoundary)
                descriptor.fetchLimit = batch * 4
                let fetched = try context.fetch(descriptor)
                let samples = try fetched.filter { !represented.contains(try membership($0.persistentModelID)) }.prefix(batch)
                guard !samples.isEmpty else { break }
                let payload = MetricsUploadPayload(samples: samples.map {
                    MetricSamplePayload(from: $0, timestamp: iso.string(from: $0.timestamp))
                })
                let stored = payload.samples.filter(\.hasStoredValue).count
                let entry = try queue.enqueue(payload: JSONEncoder().encode(payload),
                    members: samples.map { try membership($0.persistentModelID) },
                    latestSampleAt: samples.map(\.timestamp).max()!, expectedStored: stored,
                    expectedSkipped: samples.count - stored, now: now())
                BLEDiag.log("METRIC_SYNC queued batch=\(entry.id) samples=\(samples.count)")
            }
            pendingCount = try context.fetchCount(pendingDescriptor(queue.migrationBoundary))
            // Startup reconciliation owns the system task inventory. A lifecycle
            // flush can persist files before it finishes; reconciliation then
            // schedules those files, without creating duplicate uploads.
            guard reconciled else { return }
            let known = Set(queue.entries.map(\.id))
            for (id, task) in tasksByBatch {
                if !known.contains(id) {
                    task.cancel(); tasksByBatch.removeValue(forKey: id)
                } else if task.state == .suspended {
                    // A crash can occur after taskDescription is persisted but
                    // before resume(). Reconcile that real system task instead
                    // of letting its membership block the queue forever.
                    task.resume()
                    BLEDiag.log("METRIC_SYNC resumed batch=\(id) task=\(task.taskIdentifier)")
                }
            }
            for entry in queue.entries where entry.acknowledgedAt == nil && tasksByBatch[entry.id] == nil {
                guard tasksByBatch.count < 3 else { break }
                if !usesBackgroundSession && entry.nextAttemptAt > now() { continue }
                let file = queue.payloadURL(for: entry.id)
                guard FileManager.default.fileExists(atPath: file.path) else { throw CocoaError(.fileReadNoSuchFile) }
                let task = session.uploadTask(with: client.metricUploadRequest(userID: userID), fromFile: file)
                task.taskDescription = entry.id.uuidString
                task.earliestBeginDate = entry.nextAttemptAt
                tasksByBatch[entry.id] = task
                task.resume()
                BLEDiag.log("METRIC_SYNC scheduled batch=\(entry.id) task=\(task.taskIdentifier) attempt=\(entry.attempts) delay=\(max(0, Int(entry.nextAttemptAt.timeIntervalSince(now()))))")
            }
            scheduleForegroundRetry()
        } catch {
            lastError = "Cannot prepare saved metrics for upload"
            BLEDiag.log("METRIC_SYNC queue_error code=\((error as NSError).code)")
        }
    }

    private func membership(_ id: PersistentIdentifier) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(id)
    }

    private func applyReceipts(_ queue: MetricUploadQueue, context: ModelContext) throws {
        for entry in queue.entries where entry.acknowledgedAt != nil {
            let ids = try entry.members.map { try JSONDecoder().decode(PersistentIdentifier.self, from: $0) }
            let descriptor = FetchDescriptor<HRVSample>(predicate: #Predicate { ids.contains($0.persistentModelID) })
            for sample in try context.fetch(descriptor) { sample.cloudUploadState = 1 }
            try context.save()
            let defaults = UserDefaults.standard
            let epoch = max(defaults.double(forKey: "metricsLastSyncedEpoch"), entry.latestSampleAt.timeIntervalSince1970)
            defaults.set(epoch, forKey: "metricsLastSyncedEpoch")
            defaults.set(iso.string(from: Date(timeIntervalSince1970: epoch)), forKey: "metricsLastSyncedAt")
            if let acceptedAt = entry.acknowledgedAt {
                lastUploadedAt = max(lastUploadedAt ?? .distantPast, acceptedAt)
                defaults.set(lastUploadedAt!.timeIntervalSince1970, forKey: "metricsLastUploadAtEpoch")
            }
            try queue.removeAcknowledged(entry.id)
        }
    }

    private func scheduleForegroundRetry() {
        retryTimer?.invalidate(); retryTimer = nil
        guard !usesBackgroundSession, enabled,
              let due = queue?.entries.filter({ $0.acknowledgedAt == nil && tasksByBatch[$0.id] == nil }).map(\.nextAttemptAt).min() else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, due.timeIntervalSince(now())), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
    }

    func handleBackgroundEvents(completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
        start()
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseBodies.append(data, task: dataTask.taskIdentifier)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let body = responseBodies.take(task: task.taskIdentifier)
        completionGroup.enter()
        Task { @MainActor in
            self.finish(task, body: body, error: error)
            self.completionGroup.leave()
        }
    }

    private func finish(_ task: URLSessionTask, body: Data, error: Error?) {
        guard let description = task.taskDescription, let id = UUID(uuidString: description),
              tasksByBatch[id]?.taskIdentifier == task.taskIdentifier else { return }
        tasksByBatch.removeValue(forKey: id)
        guard enabled else { pauseForConsent(); return }
        do {
            let queue = try openQueue()
            guard queue.entries.contains(where: { $0.id == id }) else { return }
            if error == nil, let response = task.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) {
                try queue.acknowledge(id, response: body, now: now())
                try applyReceipts(queue, context: ModelContext(container))
                lastError = nil
                BLEDiag.log("METRIC_SYNC acknowledged batch=\(id) task=\(task.taskIdentifier)")
            } else {
                throw error ?? URLError(.badServerResponse)
            }
        } catch {
            // If the receipt was saved but SwiftData could not yet be updated,
            // fail() preserves it; the next flush/relaunch applies that receipt.
            do { try queue?.fail(id, now: now()) }
            catch {
                blockedForStorage = true
                lastError = "Cannot save metric upload retry"
                BLEDiag.log("METRIC_SYNC retry_storage_error code=\((error as NSError).code)")
                return
            }
            lastError = "Metric upload waiting to retry"
            BLEDiag.log("METRIC_SYNC retry batch=\(id) status=\((task.response as? HTTPURLResponse)?.statusCode ?? 0) code=\((error as NSError).code)")
        }
        // Background retry tasks carry earliestBeginDate. iOS owns their wait;
        // a failed callback never immediately sends another network request.
        flush()
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        completionGroup.notify(queue: .main) {
            Task { @MainActor in
                self.backgroundCompletionHandler?()
                self.backgroundCompletionHandler = nil
            }
        }
    }

    var diagnosticsSummary: [String: String] {
        let entries = queue?.entries ?? []
        return [
            "consent": enabled ? "enabled" : "disabled",
            "pending_samples": String(pendingCount),
            "queued_batches": String(entries.count),
            "oldest_queued_at": entries.map(\.createdAt).min().map(iso.string) ?? "none",
            "latest_queued_sample_at": entries.map(\.latestSampleAt).max().map(iso.string) ?? "none",
            "storage_retry_blocked": String(blockedForStorage),
            "queued_samples": String(entries.reduce(0) { $0 + $1.expectedStored + $1.expectedSkipped }),
            "in_flight": String(tasksByBatch.count),
            "saved_at": lastSavedAt.map(iso.string) ?? "unknown",
            "acknowledged_at": lastUploadedAt.map(iso.string) ?? "none",
            "next_retry_at": entries.filter { $0.attempts > 0 }.map(\.nextAttemptAt).min().map(iso.string) ?? "none",
            "maximum_attempts": String(entries.map(\.attempts).max() ?? 0),
            "error": lastError ?? "none"
        ]
    }

    private func syncProfileIfNeeded() async {
        guard enabled else { return }
        let p = ClientProfileStore().load()
        guard p.hasRequiredContact else { return }
        let profile = ProfilePayload(
            first_name: p.firstName, last_name: p.lastName,
            phone: p.phone, email: p.email, age_range: p.ageRange, gender: p.gender,
            height_cm: p.heightCm, weight_kg: p.weightKg,
            goals: p.goals, practices: p.practices, devices: p.devices,
            state_focus: p.state.focus, state_anxiety: p.state.anxiety,
            state_energy: p.state.energy, state_sleep_quality: p.state.sleepQuality,
            state_stress: p.state.stress,
            consent_share_team: OnboardingConsent.shareWithTeam(),
            consent_ai_insights: OnboardingConsent.aiInsights(),
            timezone: TimeZone.autoupdatingCurrent.identifier)
        guard let encoded = try? Self.profileEncoder.encode(profile) else { return }
        let canonical = String(decoding: encoded, as: UTF8.self)
        guard canonical != UserDefaults.standard.string(forKey: "profileLastSynced"), enabled else { return }
        let task = Task { [client, userID] in
            (try? await client.uploadProfile(profile, userID: userID)) != nil
        }
        profileUploadTask = task
        let accepted = await task.value
        profileUploadTask = nil
        if accepted, enabled, !task.isCancelled {
            UserDefaults.standard.set(canonical, forKey: "profileLastSynced")
        }
    }
}

/// URLSession delegate callbacks are not actor-isolated. Accumulate every body
/// fragment under a lock, cap unexpected response bodies, and consume once.
private final class MetricUploadResponseBodies: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Int: Data] = [:]
    func append(_ data: Data, task: Int) {
        lock.lock(); defer { lock.unlock() }
        var body = bodies[task] ?? Data()
        if body.count <= 65_536 { body.append(data.prefix(65_537 - body.count)) }
        bodies[task] = body
    }
    func take(task: Int) -> Data {
        lock.lock(); defer { lock.unlock() }
        return bodies.removeValue(forKey: task) ?? Data()
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
    func generateSleepInsight(_ payload: SleepInsightPayload) async throws -> InsightResponse
}

extension APIClient: InsightAPIClient {}

/// Narrow protocol over `APIClient.uploadUsage` so `UsageUploader` can be
/// tested with a fake instead of a real network call.
protocol UsageAPIClient {
    func uploadUsage(_ payload: UsageUploadPayload, userID: String) async throws
}

extension APIClient: UsageAPIClient {}

/// Narrow protocol over `APIClient.uploadFeltStateLog` so `FeltStateLogUploader`
/// can be tested with a fake instead of a real network call.
enum FeltStateUploadError: Error {
    case httpStatus(Int)
    case invalidReceipt

    var isRecordRejection: Bool {
        guard case .httpStatus(let code) = self else { return false }
        return [400, 409, 422].contains(code)
    }
}

protocol FeltStateAPIClient {
    var baseURL: URL { get }
    func uploadFeltStateLog(_ payload: FeltStateUploadPayload, userID: String) async throws
}

extension APIClient: FeltStateAPIClient {}

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

extension MetricSamplePayload {
    init(from s: HRVSample, timestamp: String? = nil) {
        let ts: String
        if let timestamp { ts = timestamp } else {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            ts = iso.string(from: s.timestamp)
        }
        self.init(ts: ts, mean_bpm: s.meanBPM, rmssd: s.rmssd, sdnn: s.sdnn,
                  pnn50: s.pnn50, lf_hf: s.lfHF, rsa_ms: s.rsaMs,
                  coherence: s.coherence, cbi: s.cbi, breath_bpm: s.breathBPM,
                  dfa1: s.dfa1, rcmse: s.rcmse, pip: s.pip, dc: s.dc, vti: s.vti,
                  motion: s.motion, signal_quality: s.signalQuality,
                  rr_invalid_rate: s.rrInvalidRate, ecg_quality_tier: s.ecgQualityTier,
                  timezone: s.timezone, stress_balance: s.stressBalanceValue)
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
        self.stressBalance = s.stressBalanceValue
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
    /// - Parameter usual: metric id → the person's own recent average during
    ///   value for this peer group. Empty for a first session, which is the
    ///   honest state and reads as "no comparison yet" rather than as zero.
    init(from entry: ActivityLog, usual: [String: Double] = [:], peers: Int = 0) {
        func avg(_ metric: LiveMetric) -> Float? {
            usual[metricDef(metric).id].map(Float.init)
        }
        self.peerGroup    = peers > 0 ? entry.scoreGroupKey : nil
        self.peerSessions = peers > 0 ? peers : nil
        self.usualHR = avg(.hr); self.usualRSA = avg(.rsa); self.usualSDNN = nil
        self.usualRMSSD = avg(.rmssd); self.usualDC = avg(.dc); self.usualRCMSE = avg(.rcmse)
        self.usualPIP = avg(.pip); self.usualDFA1 = avg(.dfa1); self.usualStress = avg(.stressBalance)
        self.usualBreath = avg(.breathBPM)
        self.activityType    = entry.activityType
        self.activitySubtype = entry.activitySubtype
        self.durationMin     = entry.duration.map { Int($0 / 60) }
        self.beforeHR   = entry.beforeHR;   self.duringHR   = entry.duringHR;   self.afterHR   = entry.afterHR
        self.beforeRSA  = entry.beforeRSA;  self.duringRSA  = entry.duringRSA;  self.afterRSA  = entry.afterRSA
        self.beforeSDNN = entry.beforeSDNN; self.duringSDNN = entry.duringSDNN; self.afterSDNN = entry.afterSDNN
        self.beforeRMSSD = entry.beforeRMSSD; self.duringRMSSD = entry.duringRMSSD; self.afterRMSSD = entry.afterRMSSD
        self.beforeDC = entry.beforeDC; self.duringDC = entry.duringDC; self.afterDC = entry.afterDC
        self.beforeRCMSE = entry.beforeRCMSE; self.duringRCMSE = entry.duringRCMSE; self.afterRCMSE = entry.afterRCMSE
        self.beforePIP = entry.beforePIP; self.duringPIP = entry.duringPIP; self.afterPIP = entry.afterPIP
        self.beforeDFA1 = entry.beforeDFA1; self.duringDFA1 = entry.duringDFA1; self.afterDFA1 = entry.afterDFA1
        self.beforeStress = entry.beforeStress; self.duringStress = entry.duringStress; self.afterStress = entry.afterStress
        self.beforeBreath = entry.beforeBreath; self.duringBreath = entry.duringBreath; self.afterBreath = entry.afterBreath
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
