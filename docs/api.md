# API reference (v1)

Base URL: the `ApiUrl` stack output (AWS) or `http://127.0.0.1:8787` (local). All bodies are JSON.
Timestamps are ISO-8601 **with an explicit offset** (`…Z`); the server rejects ambiguous ones.

**Auth:** `Authorization: Bearer <Cognito ID token>`. API Gateway's JWT authorizer verifies it.
The user ID is always the token's `sub` and is never taken from a request. Locally, tokens come
from `/dev/auth/*` (not deployed to AWS).

**Errors:** `{ "error": { "code": "...", "message": "..." } }` with status 400 (validation),
401, 403 (not allowed **or** doesn't exist, deliberately indistinguishable), 404, 409
(conflict / stale version), 413, 429, 500. Messages never echo submitted values.

The authoritative wire types are `backend/src/domain/types.ts`, mirrored in
`packages/WellderKit/Sources/SharedModels`. `Tests/SharedModelsTests/Fixtures/*.json` are real
responses (regenerate with `node simulations/generate-fixtures.ts`).

## Account and devices
| Method | Path | Who | Notes |
|---|---|---|---|
| GET | `/v1/me` | any | `{ profile \| null }`. `null` means onboarding is needed. |
| PUT | `/v1/me` | any | `{ name, phoneNumber?, roles: ["alpha"\|"beta"], timeZone }`. Creates default settings for Alphas. Removing the Alpha role requires no linked caregivers. |
| DELETE | `/v1/me` | any | Deletes profile, settings, devices, telemetry, alerts, audit and relationships. The app then deletes the Cognito user. |
| PUT | `/v1/devices/{deviceId}` | any | `{ deviceType, appVersion, capabilities, monitoringState, apnsToken?, apnsEnvironment?, batteryLevel?, model?, osVersion? }` |

## Pairing and permissions
| Method | Path | Who | Notes |
|---|---|---|---|
| POST | `/v1/invitations` | Alpha | `{ permissions? }` → `{ invitation, code, link }`. Code shown once; 24 h; single use; max 10 open. |
| GET | `/v1/invitations` | Alpha | open invitations (code hint only) |
| DELETE | `/v1/invitations/{invitationId}` | Alpha | cancel |
| POST | `/v1/invitations/redeem` | Beta | `{ code }` → relationship `pendingAlphaApproval`. 10 attempts per hour. |
| GET | `/v1/relationships` | any | `{ asAlpha: [...], asBeta: [...] }` |
| POST | `/v1/relationships/{alphaId.betaId}/approve` | Alpha | `{ permissions? }` → `active` |
| POST | `/v1/relationships/{id}/reject` | Alpha | → `rejected` |
| POST | `/v1/relationships/{id}/revoke` | Alpha or Beta | → `revoked` (immediate) |
| PUT | `/v1/relationships/{id}/permissions` | Alpha | `{ permissions: { viewLocation, viewMovementHistory, viewHeartRate, viewActivity, receiveAlerts, manageSettings, manageEmergencyContacts } }` (partial) |

## Telemetry (Alpha devices)
`POST /v1/telemetry`
```json
{
  "deviceId": "…",
  "samples": [
    { "kind": "heartRate", "sampleId": "uuid", "timestamp": "2026-05-04T13:50:00.000Z", "bpm": 72, "sourceDevice": "Apple Watch" },
    { "kind": "location", "sampleId": "…", "timestamp": "…", "latitude": 41.88, "longitude": -87.63, "horizontalAccuracy": 15, "source": "standard|significantChange|visit" },
    { "kind": "activity", "sampleId": "…", "timestamp": "…", "activityType": "stationary|walking|running|cycling|automotive|unknown", "confidence": "low|medium|high" },
    { "kind": "steps", "sampleId": "…", "timestamp": "…", "endTimestamp": "…", "count": 412 },
    { "kind": "interaction", "sampleId": "…", "timestamp": "…", "source": "app|checkIn|watchApp" }
  ],
  "events": [
    { "eventId": "uuid", "type": "fallCandidate", "detectedAt": "…", "confidence": 0.8, "countdownSeconds": 60 },
    { "eventId": "uuid", "type": "fallUserOk|fallNeedHelp|fallNoResponse", "detectedAt": "…", "relatedEventId": "<fallCandidate eventId>" },
    { "eventId": "uuid", "type": "systemFallDetected", "detectedAt": "…", "details": { "resolution": "confirmed|dismissed|rejected|unresponsive" } },
    { "eventId": "uuid", "type": "manualHelpRequest|lowBattery|locationUnavailable", "detectedAt": "…" }
  ]
}
```
Up to 1,000 samples and 50 events. Timestamps must be within the last 8 days and no more than
5 minutes in the future. Any item may carry `"simulated": true`. Samples for data types the Alpha
turned off are dropped (counted in `dropped`).

Response: `{ accepted, dropped, eventsProcessed, eventsDuplicate, alerts: [{alertId, type, status, created}], settingsVersion, serverTime }`.

## Monitoring reads (Beta with an active relationship, or the Alpha themself)
| Method | Path | Permission | Notes |
|---|---|---|---|
| GET | `/v1/dashboard` | Beta role | `{ alphas: AlphaSummary[], pending: Relationship[] }`. Fields filtered by permission. Sorted red → yellow → gray → green. Marks in-app deliveries delivered. |
| GET | `/v1/alphas/{alphaId}/summary` | any active link | `{ summary }` |
| GET | `/v1/alphas/{alphaId}/locations?from&to` | viewLocation + viewMovementHistory | ≤ 31 days, ≤ 5,000 points, `cursor` for more |
| GET | `/v1/alphas/{alphaId}/heart-rate?from&to` | viewHeartRate | + `stats {min,max,count}` and thresholds |
| GET | `/v1/alphas/{alphaId}/activity?from&to` | viewActivity | activity, steps, interactions |
| GET | `/v1/alphas/{alphaId}/alerts?limit&cursor` | receiveAlerts | newest first |
| GET | `/v1/alphas/{alphaId}/alerts/{alertId}` | receiveAlerts | `{ alert, deliveries }` (a Beta sees only their own deliveries) |
| POST | `/v1/alphas/{alphaId}/alerts/{alertId}/acknowledge` | Beta + receiveAlerts | stops escalation |
| POST | `/v1/alphas/{alphaId}/alerts/{alertId}/resolve` | Beta + receiveAlerts, or Alpha | `{ resolution: "betaResolved"\|"falseAlarm" }` |

`AlphaSummary.status`: `red` = unacknowledged critical safety alert; `yellow` = other open
alert; `gray` = no data or older than `staleAfterMinutes`; `green` = none of those. Green is
**not** a statement that the person is safe.

## Settings and consent
| Method | Path | Who | Notes |
|---|---|---|---|
| GET | `/v1/alphas/{alphaId}/settings` | Alpha or any active Beta | emergency contacts hidden without `manageEmergencyContacts` |
| PUT | `/v1/me/settings` | Alpha | `{ version, changes: { <section>: {...whole section} } }`. 409 if `version` is stale. |
| POST | `/v1/alphas/{alphaId}/settings-requests` | Beta with manageSettings / manageEmergencyContacts | `{ changes, reason? }`. Nothing applies until approved. |
| GET | `/v1/alphas/{alphaId}/settings-requests` | Alpha (all) or Beta (own) | |
| POST | `/v1/me/settings-requests/{id}/approve` · `/reject` | Alpha | permission re-checked at approval |
| GET | `/v1/me/audit` | Alpha | last 100 audit entries |

Sections: `sleepSchedule`, `heartRate`, `movement`, `fallDetection`, `notifications`,
`emergency` (`automaticEmergencyServices` must be `false`), `dataRetention`, `staleAfterMinutes`.
Validation ranges are in `backend/src/domain/settings.ts`.

## Local development only
`POST /dev/auth/register` and `POST /dev/auth/login` (`{ email, password }` → `{ userId, idToken, expiresAt }`), and `GET /health`.

### POST /v1/alphas/:alphaId/alerts/:alertId/respond
The monitored person's answer during an alert's false-alarm window (alerts in
`awaitingAlphaResponse`). Body: `{ "response": "ok" | "help" | "noResponse" }`. `ok` resolves the
alert as a false alarm (caregivers are never notified); `help` and `noResponse` notify caregivers
now. Only the Alpha may call it (403 otherwise). Heart-rate alerts and experimental fall
candidates start in this state; if no answer arrives, the server opens them itself after the
countdown plus 30 s.
