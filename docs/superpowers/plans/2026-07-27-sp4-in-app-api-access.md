# SP4 — In-app "Claude Code Access" screen — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A "CLAUDE CODE ACCESS" section in the app's Settings that lets a user mint a personal access token, see the token + a ready-to-paste `claude mcp add` command (once), and list/revoke their tokens — all without touching the shared API key.

**Architecture:** iOS-only. `APIClient` gets `createToken`/`listTokens`/`revokeToken` (calling the live SP1 `/v1/tokens` endpoints with the app's `X-User-ID`). A pure `MCPSetup.claudeCommand` builds the setup command. `SettingsView` gets the section + a once-shown new-token sheet + a revocable token list. No server change.

**Tech Stack:** Swift, SwiftUI, existing `APIClient`, `UIPasteboard`, XCTest (WythinTests).

## Global Constraints

- **No `.xcodeproj` change:** put the models + `MCPSetup` in the existing in-target file `ios/Wythin/Sync/APIClient.swift`; append unit tests to the existing `ios/WythinTests/PayloadBuilderTests.swift`; edit the existing `ios/Wythin/UI/Settings/SettingsView.swift`. Do NOT create new source files (they'd need a target membership edit).
- Token endpoints send `X-User-ID = env.userID` (mirrors `uploadSession`); the shared `X-API-Key` is added by the existing `request(path:method:)` helper — the user never sees or handles it.
- The token is shown exactly once, on creation. The list shows metadata only (server never returns the raw token again).
- Match the server JSON: `created_at`, `last_used_at` (snake_case) via `CodingKeys`.
- Follow the file's existing style (Theme fonts/colors, `List`/`Section` with `.listRowBackground(Theme.card)`).
- Build with: `xcodebuild -project ios/Wythin.xcodeproj -scheme Wythin -destination 'generic/platform=iOS Simulator' -configuration Debug build`. Ignore SourceKit "Cannot find … in scope" diagnostics — only a real `xcodebuild` result counts.

## File Structure

- Modify `ios/Wythin/Sync/APIClient.swift` — add `TokenCreated`, `TokenInfo`, `enum MCPSetup`, and the three `APIClient` methods.
- Modify `ios/WythinTests/PayloadBuilderTests.swift` — add decode + command-string tests.
- Modify `ios/Wythin/UI/Settings/SettingsView.swift` — add the section, the new-token sheet, and list/revoke logic.

---

### Task 1: Token models, API client methods, and command helper (+ unit tests)

**Files:**
- Modify: `ios/Wythin/Sync/APIClient.swift`
- Test: `ios/WythinTests/PayloadBuilderTests.swift`

**Interfaces:**
- Produces: `struct TokenCreated: Codable, Identifiable`, `struct TokenInfo: Codable, Identifiable`; `enum MCPSetup { static func claudeCommand(serverURL:token:) -> String }`; `APIClient.createToken(name:userID:)`, `.listTokens(userID:)`, `.revokeToken(id:userID:)`.

- [ ] **Step 1: Write the failing unit tests** — append to `ios/WythinTests/PayloadBuilderTests.swift`:

```swift
func testTokenCreatedDecodesSnakeCase() throws {
    let json = """
    {"token":"wyth_pat_abc","id":"11111111-1111-1111-1111-111111111111","name":"iPhone","created_at":"2026-07-27T01:00:00Z"}
    """.data(using: .utf8)!
    let t = try JSONDecoder().decode(TokenCreated.self, from: json)
    XCTAssertEqual(t.token, "wyth_pat_abc")
    XCTAssertEqual(t.id, "11111111-1111-1111-1111-111111111111")
    XCTAssertEqual(t.name, "iPhone")
    XCTAssertEqual(t.createdAt, "2026-07-27T01:00:00Z")
}

func testTokenInfoDecodesNullsAndSnakeCase() throws {
    let json = """
    [{"id":"22222222-2222-2222-2222-222222222222","name":null,"created_at":"2026-07-27T01:00:00Z","last_used_at":null}]
    """.data(using: .utf8)!
    let list = try JSONDecoder().decode([TokenInfo].self, from: json)
    XCTAssertEqual(list.count, 1)
    XCTAssertNil(list[0].name)
    XCTAssertNil(list[0].lastUsedAt)
    XCTAssertEqual(list[0].createdAt, "2026-07-27T01:00:00Z")
}

func testClaudeCommandString() {
    let url = URL(string: "https://api.example.com")!
    let cmd = MCPSetup.claudeCommand(serverURL: url, token: "wyth_pat_xyz")
    XCTAssertEqual(cmd, "claude mcp add --transport http wythin https://api.example.com/mcp --header \"Authorization: Bearer wyth_pat_xyz\"")
}

func testClaudeCommandStripsTrailingSlash() {
    let url = URL(string: "https://api.example.com/")!
    let cmd = MCPSetup.claudeCommand(serverURL: url, token: "t")
    XCTAssertTrue(cmd.contains("https://api.example.com/mcp"))
    XCTAssertFalse(cmd.contains(".com//mcp"))
}
```

- [ ] **Step 2: Run to confirm they fail**

Run: `xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:WythinTests/PayloadBuilderTests 2>&1 | tail -20`
(If `iPhone 16` isn't listed by `xcrun simctl list devices available`, pick any available iOS simulator name.)
Expected: FAIL to compile / tests missing symbols (`TokenCreated`, `MCPSetup` unknown).

- [ ] **Step 3: Add models + helper to `ios/Wythin/Sync/APIClient.swift`**

Add near the other response structs (e.g. after `InsightResponse`):

```swift
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
```

- [ ] **Step 4: Add the three methods to `APIClient`** (after `fetchSessions`, following the `uploadSession` pattern)

```swift
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
```

- [ ] **Step 5: Run the tests — verify green**

Run: `xcodebuild test -project ios/Wythin.xcodeproj -scheme Wythin -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:WythinTests/PayloadBuilderTests 2>&1 | tail -20`
Expected: the 4 new tests + existing PayloadBuilder tests PASS. (If the simulator/`test` action is unavailable in this environment, fall back to a plain `build` and report that the tests could not be executed locally — they run in CI.)

- [ ] **Step 6: Commit**

```bash
git add ios/Wythin/Sync/APIClient.swift ios/WythinTests/PayloadBuilderTests.swift
git commit -m "feat(api-access): token API client methods, models, and claude-command helper"
```

---

### Task 2: Settings "CLAUDE CODE ACCESS" section

**Files:**
- Modify: `ios/Wythin/UI/Settings/SettingsView.swift`

**Interfaces:**
- Consumes: `env.userID`, `env.serverURL`, `env.sync.client` (the `APIClient`), and Task 1's `createToken`/`listTokens`/`revokeToken`/`MCPSetup`.

- [ ] **Step 1: Add state + the section to `SettingsView`**

At the top of the file add `import UIKit` (for `UIPasteboard`). Add state properties to `SettingsView`:

```swift
@State private var tokens: [TokenInfo] = []
@State private var newToken: TokenCreated?      // non-nil drives the once-shown sheet
@State private var isWorking = false
@State private var accessError: String?
```

Insert this section in the `List` after the SERVER SYNC section (before ABOUT):

```swift
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
```

- [ ] **Step 2: Add the sheet + helpers**

Attach the sheet to the `List` (or the `ZStack`), alongside the existing `.onAppear`:

```swift
.sheet(item: $newToken) { created in
    NewTokenSheet(command: MCPSetup.claudeCommand(serverURL: env.serverURL, token: created.token),
                  token: created.token)
}
.task { await loadTokens() }
```

Add these methods to `SettingsView`:

```swift
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
```

- [ ] **Step 3: Add the `NewTokenSheet` view** (same file, private struct)

```swift
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
```

- [ ] **Step 4: Build — verify success**

Run: `xcodebuild -project ios/Wythin.xcodeproj -scheme Wythin -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ios/Wythin/UI/Settings/SettingsView.swift
git commit -m "feat(api-access): Settings section to create/copy/revoke Claude Code tokens"
```

---

## Self-Review notes

- **Spec coverage:** create → once-shown token + full `claude mcp add` command (T2 sheet); list + revoke (T2); client methods + models + pure command helper with unit tests (T1). No server change; no new files (no pbxproj edit).
- **Security:** token minted with `env.userID` (the user's identity); the raw token appears only in the create response/sheet, never persisted, never re-listed.
- **Consistency:** `TokenCreated`/`TokenInfo` CodingKeys match the server (`created_at`, `last_used_at`); UI uses the file's existing Theme + `List`/`Section` patterns.
- **Env note:** iOS unit tests need a simulator; if `xcodebuild test` can't run in this environment, `build` is the hard gate and the unit tests run in CI (`ios.yml`).
