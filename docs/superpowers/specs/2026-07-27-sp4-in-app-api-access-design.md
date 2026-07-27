# SP4 — In-app "Claude Code Access" screen — Design

**Goal:** Let a signed-in user self-serve a personal access token from the app's Settings and get a ready-to-paste `claude mcp add` command — without ever handling the shared API key — so they can connect Claude Code to their own data.

**Status:** Approved decisions — a section in `SettingsView`; on create, show the token AND the full `claude mcp add` command; list existing tokens with revoke.

**Depends on:** SP1 (`/v1/tokens` create/list/revoke) + SP3 (the `/mcp` endpoint), both live in production.

**Scope:** iOS app only. No server change.

---

## How "only their data" is guaranteed (recap)

The **token is the identity**. `env.userID` (a stable per-install UUID in `UserDefaults`) is sent as `X-User-ID`; the server binds each minted token to that one `user_id` (SP1). Every MCP tool / API query resolves the token → its `user_id` and filters strictly by it — no endpoint takes a user_id argument (verified live: bogus token rejected, scoped reads only). So a token minted in this user's app can only ever read this user's rows. The token is a secret: shown once, copyable, revocable.

**Known model limitation (out of scope, noted):** identity is a per-install device UUID + the app's shared `X-API-Key`, not an authenticated account. Isolation between users holds via tokens; stronger "this is provably you" would require account auth (e.g. Apple Sign-In) — a separate future sub-project.

## API client (`server/../ios/Wythin/Sync/APIClient.swift`)

Add three methods that reuse the existing `request(path:method:)` helper (which sets `Content-Type` + `X-API-Key`) and add the `X-User-ID` header, mirroring `uploadSession`:

```swift
func createToken(name: String, userID: String) async throws -> TokenCreated
func listTokens(userID: String) async throws -> [TokenInfo]
func revokeToken(id: String, userID: String) async throws
```

Response models (Codable, snake_case via CodingKeys — matching the server):

```swift
struct TokenCreated: Codable { let token: String; let id: String; let name: String?; let createdAt: String }   // created_at
struct TokenInfo: Codable { let id: String; let name: String?; let createdAt: String; let lastUsedAt: String? } // created_at, last_used_at
```

`createToken` POSTs `{"name": name}`; `listTokens` GETs; `revokeToken` DELETEs `/v1/tokens/{id}`. All send `X-User-ID = userID`.

## The command string (unit-testable, pure)

A pure helper so it can be unit-tested and reused:

```swift
enum MCPSetup {
    /// The exact `claude mcp add` command for a freshly minted token.
    static func claudeCommand(serverURL: URL, token: String) -> String {
        "claude mcp add --transport http wythin \(serverURL.absoluteString)/mcp "
        + "--header \"Authorization: Bearer \(token)\""
    }
}
```

## SettingsView — new "CLAUDE CODE ACCESS" section

Placed after SERVER SYNC. Contents:
- One explanatory line: "Create a token to access your own data from Claude Code. Your token is private — anyone with it can read your data."
- A **Create Access Token** button → calls `createToken(name:userID:)` with an auto-generated name (`UIDevice.current.name` + short date), then presents the **new-token sheet**.
- A list of the user's existing tokens (from `listTokens`), each row: name · "created <date>" · "last used <date|never>", with a **Revoke** swipe action (confirmation) → `revokeToken`, then refresh the list.
- The list loads on appear via `.task` and after create/revoke.

**New-token sheet** (shown once per creation):
- A "Save this now — it won't be shown again" warning.
- The raw token in a monospaced, selectable field + a **Copy token** button (`UIPasteboard.general.string`).
- The full `MCPSetup.claudeCommand(...)` in a monospaced block + a **Copy command** button.
- A Done button.

State: `@State private var tokens: [TokenInfo]`, `@State private var newToken: TokenCreated?` (drives the sheet), `@State private var isWorking`, `@State private var error`. Uses `env.userID` and `env.serverURL`.

## How it works (end-to-end)

1. User opens Settings → CLAUDE CODE ACCESS → Create Access Token.
2. App calls `POST /v1/tokens` with its `X-User-ID` (env.userID) + shared key → server mints a `wyth_pat_` token bound to that user.
3. Sheet shows the token + the `claude mcp add …` command; user copies the command.
4. User pastes it into Claude Code; every MCP request carries the token; the server scopes all data to that user.
5. User can revoke anytime from the list.

## Testing

- **Unit (WythinTests):** `MCPSetup.claudeCommand` produces the exact expected string for a sample URL+token; `TokenCreated`/`TokenInfo` decode from representative server JSON (including `created_at`/`last_used_at` mapping and null `name`/`last_used_at`).
- **Build:** `xcodebuild … build` succeeds (the new file must be added to the Wythin target in `project.pbxproj`).
- Manual: create a token in Settings, copy the command, run it against the live server, confirm Claude Code connects and `whoami` returns this user.

## Out of scope

- Account auth / Apple Sign-In (the identity-model hardening) — noted as a future option.
- Any server change (SP1 endpoints already exist).
- Rich data tools (SP5).
