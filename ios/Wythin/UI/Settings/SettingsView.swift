import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppEnvironment.self) var env

    @State private var serverURLText: String = ""
    @State private var tokens: [TokenInfo] = []
    @State private var newToken: TokenCreated?      // non-nil drives the once-shown sheet
    @State private var isWorking = false
    @State private var accessError: String?

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
            .task { await loadTokens() }
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
