# Architecture

## System overview

```
 Alpha's iPhone ───────────────┐                         ┌──────────── Beta's iPhone
  HealthKit (watch HR via sync) │   HTTPS + Cognito JWT   │  Dashboard (polls 30 s in foreground)
  Core Motion history           │                         │  APNs push for alerts
  Core Location                 ▼                         ▲
  Outbox (offline queue) ──► API Gateway (HTTP API) ──► Lambda "api" ──► DynamoDB (single table, TTL)
         ▲                     JWT authorizer             │                 ▲
 Apple Watch ── WatchConnectivity (or direct HTTPS)       │                 │
                                                          ▼                 │
                                       EventBridge (1 min) ─► Lambda "sweeper"
                                          escalations · no-response fall timer · stale data · inactivity
                                                          │
                                         APNs (HTTP/2) · Twilio SMS/voice (disabled by default)
```

**One iOS app, both roles.** Users pick *Alpha* (monitored), *Beta* (caregiver) or both at
onboarding. The watch app serves the Alpha role. Shared logic lives in a Swift package
(`WellderKit`), so separate Alpha and Beta apps could be split out later without restructuring.

## Repository layout

```
Wellder/  (repository root)
├── project.yml               XcodeGen spec (iOS app, watch app, unit + UI tests)
├── Config/                   xcconfig per environment (no secrets; Overrides.xcconfig git-ignored)
├── ios/Wellder/              iOS app: App/ Auth/ Alpha/ Beta/ Sensors/ Shared/ Simulation/
├── ios/WellderTests/       app-target unit tests
├── ios/WellderUITests/     end-to-end UI test (real app + real local backend)
├── watchos/WellderWatch/   watchOS app
├── packages/WellderKit/    SharedModels · MonitoringCore · Networking · DesignSystem (+ tests)
├── backend/
│   ├── src/domain/           types, validation, schedule, heart-rate, permissions (pure)
│   ├── src/store/            Table interface · MemoryTable · DynamoTable · Repository
│   ├── src/services/         access control, account, relationships, telemetry, alerts, queries, sweeper
│   ├── src/notify/           APNs, Twilio, Recording*/Disabled* providers
│   ├── src/http/router.ts    transport-agnostic router (shared by Lambda and local server)
│   ├── src/lambda/           API Gateway and EventBridge handlers
│   ├── src/local/server.ts   local dev server
│   ├── tests/                domain, storage-contract and end-to-end HTTP tests
│   └── infrastructure/       AWS CDK app
├── simulations/              device simulator CLI, fixture generator
├── scripts/                  UI-test runner, watch-less project generator
└── docs/
```

## Key decisions

