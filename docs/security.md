# Security and privacy

Wellder processes **location and health data about older adults**. The design assumes this
data is sensitive from the start. This document covers the controls, the threat model, and the
regulatory analysis. **It is not legal advice.** Get qualified counsel before launch.

## Data inventory
| Data | Source | Stored | Retention (default) |
|---|---|---|---|
| Name, email, phone | user / Cognito | DynamoDB | until account deletion |
| Heart rate (bpm, time) | HealthKit (Apple Watch) | DynamoDB | `telemetryDays` (30, 1–90) via TTL |
| Location (lat/lon/accuracy) | Core Location | DynamoDB | `locationHistoryRetentionDays` (30, 1–90) via TTL |
| Activity, steps, app interactions | Core Motion / app | DynamoDB | `telemetryDays` |
| Alerts + delivery records | backend | DynamoDB | `alertDays` (365) |
| Audit log | backend | DynamoDB | 1 year |
| APNs tokens | device | DynamoDB | until replaced or invalid |
| Auth tokens | Cognito | iOS Keychain (`AfterFirstUnlockThisDeviceOnly`) | session |
| Offline queue | device | app sandbox, file protection until first unlock | until uploaded |

Nothing is used for advertising or sold. HealthKit data is not written to iCloud
(App Store Review Guideline 5.1.3).

## Controls
**Authentication.** Cognito user pool: verified email, 10+ character passwords, optional TOTP
MFA, token revocation, 1 h ID/access tokens, 30-day refresh tokens. The native app uses
authorization code + PKCE with an ephemeral browser session. No passwords pass through our code.

**Authorization (server-side, every request).** Identity is only the verified `sub`. Every data
access goes through `authorizeAlphaAccess(userId, alphaId, permission)`: the caller is the
Alpha, or holds an **active** relationship with the needed permission. Relationship reads after a
GSI query are re-read from the base table (strongly consistent), so revocation is immediate.
Responses are field-filtered: heart rate, location, activity and emergency contacts are removed
without the matching permission, including inside alert evidence. "Doesn't exist" and "not
allowed" return the same 403 to prevent ID probing. Telemetry is always written to the caller's
own Alpha ID, whatever the body says. These cases are covered by `backend/tests/e2e.test.ts`
(*authorization enforcement*).

**Consent.** Single-use, expiring, hashed invitation codes, then explicit Alpha approval of
the named Beta, then per-permission grants that only the Alpha can change. Betas can only
*propose* settings, and permission is re-checked when the Alpha approves. Every change is
audit-logged and visible to the Alpha (Privacy tab). Either party can end a link instantly.

**Transport and storage.** TLS everywhere (API Gateway, APNs, Twilio, Cognito). The local dev
server is plain HTTP on localhost only (`NSAllowsLocalNetworking`). DynamoDB encryption at rest
(AWS-managed KMS key) and point-in-time recovery. Secrets (APNs .p8, Twilio) live in Secrets
Manager and are read at cold start. Nothing secret is in the repo or the app bundle (the Cognito
public client ID is not a secret).

**Least privilege.** Each Lambda role gets `grantReadWriteData` on the one table (+ its indexes)
and `grantRead` on the specific secrets, nothing else. API Gateway throttles at 50 rps / 100 burst
by default. Invitation redemption is limited to 10 attempts per user per hour (≈39-bit codes,
24 h validity).

**Input validation.** Hand-written validators on every field (types, ranges, lengths, enums,
E.164 phone numbers, IANA time zones, timestamps with explicit offset, bounded batch sizes,
512 KB body limit). Validation errors never echo the submitted value.

**Logging.** Structured logs contain only IDs, types and counts, never coordinates, bpm,
names, phone numbers or tokens (`backend/src/log.ts`). Log retention: 2 weeks dev / 3 months prod.

**Deletion.** `DELETE /v1/me` removes the account's partitions, telemetry, alerts, audit,
invitations and relationships (Betas' links are removed and recorded in the Alpha's audit). The
app also clears its local queue. TTL enforces retention automatically.

**Simulation safety.** Simulated data is flagged end to end. Simulated alerts are labelled and
can never trigger SMS or calls. The local server refuses to start with Twilio providers.

## Threat model (abridged)
| Threat | Mitigation |
|---|---|
| Stalker/abuser adds themselves as a caregiver | Alpha must approve the named person. The always-visible "Caregivers" list. Revocation at any time. Background-location indicator left on. |
| Brute-forcing invitation codes | 24 h single-use codes + per-user rate limit + Alpha approval step. |
| Beta escalates own permissions | Permissions writable only by the Alpha (server-checked). Requests need Alpha approval. |
| IDOR on `/alphas/{id}` | Relationship check on every request. Uniform 403. |
| Stolen phone (Alpha) | Keychain + file protection. Server-side revocation via Cognito global sign-out (roadmap: admin UI). |
| Token theft on the watch | Watch receives only a short-lived ID token (≤ 45 min) via WatchConnectivity. |
| Notification content on lock screen | Push bodies avoid exact values (no coordinates). Heart-rate alerts include bpm only to Betas with `viewHeartRate`. |
| Replay / duplicate events | Idempotency keys (sampleId / eventId). |
| Abuse of paid channels | Off by default. Deploy-time opt-in plus settings opt-in plus critical severity only, never for simulated alerts. |

## Regulatory analysis (not legal advice)
- **HIPAA** applies to *covered entities* (health plans, clearinghouses, providers who bill
  electronically) and their *business associates*. A consumer app that families download and
  use directly is generally **not** subject to HIPAA. It **would** apply if Wellder were
  offered by or on behalf of a provider or home-care agency. Then: a BAA with AWS (Lambda,
  DynamoDB, API Gateway, Cognito, CloudWatch, Secrets Manager, EventBridge are HIPAA-eligible)
  and with Twilio (BAA only for eligible products), plus the Security Rule's administrative
  safeguards.
- **FTC Health Breach Notification Rule** (amended 2024) *does* cover non-HIPAA health apps that
  draw health data from multiple sources (e.g. HealthKit plus location). A breach requires
  notification to users and the FTC. Plan an incident-response process.
- **State consumer-health-data laws:** Washington *My Health My Data Act* (opt-in consent for
  collecting and sharing consumer health data, right to delete; location data near health
  services is covered), Nevada SB 370, Connecticut, and California CCPA/CPRA (health and
  precise geolocation are *sensitive personal information*). The explicit, granular,
  revocable consent and deletion features are designed with these in mind.
- **GDPR/UK GDPR** (if offered in the EU/UK): health data is special-category. Explicit consent
  (Art. 9(2)(a)), a DPIA, an EU data residency decision, and DPAs with processors are needed.
- **Medical-device regulation:** marketing fall detection or heart-rate alerts as diagnosing or
  preventing a condition could make the software a medical device (FDA SaMD / EU MDR). The app is
  positioned as a general wellness and communication tool, labels detection as experimental and
  non-diagnostic, and states that it is not an emergency service.
- **App Store:** Guidelines 5.1.1 and 5.1.3 (health data: no ads or data mining, privacy policy
  required, no iCloud storage of HealthKit data). Location-in-background justification is needed in
  App Review notes. Critical Alerts and Fall Detection need separate Apple approval.
- **Emergency calling:** no automated 911 (see `feasibility.md`).

## Before production
Penetration test; privacy policy and in-app consent text reviewed by counsel; incident-response
runbook (FTC HBNR timelines); AWS WAF on the API if abuse appears; per-region data residency
decision; Cognito advanced security (adaptive auth, compromised-credential checks); MFA
prompts for Betas; dependency and secret scanning in CI.
