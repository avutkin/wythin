import SwiftUI
import WebKit
import CryptoKit

/// The contract receipt is deliberately separate from every data permission.
struct TermsReceipt: Codable, Equatable {
    let version: String
    let document_sha256: String
    let accepted_at: String
}

enum LegalDocument: String, CaseIterable, Identifiable {
    case terms = "terms-and-conditions"
    case privacy = "privacy-policy"
    case health = "consumer-health-privacy"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .terms: "Terms & Conditions"
        case .privacy: "Privacy Policy"
        case .health: "Consumer Health Data Privacy Policy"
        }
    }
    var localURL: URL? { Bundle.main.url(forResource: rawValue, withExtension: "html") }
    var publicURL: URL { URL(string: "https://avutkin.github.io/wythin/\(rawValue).html")! }
}

enum AppTerms {
    static let version = "terms-v1-2026-11-15"

    /// Fingerprint all three readable snapshots, not a mutable remote URL.
    /// If any document is absent, acceptance fails closed.
    static var documentSHA256: String? {
        var hash = SHA256()
        for document in LegalDocument.allCases {
            guard let url = document.localURL,
                  let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
            hash.update(data: Data(document.rawValue.utf8))
            hash.update(data: Data([0]))
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum TermsAcceptance {
    static let receiptKey = "termsAcceptanceReceipt"

    static func receipt(in defaults: UserDefaults = .standard) -> TermsReceipt? {
        guard let data = defaults.data(forKey: receiptKey) else { return nil }
        return try? JSONDecoder().decode(TermsReceipt.self, from: data)
    }

    static func hasAccepted(documentSHA256: String?, in defaults: UserDefaults = .standard) -> Bool {
        guard let digest = documentSHA256, let receipt = receipt(in: defaults),
              ISO8601DateFormatter().date(from: receipt.accepted_at) != nil else { return false }
        return receipt.version == AppTerms.version && receipt.document_sha256 == digest
    }

    @discardableResult
    static func accept(checked: Bool, documentSHA256: String?,
                       in defaults: UserDefaults = .standard, now: Date = .now) -> Bool {
        guard checked, let digest = documentSHA256, digest.count == 64,
              digest.allSatisfy({ "0123456789abcdef".contains($0) }) else { return false }
        if hasAccepted(documentSHA256: digest, in: defaults) { return true }
        let receipt = TermsReceipt(version: AppTerms.version, document_sha256: digest,
                                   accepted_at: ISO8601DateFormatter().string(from: now))
        guard let data = try? JSONEncoder().encode(receipt) else { return false }
        // Missing preferences are not permission. Never overwrite a decision
        // made in Settings or turn a past refusal into acceptance of an update.
        for key in ["cloudSyncEnabled", "rawCloudSyncEnabled",
                    OnboardingConsent.shareWithTeamKey, OnboardingConsent.aiInsightsKey] {
            if defaults.object(forKey: key) == nil { defaults.set(false, forKey: key) }
        }
        defaults.set(data, forKey: receiptKey)
        return true
    }
}

struct TermsAcceptanceView: View {
    let onAccepted: () -> Void
    @State private var checked = false
    @State private var document: LegalDocument?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Before you begin")
                        .font(.system(size: 30, weight: .bold))
                    Text("Read and accept the Terms & Conditions to continue with Wythin.")
                        .font(.body)
                    Text("Wythin uses heart signals, movement and information you provide to show wellness trends. Cloud storage, full-signal archiving, coaching and AI sharing have their own controls. Accepting these Terms does not turn them on.")
                        .font(.callout)
                        .foregroundStyle(Theme.dim)
                    ForEach(LegalDocument.allCases) { item in
                        Button { document = item } label: {
                            HStack {
                                Text(item.title).multilineTextAlignment(.leading)
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                        }
                        .accessibilityIdentifier("legal-link-\(item.rawValue)")
                    }
                    Text("Your data choices remain available in Settings. Wythin provides wellness information, not diagnosis or emergency monitoring.")
                        .font(.callout)
                        .foregroundStyle(Theme.dim)
                }
                .padding(.top, 32)
            }

            Button { checked.toggle() } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .font(.title2)
                    Text("I am at least 18 and agree to the Terms & Conditions.")
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("terms-checkbox")
            .accessibilityValue(checked ? "Checked" : "Not checked")

            if let error { Text(error).font(.callout).foregroundStyle(Theme.warn) }

            Button("Accept and continue") {
                guard TermsAcceptance.accept(checked: checked, documentSHA256: AppTerms.documentSHA256) else {
                    error = "The complete legal documents could not be opened. Please try again before continuing."
                    return
                }
                onAccepted()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(!checked || AppTerms.documentSHA256 == nil)
            .accessibilityIdentifier("terms-continue")
            Text("If you do not agree, you can close Wythin. Onboarding will not continue.")
                .font(.footnote).foregroundStyle(Theme.dim)
        }
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .background(Theme.bg.ignoresSafeArea())
        .sheet(item: $document) { LegalDocumentSheet(document: $0) }
    }
}

struct LegalDocumentSheet: View {
    let document: LegalDocument
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Group {
                if let url = document.localURL {
                    LegalDocumentReader(url: url) { openURL($0) }
                } else {
                    ContentUnavailableView("Document unavailable", systemImage: "doc",
                        description: Text("Please reopen Wythin before accepting the Terms."))
                }
            }
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Local, script-free snapshots work before onboarding and without a network.
/// External pages open only after an intentional tap; nothing is preloaded.
private struct LegalDocumentReader: UIViewRepresentable {
    let url: URL
    let openExternal: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(openExternal: openExternal) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return web
    }
    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let openExternal: (URL) -> Void
        init(openExternal: @escaping (URL) -> Void) { self.openExternal = openExternal }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            let allowedFiles = LegalDocument.allCases.compactMap { $0.localURL?.standardizedFileURL.path }
            if url.isFileURL, allowedFiles.contains(url.standardizedFileURL.path) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                if navigationAction.navigationType == .linkActivated,
                   ["https", "mailto"].contains(url.scheme?.lowercased() ?? "") { openExternal(url) }
            }
        }
    }
}
