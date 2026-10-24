# Apple API feasibility matrix

What Apple's public APIs allow for each requested feature, and what Wellder actually does.
Status values: **Supported**, **Supported with limitations**, **Requires special entitlement or approval**,
**Requires additional hardware**, **Experimental**, **Not supported through public APIs**.

Researched October 2026 against the iOS/watchOS 26 SDKs (Xcode 26.6). Apple changes these
rules; re-check before relying on any row.

## Summary

| Feature | Status | What Wellder does |
|---|---|---|
| Current location, accuracy, timestamp | Supported | Core Location `CLLocationManager`; every sample carries measurement time and `horizontalAccuracy`. |
| Background location | Supported with limitations | "Always" permission + `location` background mode. Standard updates (100 m / 50 m filter, auto-pause) + significant-change + visits. iOS pauses or suspends updates, and a force-quit app returns only on significant-change or visit events. |
| Continuous precise GPS in every state | Not supported through public APIs | Not attempted. The UI shows the last known location with its age and accuracy. |
| Location history and map trail | Supported | Stored server-side (TTL retention). MapKit `MapPolyline` per continuous segment. |
| Gaps in location data | Supported | Gaps over 15 min break the line and are listed. Nothing is interpolated. |
| Room-level indoor position | Requires additional hardware | Not implemented (GPS cannot do it). Options: BLE beacons, UWB anchors (Nearby Interaction), HomeKit sensors. See *Indoor movement*. |
| Indoor activity estimate (moving, stationary, steps, inactivity) | Supported with limitations | `CMMotionActivityManager` + `CMPedometer` history (about 7 days, read on every wake). Only reflects movement while the phone is carried. |
| Latest heart rate + history | Supported with limitations | HealthKit `HKAnchoredObjectQuery` on iPhone. Watch readings sync to iPhone with a delay. |
| Background heart-rate updates | Supported with limitations | `HKObserverQuery` + `enableBackgroundDelivery(.immediate)` + background-delivery entitlement. Delivery is best-effort; minutes to about an hour is commonly reported. |
| Continuous real-time heart rate | Only during a workout session | **Opt-in "Live heart rate" on the watch** (added at the user's request): runs an `HKWorkoutSession` (`.other`, discarded, not saved to Fitness) so HealthKit records a reading every few seconds; the watch shows it and uploads at most one per 5 s, batched every 15 s. Costs: battery (hours, not a day), the workout indicator, and App Review may reject a workout used this way. |
| Heart-rate thresholds and alerts | Supported | Evaluated server-side with a persistence window and cooldown. Labelled with the measurement time. |
| Screen Time / device activity (FamilyControls, DeviceActivity) | Requires special entitlement or approval, *and* cannot share the data | Not used. Report data stays inside a sandboxed extension that cannot make network requests. Distribution needs Apple's Family Controls entitlement. **Alternative:** "Last opened Wellder" and "I'm okay" check-ins, clearly labelled. |
| Apple Watch system Fall Detection events | Requires special entitlement or approval | `CMFallDetectionManager` is integrated in the watch app. It only works after Apple grants the Fall Detection entitlement (Account Holder applies). Reports the watchOS prompt resolution. |
| Custom fall detection (iPhone) | Experimental | Threshold pipeline (free-fall, impact, orientation, stillness) on 50 Hz device motion. Runs only while the app is in the foreground. Not validated. |
| Custom background fall detection (watch) | Not supported through public APIs (without misuse) | Background motion sampling needs a workout session (misuse) or is retrospective only (`CMSensorRecorder`, see roadmap). |
| "Are you okay?" prompt + countdown + escalation | Supported | In-app full-screen prompt + time-sensitive local notification with actions. The server runs its own dead-man timer. |
| Night monitoring schedule | Supported | Wall-clock schedule in the Alpha's time zone. Handles DST, overnight windows and overrides. Location switches to low power. |
| Continuous night-time pulse | Not supported through public APIs | Heart rate continues only as Apple Watch records it (Sleep Focus / background cadence). |
| Push notifications (APNs) | Supported (paid developer account) | Token-based APNs over HTTP/2. "Accepted by APNs" is recorded as *sent*, never as *delivered*. |
| Time-sensitive notifications | Supported | Entitlement included (no approval needed). |
| Critical alerts (bypass Silent / Do Not Disturb) | Requires special entitlement or approval | Not requested. The payload supports `critical`; enable only after Apple approval. |
| SMS / automated calls | Supported via external provider (paid) | Twilio provider implemented, **disabled by default**. Requires deploy-time opt-in plus credentials. |
| Automatic emergency services (911) | Not supported through public APIs | Not implemented and blocked server-side. Manual "Call 911" uses the system dialer. See *Emergency services*. |
| Manual emergency call | Supported | `tel://` (iPhone) and `openSystemURL` (watch). The system asks for confirmation. |
| Watch ↔ phone sync | Supported with limitations | WatchConnectivity: application context, `transferUserInfo` (queued) and `sendMessage` (when reachable). Direct upload fallback from the watch. |
| Offline queueing and later upload | Supported | Persistent outbox (file protection: until first unlock), idempotent server ingestion. |
| Background refresh | Supported with limitations | `BGAppRefreshTask`. iOS decides when it runs (often hours apart; it doesn't run after force-quit). |
| Low battery reporting | Supported with limitations | iPhone battery read on wakes. The watch's battery is not reported (no reliable cross-device API). |
| Sign in | Supported | Amazon Cognito Hosted UI with OAuth code + PKCE via `ASWebAuthenticationSession`. Sign in with Apple can be added as a Cognito IdP. |

## Details

### Location
- **What works:** `startUpdatingLocation` with `allowsBackgroundLocationUpdates` (needs "Always"
  and the `location` background mode) keeps delivering while the app is suspended. iOS pauses
  updates when the device is stationary (`pausesLocationUpdatesAutomatically`). Significant-change
  monitoring (~500 m, cell/Wi-Fi) and visit monitoring can **relaunch a terminated app**, which is
  the only way back after the user force-quits.
- **What doesn't:** guaranteed periodic GPS fixes. iOS may grant only "While Using" (the
  Always upgrade prompt is shown at the system's discretion) and may reduce accuracy if the user
  turns off *Precise Location*.
- **Battery:** 100 m accuracy, 50 m distance filter, auto-pause; night/low-power mode drops to
  significant-change and visits only. The blue background-location indicator is left on so the
  Alpha can always see that sharing is active.

### Indoor movement
GPS/Wi-Fi location is not room-accurate. Wellder reports **activity** instead: moving or
stationary, walking/running/automotive classification with confidence, steps in 30-minute
buckets, time since last movement, and time since last app interaction. These come from the
motion coprocessor's history, so they don't require the app to run continuously. Room-level
positioning would need extra hardware, documented here and not built:
- **BLE beacons** per room + `CLBeaconIdentityConstraint` ranging (foreground or region
  monitoring; coarse, about 1–3 m).
- **UWB anchors** (third-party Nearby Interaction accessories) for sub-metre accuracy. Needs
  compatible accessories and an active `NISession`.
- **HomeKit motion/contact sensors** (`HMHome`). Reading sensor state needs the Home app setup and
  the app in the foreground.

### Heart rate
Apple Watch records heart rate in the background periodically: roughly every few minutes when
still, less when moving, more during workouts. Readings sync to the iPhone's HealthKit store
with delay, so the iPhone app uses an **anchored query** (new samples since the last anchor, even
with older timestamps) rather than a time window. `HKObserverQuery` with background delivery
wakes the app when new samples arrive. Apple documents the frequency only as a ceiling, and
developers report anything from minutes to about an hour. The app shows *"Measured 12 min ago"*,
never "live", and the dashboard downgrades stale readings.

Workout sessions (`HKWorkoutSession`) give continuous HR and keep a watch app running, but
using them for anything other than an actual workout violates App Review guideline 2.5.4 and
drains the battery. **Not used.**

### Screen Time / device activity
`FamilyControls` supports `.individual` authorization (an adult authorizing their own device),
but `DeviceActivityReport` runs in a sandboxed extension that cannot make network requests or
export data, by design. `DeviceActivityMonitor` threshold callbacks can't reliably convey usage
off-device either. Shipping either requires Apple's Family Controls (Distribution) entitlement,
intended for parental controls. **Not used.** Wellder instead shows **"Last opened
Wellder"** and **"I'm okay" check-ins**, and labels them so nobody mistakes them for general
phone use.

### Fall detection
1. **Apple Watch Fall Detection via `CMFallDetectionManager`** (watchOS 7.2+): the system detects
   the fall and runs its own prompt/SOS flow. Third-party apps get the event and its resolution
   (`confirmed`, `dismissed`, `rejected`, `unresponsive`), even in the background. It requires the
   **Fall Detection entitlement from Apple** (Account Holder request) and
   `NSFallDetectionUsageDescription`. Delivery can be delayed (developers report minutes). Integrated in
   `watchos/WellderWatch/WatchModel.swift`; without the entitlement, the capability reports as
   unavailable and nothing else breaks.
2. **Experimental custom detector** (`MonitoringCore/FallDetection`): free-fall (<0.5 g for
   ≥60 ms), impact (>2.5 g), orientation change (≥45°), post-impact stillness. It produces a
   heuristic confidence (not a probability). **Only runs while Wellder is open in the
   foreground on iPhone**, because iOS doesn't deliver device motion to suspended apps.
   Known false positive: a dropped phone (kept as a unit test). Known misses: slow slides, falls
   while the phone is not carried.
3. **Validation required before calling it anything but experimental:** recorded datasets of
   real falls and activities of daily living (e.g. SisFall, FARSEEING), sensitivity/specificity
   per device placement, and clinical review. Possibly regulatory review if marketed as a medical
   function (see `security.md`).

Every candidate goes through **"Possible fall detected. Are you okay?"** with a configurable
countdown. *I'm okay* resolves it silently. *I need help* or no answer alerts caregivers, and the
message says that no answer does **not** confirm an injury. The backend starts its own timer when
the candidate arrives. If the device dies mid-countdown, caregivers are still alerted after
countdown + 30 s.

### Emergency services
No public iOS API places emergency calls automatically, and generic telephony providers prohibit
emergency calling (Twilio's terms exclude it, and US regulation ties 911 to registered locations).
Wellder therefore:
- provides a **manual "Call 911"** button (system dialer, user confirms). The number is configurable.
- **rejects** `automaticEmergencyServices: true` in the API (`validateSettingsPatch`).
- relies on Apple's own **Emergency SOS / Fall Detection SOS**, which call emergency services natively.

A legitimate future integration would go through an emergency-data or monitoring provider:
RapidSOS (delivers data to 911 centres, needs a partnership and certification) or a UL-listed
PERS central monitoring station that dispatches services. Either needs contracts, location
verification and legal review.

### Notifications
APNs `200 OK` means *Apple accepted* the notification, not that the device displayed it.
Delivery records therefore say **sent**. **Delivered** is set only when a channel can confirm it:
in-app (the Beta's app fetched the alert), or provider callbacks (Twilio status callbacks, a
roadmap item). A Notification Service Extension could report display (roadmap).
