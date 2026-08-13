import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppEnvironment.self) var env

    @State private var serverURLText: String = ""
    @State private var tokens: [TokenInfo] = []
    @State private var newToken: TokenCreated?      // non-nil drives the once-shown sheet
    @State private var isWorking = false
    @State private var accessError: String?

    @AppStorage("cloudSyncEnabled") private var cloudSyncEnabled = true
    @AppStorage(OnboardingConsent.shareWithTeamKey)
    private var shareWithTeam = OnboardingConsent.shareWithTeamDefault
    @AppStorage(OnboardingConsent.aiInsightsKey)
    private var aiInsightsEnabled = OnboardingConsent.aiInsightsDefault
    @State private var showDataDetail = false
    @State private var isDeletingCloudData = false
    @State private var notificationsAuthorized: Bool?

    // MARK: Cloud restore
    @Environment(\.modelContext) private var modelContext
    @State private var restore = CloudRestoreService()
    @State private var confirmRestore = false

    private var restoreLabel: String {
        switch restore.phase {
        case .idle:
            return "Restore history from cloud"
        case .failed:
            return "Resume restore from cloud"
        case .restoring(let n):
            return "Restoring… \(n) samples — keep the app open"
        case .done(let s, let a):
            return "Restored \(s) samples, \(a) activities"
        }
    }

    // MARK: Nudges

    private var nudgesBinding: Binding<Bool> {
        Binding(get: { env.nudgesEnabled },
                set: { on in
                    env.nudgesEnabled = on
                    if on {
                        Task {
                            _ = await env.notifications.requestAuthorization()
                            await refreshAuthorization()
                        }
                    }
                })
    }

    private func binding(for id: NudgeInterventionID) -> Binding<Bool> {
        Binding(get: { !env.disabledInterventions.contains(id) },
                set: { on in
                    var disabled = env.disabledInterventions
                    if on { disabled.remove(id) } else { disabled.insert(id) }
                    env.disabledInterventions = disabled
                })
    }

    private func refreshAuthorization() async {
        let status = await env.notifications.authorizationStatus()
        notificationsAuthorized = (status == .authorized || status == .provisional)
    }

    /// Says why it is quiet, so a silent day reads as working rather than broken.
    private var nudgeStateLabel: String {
        switch env.lastNudgeSuppression {
        case .strapOff:           return "waiting for the strap"
        case .activityInProgress: return "you're mid-activity"
        case .noBaseline:         return "still learning your range"
        case .warmingUp:          return "warming up"
        case .quietHours:         return "quiet hours"
        case .budgetExhausted:    return "done for today"
        case .none:               return "watching"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                List {
                    // ── Device ────────────────────────────────────────
                    Section("POLAR H10") {
                        HStack {
                            Text("Status")
                                .font(Theme.monoBody)
                                .foregroundStyle(Theme.text)
                            Spacer()
                            Text(bleStatusLabel)
                                .font(Theme.monoLabel)
                                .foregroundStyle(bleStatusColor)
                        }

                        if case .connected = env.ble.state {
                            HStack {
                                Text("Battery")
                                    .font(Theme.monoBody)
                                    .foregroundStyle(Theme.text)
                                Spacer()
                                Text(env.ble.batteryLevel.map { "\($0)%" } ?? "—")
                                    .font(Theme.monoLabel)
                                    .foregroundStyle(Theme.dim)
                            }
                        }

                        Text("Use the  ⌁  icon on the Live tab to connect or switch devices.")
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)
                    }
                    .listRowBackground(Theme.card)

                    // ── Server ────────────────────────────────────────
                    Section("SERVER SYNC") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Server URL")
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.dim)
                            TextField("http://your-server:8000", text: $serverURLText)
                                .font(Theme.monoBody)
                                .foregroundStyle(Theme.text)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .onSubmit { saveServerURL() }
                        }

                        HStack {
                            Text("User ID")
                                .font(Theme.monoBody)
                                .foregroundStyle(Theme.text)
                            Spacer()
                            Text(env.userID.prefix(8) + "…")
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.dim)
                        }

                        // One-shot read-back of the cloud copy. Idempotent —
                        // it only fills what the local store is missing.
                        Button {
                            confirmRestore = true
                        } label: {
                            HStack {
                                Text(restoreLabel)
                                    .font(Theme.monoBody)
                                    .foregroundStyle(restore.isRunning ? Theme.dim : Theme.accent)
                                Spacer()
                                if restore.isRunning {
                                    ProgressView().tint(Theme.accent).scaleEffect(0.8)
                                }
                            }
                        }
                        .disabled(restore.isRunning)
                        .confirmationDialog(
                            "Download your synced history from the cloud into this phone? Existing local data is kept; only missing samples and activities are added.",
                            isPresented: $confirmRestore, titleVisibility: .visible
                        ) {
                            Button("Restore history") {
                                Task { await restore.run(env: env, context: modelContext) }
                            }
                            Button("Cancel", role: .cancel) {}
                        }
                        if case .failed(let message) = restore.phase {
                            Text(message)
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.warn)
                        }
                    }
                    .listRowBackground(Theme.card)

                    // ── Claude Code access ────────────────────────────
                    Section("CLAUDE CODE ACCESS") {
                        Text("Create a token to reach your own data from Claude Code. Your token is private — anyone who has it can read your data.")
                            .font(Theme.monoLabel)
                            .foregroundStyle(Theme.dim)

                        Button {
                            Task { await createToken() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "key.horizontal")
                                Text(isWorking ? "Working…" : "Create Access Token")
                            }
                            .font(Theme.monoBody)
                            .foregroundStyle(Theme.accent)
                        }
                        .disabled(isWorking)

                        if let accessError {
                            Text(accessError)
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.warn)
                        }

                        ForEach(tokens) { token in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(token.name ?? "Access token")
                                    .font(Theme.monoBody)
                                    .foregroundStyle(Theme.text)
                                Text("created \(shortDate(token.createdAt)) · last used \(token.lastUsedAt.map(shortDate) ?? "never")")
                                    .font(Theme.monoLabel)
                                    .foregroundStyle(Theme.dim)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await revoke(token) }
                                } label: { Label("Revoke", systemImage: "trash") }
                            }
                        }

                        Divider()

                        Toggle(isOn: $cloudSyncEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sync my data to the cloud").font(Theme.monoBody).foregroundStyle(Theme.text)
                                Text("Lets Claude Code read your continuous metrics. Off = data stays on this device.")
                                    .font(Theme.monoLabel).foregroundStyle(Theme.dim)
                            }
                        }
                        .tint(Theme.accent)

                        if cloudSyncEnabled {
                            Button(role: .destructive) {
                                Task { await deleteCloudData() }
                            } label: {
                                Text(isDeletingCloudData ? "Deleting…" : "Delete my cloud data")
                                    .font(Theme.monoBody)
                                    .foregroundStyle(Theme.warn)
                            }
                            .disabled(isDeletingCloudData)
                        }
                    }
                    .listRowBackground(Theme.card)

                    // ── Data sharing ──────────────────────────────────
                    //
                    // Onboarding deliberately doesn't ask about these, so this
                    // section is the only place they are ever presented. That
                    // makes the "What's shared" link load-bearing rather than
                    // decorative: without it nothing in the app ever states
                    // where the data goes.
                    Section("DATA SHARING") {
                        Toggle(isOn: $shareWithTeam) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Share with the Wythin team").font(Theme.monoBody).foregroundStyle(Theme.text)
                                Text("Lets a coach review your sessions and adjust your guidance.")
                                    .font(Theme.monoLabel).foregroundStyle(Theme.dim)
                            }
                        }
                        .tint(Theme.accent)

                        Toggle(isOn: $aiInsightsEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Personalised guidance").font(Theme.monoBody).foregroundStyle(Theme.text)
                                Text("Sends your metrics to \(AIProvider.name) to write your insights. Off = no AI guidance.")
                                    .font(Theme.monoLabel).foregroundStyle(Theme.dim)
                            }
                        }
                        .tint(Theme.accent)

                        Button { showDataDetail = true } label: {
                            Text("What's shared?")
                                .font(Theme.monoBody)
                                .foregroundStyle(Theme.breathe)
                        }
                    }
                    .listRowBackground(Theme.card)

                    // ── Nudges ────────────────────────────────────────
                    Section("NUDGES") {
                        Toggle(isOn: nudgesBinding) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Nudge me when my state shifts")
                                    .font(Theme.monoBody).foregroundStyle(Theme.text)
                                Text("At most three a day, never between 10pm and 7am, and never while you're moving.")
                                    .font(Theme.monoLabel).foregroundStyle(Theme.dim)
                            }
                        }
                        .tint(Theme.accent)

                        // Always visible, on or off: the point of this row is to
                        // explain a quiet day, which is exactly what you want to
                        // read *before* deciding to turn nudges on.
                        HStack {
                            Text("Right now")
                                .font(Theme.monoBody).foregroundStyle(Theme.text)
                            Spacer()
                            Text(nudgeStateLabel)
                                .font(Theme.monoLabel).foregroundStyle(Theme.dim)
                        }

                        Button {
                            Task { await env.sendTestNudge() }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Image(systemName: "paperplane")
                                    Text("Send a test nudge")
                                }
                                .font(Theme.monoBody)
                                .foregroundStyle(Theme.accent)
                                Text("Arrives in 5 seconds — background the app to see the real banner and its buttons.")
                                    .font(Theme.monoLabel).foregroundStyle(Theme.dim)
                            }
                        }

                        if env.nudgesEnabled {
                            if notificationsAuthorized == false {
                                Button {
                                    Task {
                                        _ = await env.notifications.requestAuthorization()
                                        await refreshAuthorization()
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "bell.badge")
                                        Text("Allow notifications")
                                    }
                                    .font(Theme.monoBody)
                                    .foregroundStyle(Theme.accent)
                                }
                            }

                            Divider()

                            Text("WHAT I CAN SUGGEST")
                                .font(Theme.monoLabel).foregroundStyle(Theme.dim)

                            ForEach(NudgeInterventionLibrary.all, id: \.id) { option in
                                Toggle(isOn: binding(for: option.id)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(option.title) · \(option.minutes) min")
                                            .font(Theme.monoBody).foregroundStyle(Theme.text)
                                        Text(option.why)
                                            .font(Theme.monoLabel).foregroundStyle(Theme.dim)
                                    }
                                }
                                .tint(Theme.accent)
                            }
                        }
                    }
                    .listRowBackground(Theme.card)

                    // ── About ─────────────────────────────────────────
                    Section("ABOUT") {
                        HStack {
                            Text("Version")
                                .font(Theme.monoBody)
                                .foregroundStyle(Theme.text)
                            Spacer()
                            Text(appVersion)
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.dim)
                        }
                        HStack {
                            Text("Device")
                                .font(Theme.monoBody)
                                .foregroundStyle(Theme.text)
                            Spacer()
                            Text(UIDevice.current.model)
                                .font(Theme.monoLabel)
                                .foregroundStyle(Theme.dim)
                        }
                    }
                    .listRowBackground(Theme.card)
                }
                .scrollContentBackground(.hidden)
                .background(Theme.bg)
            }
            .navigationTitle("SETTINGS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear {
                serverURLText = env.serverURL.absoluteString
            }
            .sheet(item: $newToken) { created in
                NewTokenSheet(command: MCPSetup.claudeCommand(serverURL: env.serverURL, token: created.token),
                              token: created.token)
            }
            .sheet(isPresented: $showDataDetail) {
                DataSharingDetailSheet(onDone: { showDataDetail = false })
            }
            .task { await loadTokens() }
            .task { await refreshAuthorization() }
        }
    }

    private var bleStatusLabel: String {
        switch env.ble.state {
        case .idle:              return "IDLE"
        case .scanning:          return "SCANNING…"
        case .connecting(let n): return "CONNECTING \(n)"
        case .connected(let n):  return n.uppercased()
        case .disconnected(let r): return "OFF — \(r)"
        case .standby:           return "IDLE — STRAP OFF"
        case .unauthorized:      return "NO PERMISSION"
        case .unsupported:       return "UNSUPPORTED"
        }
    }

    private var bleStatusColor: Color {
        switch env.ble.state {
        case .connected:    return Theme.accent
        case .scanning,
             .connecting:   return Theme.warn
        default:            return Theme.dim
        }
    }

    private func saveServerURL() {
        if let url = URL(string: serverURLText) {
            env.serverURL = url
        }
    }

    private func loadTokens() async {
        tokens = (try? await env.sync.client.listTokens(userID: env.userID)) ?? tokens
    }

    private func createToken() async {
        isWorking = true; accessError = nil
        defer { isWorking = false }
        do {
            let name = "\(UIDevice.current.name) · \(shortDate(ISO8601DateFormatter().string(from: Date())))"
            newToken = try await env.sync.client.createToken(name: name, userID: env.userID)
            await loadTokens()
        } catch {
            accessError = "Couldn't create token. Check the server URL and try again."
        }
    }

    private func revoke(_ token: TokenInfo) async {
        do {
            try await env.sync.client.revokeToken(id: token.id, userID: env.userID)
            await loadTokens()
        } catch {
            accessError = "Couldn't revoke token."
        }
    }

    /// Erases the caller's data server-side. Mints a short-lived token to
    /// authorize the Bearer-scoped delete call, then revokes it immediately
    /// afterward — no token is left persisted just for this one-off action.
    ///
    /// The revoke runs in a `defer` right after the token is minted, so it
    /// fires on every exit path (success, `deleteMyData` throwing, etc.) —
    /// a stray full-scope token is never left live on the server.
    private func deleteCloudData() async {
        isDeletingCloudData = true; accessError = nil
        defer { isDeletingCloudData = false }
        do {
            let created = try await env.sync.client.createToken(name: "delete-my-data", userID: env.userID)
            defer {
                Task { try? await env.sync.client.revokeToken(id: created.id, userID: env.userID) }
            }
            try await env.sync.client.deleteMyData(token: created.token)
            await loadTokens()
        } catch {
            accessError = "Couldn't delete cloud data. Check the server URL and try again."
        }
    }

    private func shortDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: iso) else { return iso }
        let out = DateFormatter(); out.dateFormat = "MMM d"
        return out.string(from: d)
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

// MARK: - NewTokenSheet

private struct NewTokenSheet: View {
    let command: String
    let token: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Save this now — it won't be shown again.")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.warn)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("TOKEN").font(Theme.monoLabel).foregroundStyle(Theme.dim)
                        Text(token)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        copyButton("Copy token", value: token)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("CLAUDE CODE SETUP").font(Theme.monoLabel).foregroundStyle(Theme.dim)
                        Text(command)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        copyButton("Copy command", value: command)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.bg)
            .navigationTitle("ACCESS TOKEN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private func copyButton(_ label: String, value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc")
                Text(label)
            }
            .font(Theme.monoBody)
            .foregroundStyle(Theme.accent)
        }
    }
}
