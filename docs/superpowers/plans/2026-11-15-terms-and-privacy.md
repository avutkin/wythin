# Terms and privacy implementation plan

> Execute inline with superpowers:executing-plans. Legal source research uses the deep-research workflow.

**Goal:** Require affirmative acceptance of linked, readable Terms before onboarding or app services start, while keeping contract acceptance distinct from health-data permissions.

**Architecture:** Versioned local acceptance receipt, bundled HTML documents with public counterparts, a root application gate before AppEnvironment creation, and an append-only server receipt alongside the profile. Existing archive infrastructure remains disabled until its release gates pass.

**Tech stack:** SwiftUI, WebKit local documents, UserDefaults, FastAPI/Pydantic, PostgreSQL, static GitHub Pages.

**Spec:** User requirements in this conversation and `../specs/2026-11-15-full-signal-archive.md`; current primary-source legal findings in `research_notes/Условия Wythin для США/`.

## Constraints and resolved decisions

- One required contract checkbox, unchecked initially. Declining does not enter onboarding or create AppEnvironment.
- Terms must be readable before acceptance and from Settings, including offline; publish from the existing GitHub Pages `/docs` source only after release review.
- General Terms acceptance is not health-data consent. Do not turn raw/team/AI permissions on as a side effect of accepting Terms. New cloud/team/AI choices start off; preserve existing explicit refusals.
- The legal draft cannot certify all-state compliance or invent operator details, vendor contracts, security controls, backup deletion, or validated medical capabilities.
- No deployment or activation while authentication, coach-access enforcement, vendor agreements, deletion lifecycle, operator identity and legal review remain unresolved.
- Do not change the shared checkout. Do not merge or ship unreviewed drafts.

## Tasks

- [x] Research current California, consumer-health state, federal and Apple rules; draft Terms, Privacy Policy, distinct Consumer Health Data Privacy Policy and a launch assessment.
- [x] Add failing client tests for unchecked/missing/stale acceptance, receipt stability, missing-document failure, and no automatic data permissions; implement local gate and document reader.
- [x] Add failing server tests for receipt persistence, retries, legacy omission and invalid receipts; implement additive schema and profile upload fields without granting data consent.
- [x] Remove the late mandatory raw-archive onboarding step; add legal links and accurate choice copy in Settings. Keep raw feature rollout disabled.
- [x] Verify common bundle/Pages source, targeted tests, full server/iOS suites, and fresh review; fix cloud transport bypasses, receipt-cache invalidation and client-clock failure. Public publication remains gated.
- [x] Update the existing draft PR and runbook with exact remaining provisioning blockers. Primary storage is purchased and the approved project-wide S3 key is generated; secure transfer and backup SSH access await their pending approvals. No production activation.

## Review focus

- Acceptance with unreadable or changed documents must not silently pass.
- Reopening the app must not collect/upload before the mandatory contract gate.
- Legacy profile uploads must not erase or fabricate acceptance receipts.
- Contract acceptance must not reverse opt-outs or be presented as consent to AI/coaching/research.
- Draft policies must not promise controls the current server does not implement.
