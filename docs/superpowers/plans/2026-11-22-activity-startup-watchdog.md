# Activity startup watchdog implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the symbolicated activity-backfill startup watchdog on builds 159/160.
**Architecture:** One environment-owned coordinator runs version migration and ongoing window repair sequentially on a detached worker. Settled windows remain settled when their stress value is legitimately absent.
**Tech Stack:** Swift, SwiftData, SwiftUI, XCTest.
**Spec:** docs/superpowers/specs/2026-11-22-activity-startup-watchdog-design.md

## Global constraints
- Preserve all stores, schemas, calculation formulas and version 11; no reset or forced migration.
- No heavy fetch/computation from launch or scene-phase main actor callbacks.
- One pending follow-up, own background ModelContext, six-entry progress saves.
- Use tools/ship.sh for TestFlight/device installation; existing release authorization applies.

## Review focus
- A settled imported workout with no Polar samples must not become perpetual launch work.
- Simultaneous content/foreground requests must not run migrations concurrently.
- A store failure must remain retryable without advancing uncommitted progress.
- Active activities and after-windows still filling must retain their existing semantics.
- Background persistence must not erase local activity edits or expose an empty replacement store.

### Task 1: Move activity maintenance out of startup UI work

**Files:** Create App/ActivityWindowMaintenance.swift and WythinTests/ActivityWindowMaintenanceTests.swift; modify Models/ActivityLog.swift, App/AppEnvironment.swift, App/WythinApp.swift and project.pbxproj.
**Consumes:** ModelContainer; ActivityLog.migrate(context:); ActivityLog.backfillMissingWindows(context:).
**Produces:** @MainActor ActivityWindowMaintenance(container:work:) with request() returning a shared Task<Void,Never>; AppEnvironment.refreshActivityWindows() schedules its owned coordinator.

- [ ] Write regression tests: a settled activity with nil duringStress does not need refresh; a slow maintenance job executes off the main thread and allows a main-actor heartbeat; repeated requests coalesce; a failed worker allows a later retry; real history is preserved and missing windows become durably settled.
- [ ] Run the focused tests and observe the old predicate and synchronous execution fail.
- [ ] Correct the predicate order; implement the detached/coalesced coordinator; route both ContentView and scene activation through it; save ongoing repair every six entries with no progress advance on save failure.
- [ ] Run focused activity tests and full WythinTests suite on simulator 13E49A03-B74A-4D83-80DF-994C88500356, absolute project path, normal signing. Require TEST SUCCEEDED and zero failures.
- [ ] Commit; obtain one independent whole-change review; address Important/Critical findings in one test-driven pass.
- [ ] Integrate main, ship TestFlight, verify external availability, and validate startup on the reachable physical iPhone through ship.sh phone if available. Record observed outcomes and remaining limits.
