# Wellder

An iPhone and Apple Watch app for checking on older adults who live alone, with their consent.

- **Alpha:** the person being looked after. They share chosen information (heart rate from Apple
  Watch, location, activity) and get a big **Get help** button, an **I'm okay** check-in, and a
  possible-fall prompt.
- **Beta:** a family member or friend the Alpha has approved. They see a dashboard, movement
  history, heart-rate charts and alerts, and acknowledge them.

> Wellder is not a medical device or an emergency service. It can miss emergencies: phones
> get left behind, batteries die, iOS limits background work, and Apple Watch measures heart rate
> periodically, not continuously. Fall detection here is **experimental**. See
> [docs/feasibility.md](docs/feasibility.md) for exactly what Apple's APIs allow.

## Status

| Area | State |
|---|---|
| Backend API, auth, pairing, permissions, telemetry, alerts, escalation, retention, deletion | ✅ Implemented; 36 automated tests (unit, storage contract, end-to-end HTTP) |
| AWS infrastructure (CDK) | ✅ Dev stack deployed to us-east-2 (2026-10-24) and smoke-tested; full device sign-in not yet verified |
| Shared Swift package (models, schedule, outbox, fall detector, networking, auth) | ✅ 39 tests, including decoding real backend responses |
| iOS app (Alpha + Beta) | ✅ Builds (Swift 6); 4 unit tests + an end-to-end UI test against a real local backend pass |
| watchOS app | 🟡 Code type-checks against the watchOS SDK. A full build needs the watchOS platform runtime installed in Xcode |
| Real sensors (HealthKit, Core Location, Core Motion) | 🟡 Implemented; needs a physical iPhone + Apple Watch to verify (simulator has no sensors) |
| Push (APNs), SMS/voice (Twilio) | 🟡 Implemented behind interfaces; need credentials. SMS/voice off by default |
| Apple Watch system Fall Detection | 🔒 Implemented; needs Apple to grant the Fall Detection entitlement |

Feasibility details: [docs/feasibility.md](docs/feasibility.md).

## Quick start (no AWS, no Apple Watch needed)

Requirements: Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), Node.js ≥ 22.18.

```bash
cd Wellder   # the repository root

# 1. Backend, locally (in-memory store; notifications are recorded, never sent)
cd backend && npm ci && npm run dev          # http://127.0.0.1:8787
cd ..

# 2. A simulated Alpha with history, paired to a Beta (second terminal)
node simulations/simulate-alpha.ts setup      # prints the Beta's sign-in
node simulations/simulate-alpha.ts stream     # live synthetic telemetry every 15 s
node simulations/simulate-alpha.ts help       # or: high-hr, low-hr, fall-no-response, fall-ok,
                                              #     inactivity, connectivity-failure, history

# 3. The app
xcodegen generate
./scripts/nowatch-project.sh                  # only if the watchOS platform isn't installed
open WellderNoWatch.xcodeproj               # or Wellder.xcodeproj
```
Run in the iOS Simulator and sign in with the Beta credentials from step 2 to see the dashboard
update. To try the Alpha side, create a new account and switch on **Use simulated sensors** during
onboarding. Simulation is labelled everywhere, and simulated alerts never send texts or calls.

On a physical iPhone, run the backend with `HOST=0.0.0.0 npm run dev` and set your Mac's LAN
address in `Config/Overrides.xcconfig` (see `Config/Overrides.xcconfig.example`).

## Tests

```bash
cd backend && npm test && npm run typecheck   # 36 tests: domain, storage contract, end-to-end HTTP
cd backend && npm run synth                   # CDK synthesis + Lambda bundling (no AWS calls)
cd packages/WellderKit && swift test        # 39 tests
./scripts/run-ui-tests.sh "iPhone 17"         # starts a backend, runs app unit + end-to-end UI tests
```
Optional DynamoDB Local (Docker): `cd backend && npm run ddb:up && npm run test:dynamo` runs the
storage contract tests against the real DynamoDB adapter too.

After changing a backend response type, regenerate the Swift contract fixtures with
`node simulations/generate-fixtures.ts`.

## Documentation
- [docs/architecture.md](docs/architecture.md): system design, decisions and trade-offs, data model, alert lifecycle
- [docs/feasibility.md](docs/feasibility.md): Apple API feasibility matrix
- [docs/api.md](docs/api.md): HTTP API
- [docs/security.md](docs/security.md): security controls, threat model, privacy and regulatory notes (HIPAA, FTC HBNR, state laws)
- [docs/deployment.md](docs/deployment.md): AWS deployment, APNs, Twilio, Apple capabilities and entitlements

Minimum deployment targets: **iOS 18.0, watchOS 11.0** (built with the iOS/watchOS 26.5 SDKs).
Backend: Node.js 22 on AWS Lambda (arm64).