| Decision | Choice | Why / trade-off |
|---|---|---|
| Compute | API Gateway HTTP API + 2 Lambdas | No servers to operate. Scales to zero. HTTP API is cheaper and simpler than REST API and has a native JWT authorizer. One "fat" API Lambda with an internal router means fewer cold starts and one deployment unit. Split per route only if profiles diverge. |
| Database | DynamoDB single table | Access patterns are known and key-based (by Alpha, by Beta, by time range). On-demand billing at near-zero idle cost, TTL for retention, PITR, encryption at rest. **Relational (Aurora Serverless v2)** was considered for the many-to-many relationships, but there is exactly one join (Beta → Alphas), served by a GSI. Postgres would add a VPC, connection management and a minimum ACU cost. |
| Time-series telemetry | DynamoDB partitions per Alpha and kind, sorted by timestamp, with TTL | **Timestream for LiveAnalytics closed to new customers (20 June 2025)**. Timestream for InfluxDB is instance-based (always-on cost). Query patterns are simple range scans (≤ 31 days, ≤ 5,000 points), which DynamoDB serves well. Analytics or long-term archive would go to S3 via DynamoDB export (roadmap). |
| Dashboard sync | Polling (30 s, foreground only) + APNs for alerts | Caregivers need timely *alerts*, not sub-second telemetry. Telemetry itself arrives in bursts governed by iOS background limits. WebSockets (API Gateway WebSocket + connection table) would add complexity and cost for no real-world latency gain. Revisit for a live "currently viewing" mode. |
| Auth | Cognito user pool; Hosted UI with OAuth code + PKCE; ID token to API | Managed, MFA-capable, no password handling in our code. Native PKCE flow via `ASWebAuthenticationSession`, so no Amplify dependency. The local dev server issues HMAC tokens with the same claims. |
| Escalation timing | EventBridge 1-minute schedule + sparse GSI of due alerts | Simple and robust: one sweeper, no per-alert schedules to clean up. Resolution is ≤ 1 min. The alternative, EventBridge Scheduler one-shot schedules per alert, gives exact timing at the cost of more moving parts. |
| Push | Direct APNs (HTTP/2, token auth) | No SNS platform-application indirection. Lets us set `interruption-level` and threading. |
| SMS/voice | `SmsProvider` / `VoiceProvider` interfaces; Twilio implementation; disabled by default | Pinpoint SMS is now *AWS End User Messaging*. Either works. Twilio was chosen for voice + SMS in one API with status callbacks. Swapping providers means one class. |
| iOS persistence | File-backed outbox (actor) + UserDefaults for small state + Keychain for tokens | The outbox must be written during background wakes and tested on macOS. A Codable file under file protection "until first unlock" is simplest. **SwiftData** was not needed: there is no local query workload, and the server is the source of truth. |
| Swift concurrency | Swift 6 language mode everywhere | Strict data-race checking caught several real issues (HealthKit/Core Motion callbacks crossing actors). |
| Third-party deps | None on iOS. Backend: AWS SDK v3 only (+ CDK/TypeScript dev deps) | Smaller attack surface. Node 22 runs TypeScript directly (type stripping), so no build step for dev and tests. esbuild bundles for Lambda. |

## Data model

Single DynamoDB table `pk`/`sk` + two GSIs (all strings, projection ALL). Source of truth:
`backend/src/store/repository.ts`.

| Entity | pk | sk | GSI | Notes |
|---|---|---|---|---|
| User profile | `USER#<uid>` | `PROFILE` | | name, email (from token), phone, roles |
| Monitoring settings | `USER#<alpha>` | `SETTINGS` | | `version` for optimistic locking |
| Device | `USER#<uid>` | `DEVICE#<id>` | | APNs token, capabilities, state, battery, lastSeen |
| Snapshot | `USER#<alpha>` | `SNAPSHOT` | gsi2 `MONITOR#<shard>` / `<alpha>` | latest HR, location, activity; dashboard reads one item |
| Relationship | `ALPHA#<a>` | `REL#<b>` | gsi1 `BETA#<b>` / `REL#<a>` | permissions, status; GSI results re-read from base (strong consistency) |
| Invitation | `INVITE#<sha256(code)>` | `INVITE` | gsi1 `INVITES#<a>` / createdAt | code never stored; TTL 24 h; single use |
| Telemetry | `T#<a>#<kind>` | `<ISO ts>#<sampleId>` | | idempotent overwrite; TTL = retention (location separately) |
| Event marker | `ALPHA#<a>` | `EVENT#<eventId>` | | conditional put = exactly-once processing; TTL 30 d |
| Alert | `ALPHA#<a>` | `ALERT#<sortableId>` | gsi2 `ESCALATION#<shard>` / `<nextAt>#…` | sparse: indexed only while an escalation is pending |
| Active-alert lock | `ALPHA#<a>` | `ACTIVE#<type>` | | dedupe: one open alert per type |
| Cooldown | `ALPHA#<a>` | `COOLDOWN#<type>` | | TTL = end of cooldown (starts at resolution) |
| Delivery | `ALPHA#<a>` | `DELIVERY#<alert>#<id>` | | per Beta × channel × step |
| Settings request | `ALPHA#<a>` | `SCR#<id>` | | Beta proposals awaiting Alpha |
| Audit entry | `ALPHA#<a>` | `AUDIT#<id>` | | TTL 1 year |
| Rate limit | `RATE#<uid>#<action>#<window>` | `RATE` | | fixed window counter |

The spec's separate `AlphaProfile`/`BetaProfile` entities are folded into `UserProfile.roles`
(+ settings). `alphaId == userId`, which removes a whole class of ID-mismatch bugs. Hot GSI
partitions are write-sharded (`SHARDS = 4`); raise it as the number of Alphas grows.

## Alerts

### Lifecycle
```
                 (fall candidate)
 detected ──► awaitingAlphaResponse ──"I'm okay"──► resolved (alphaOk, nobody notified)
    │                 │ "I need help" / no answer / server timer (countdown + 30 s)
    ▼                 ▼
  open ───────────────┴──► acknowledged (escalation stops) ──► resolved
```
Every stage has its own timestamp: `detectedAt` (device), `receivedAt` (server),
`firstNotificationSentAt` (a provider accepted it), `firstDeliveryConfirmedAt` (only when
confirmable), `acknowledgedAt`, `resolvedAt`. One never implies another.

### Escalation (critical *safety* alerts only)
| Step | When | Channels |
|---|---|---|
| 0 | immediately | in-app + push to every Beta with `receiveAlerts` |
| 1 | + `escalationDelaySeconds` | push reminder + SMS (if enabled in settings **and** provider configured) |
| 2 | + another delay | push reminder + voice call (same conditions) |

Warnings (heart rate, inactivity) and technical alerts stop at step 0 to limit alarm fatigue.
Simulated alerts never use SMS or voice. Each step is **leased** (CAS on `version`) before sending,
so parallel sweepers don't double-send. If a worker dies mid-step, the lease expires and the step
re-runs (at-least-once, which is the safer failure mode for safety alerts).

### Deduplication and idempotency
- Samples: deterministic keys (`timestamp#sampleId`), so retries overwrite.
- Events: conditional `EVENT#<eventId>` marker, processed exactly once.
- Alerts: `ACTIVE#<type>` lock. Repeats increment `occurrences` on the open alert. Cooldown
  starts when the alert resolves.

### Safety alert types vs technical alerts
Safety: possible fall, help request, heart rate high/low, prolonged inactivity. Technical:
monitoring interrupted (no data for `staleAfterMinutes`), low battery, location unavailable.
**Missing data never produces "safe".** It produces a gray status and a *monitoring interrupted*
alert. Inactivity is only evaluated while data is flowing and outside the night window, and is
measured from the later of last movement, last interaction and today's wake time.

## Monitoring on device

Every wake (foreground, `BGAppRefreshTask`, HealthKit background delivery, significant
location change, watch event) runs `MonitoringPipeline.runCycle`:
1. Each `TelemetryCollector` reads `(cursor, now]`: HealthKit anchored query, Core Motion
   activity history, pedometer buckets (or the simulated collectors).
2. Samples go into the per-account **outbox** (persisted, de-duplicated, events never dropped).
3. Batches upload oldest-first. On failure everything stays queued for the next wake.
4. The response's `settingsVersion` triggers a settings refresh if it changed.

`MonitoringStateModel` derives the state shown to the Alpha and reported to the server:
`active`, `reduced`, `night`, `temporarilyDisconnected`, `permissionsUnavailable`, `dataStale`,
`disabled`.

Night mode (`NightSchedule`): local wall-clock window in the schedule's IANA time zone, which
handles DST, windows across midnight and manual overrides. The device schedules the next
transition. At night, location drops to significant-change/visits, inactivity alerts are
suppressed server-side, and help requests and fall prompts are unaffected (fall detection stays
on unless the Alpha turns `keepFallDetectionAtNight` off).

## Consent model

- A Beta sees nothing until the Alpha **approves the specific person** who redeemed a code.
  Codes are single-use, 24 h, stored only as SHA-256, and redemption is rate-limited.
- Permissions are per relationship (7 flags), editable only by the Alpha, and enforced
  server-side on every read (including field-level filtering of the snapshot and alert evidence).
- Betas *propose* settings changes (`manageSettings` / `manageEmergencyContacts`). They apply only
  on Alpha approval, and permission is re-checked at approval time.
- Revocation takes effect on the next request. Every sensitive change is in the Alpha's audit log.
