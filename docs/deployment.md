# Deployment

A **dev** stack (`AlphaBeta-dev`, us-east-2, Cognito domain prefix `alpha-beta-dev-berkgozek`) was
deployed on 2026-10-24. Deploying creates billable resources in
your account. Read the cost notes first.

## 1. Prerequisites
- AWS account + CLI credentials with permission to deploy CloudFormation/CDK
  (`aws sts get-caller-identity` must work; it currently does not on this machine).
- Node.js ≥ 22.18 (`backend/`: `npm ci`).
- Apple Developer Program membership (paid). Push notifications, HealthKit background delivery
  and time-sensitive notifications need it.

## 2. Deploy the backend
```bash
cd backend
npm ci
npx cdk bootstrap                                   # once per account/region
npx cdk deploy --app 'node infrastructure/bin/app.ts' \
  -c stage=dev \
  -c cognitoDomainPrefix=wellder-dev-<something-unique> \
  -c alarmEmail=you@example.com                     # optional
```
Outputs: `ApiUrl`, `UserPoolId`, `AppClientId`, `CognitoDomain`, `TableName`.

What gets created: DynamoDB table (on-demand, PITR, encrypted), Cognito user pool + app client +
domain, two Lambda functions (arm64, Node 22), HTTP API with JWT authorizer and throttling,
EventBridge rule (every minute), CloudWatch log groups and 3 alarms, and an SNS topic for alarms.
`stage=prod` turns on deletion protection and RETAIN policies for the table and user pool.

### Cost notes (us-east-1 list prices; check current pricing)
Idle cost is close to zero: on-demand DynamoDB, Lambda and API Gateway charge per request.
Fixed-ish costs: 3 CloudWatch alarms (~$0.30/month), Secrets Manager $0.40/secret/month once
you add APNs/Twilio secrets, and the sweeper (~43,800 invocations/month, inside the Lambda free
tier). Cognito's Essentials tier includes 10,000 monthly active users free. **SMS and voice are
billed by Twilio per message or minute and are off unless you enable them (step 4).**

## 3. Push notifications (APNs)
1. In the Apple Developer portal, create an **APNs Auth Key** (.p8). Note the Key ID and Team ID.
2. Store it in Secrets Manager (never in the repo):
   ```bash
   aws secretsmanager create-secret --name wellder/apns --secret-string \
     "$(jq -n --arg k "$(cat AuthKey_XXXX.p8)" '{teamId:"TEAMID",keyId:"KEYID",privateKey:$k,bundleId:"com.berkgozek.AlphaBeta"}')"
   ```
3. Redeploy with `-c apnsSecretArn=<full secret ARN>`. `PUSH_PROVIDER` becomes `apns`.
   Debug builds register with the **sandbox** APNs environment and Release with **production**;
   the device record carries which one.

## 4. SMS and voice (optional, billable)
1. Create a Twilio account and buy a number. Read Twilio's terms: **no emergency-services
   calling**.
2. `aws secretsmanager create-secret --name wellder/twilio --secret-string '{"accountSid":"AC…","authToken":"…","fromNumber":"+1…"}'`
3. Redeploy with `-c twilioSecretArn=<arn> -c smsProvider=twilio -c voiceProvider=twilio`.
4. Each Alpha must still turn on *Text messages* / *Phone calls* in their notification settings.
   Channels are used only for **critical safety** alerts, from escalation step 1 and 2, and never
   for simulated alerts.

## 5. Point the app at AWS
Create `Config/Overrides.xcconfig` (git-ignored) from the example:
```
AB_BACKEND_MODE = aws
AB_API_BASE_URL = https:/$()/<api-id>.execute-api.<region>.amazonaws.com
AB_COGNITO_DOMAIN = https:/$()/<prefix>.auth.<region>.amazoncognito.com
AB_COGNITO_CLIENT_ID = <AppClientId>
```
Then `xcodegen generate` and build. Sign-in then uses the Cognito Hosted UI (PKCE).

## 6. Apple capabilities and entitlements
| Capability | Where | Approval |
|---|---|---|
| HealthKit (+ background delivery) | iOS app entitlements | Standard (paid team) |
| Push Notifications (`aps-environment`) | iOS app | Standard (paid team) |
| Time-sensitive notifications | iOS app | Standard |
| Background modes: location, fetch, remote-notification | Info.plist | App Review justification |
| Location "Always" | Info.plist usage strings | App Review justification |
| **Fall Detection** (`CMFallDetectionManager`) | watch app | **Apple must grant it.** The Account Holder requests it at developer.apple.com/contact/request/fall-detection-api. Once granted, add the entitlement to the watch target **and** set `AB_FALL_DETECTION_ENTITLED = YES` in `Config/Overrides.xcconfig`. Without the entitlement, `CMFallDetectionManager` crashes the watch app at launch, so the app only creates it when that flag is YES. |
| **Critical Alerts** | iOS app | **Apple must grant it** (paid team; health/safety justification). Then add `com.apple.developer.usernotifications.critical-alerts` to the entitlements and set `AB_CRITICAL_ALERTS_ENTITLED = YES`: the app's alarm notifications become critical (red, ignore silent mode and Focus). |
| AlarmKit (iOS 26) | iOS app, `NSAlarmKitUsageDescription` | No capability needed; signs with the free team. The user allows it once. Used first for alarms (system alarm UI, breaks through silent/Focus); falls back to the in-app alarm. Can only be scheduled while the app runs, so the Beta needs the app open or "Overnight alarm" on. |
| Family Controls | not used | (would need Apple approval, and can't export data anyway) |

The entitlements file is chosen by `AB_ENTITLEMENTS` in `Config/Base.xcconfig`:
- **Default: `Wellder-PersonalTeam.entitlements`.** HealthKit plus background delivery, with no
  push and no time-sensitive notifications, because free personal teams can't sign those. This was
  verified: a signed device build with the free team gets a provisioning profile. Without push,
  Betas see new alerts through dashboard polling, and the Alpha's local notifications arrive at
  normal priority.
- **Paid team:** in `Config/Overrides.xcconfig`, set `AB_ENTITLEMENTS = ios/Wellder/Wellder.entitlements`
  to get the full set, and set your team's ID in `project.yml` (`DEVELOPMENT_TEAM`).

## 7. Building the apps
```bash
# from the repository root
xcodegen generate
open Wellder.xcodeproj
```
The **Wellder** scheme embeds the watch app. Xcode requires the **watchOS platform** to be
installed for that (Xcode › Settings › Components). Without it, run `scripts/nowatch-project.sh`
and use `WellderNoWatch.xcodeproj`, which is the same iOS app without the embedded watch app.

## 8. Operations
- Alarms: API errors, sweeper errors, and **sweeper not running** (escalations depend on it).
- Logs contain no health or location values. Use `alertId`/`alphaId` to trace.
- Data deletion is per user (`DELETE /v1/me`). Retention runs via DynamoDB TTL (deletion can lag up
  to a few days; reads hide expired items immediately).
- Teardown: `npx cdk destroy` (the dev stage deletes the table and user pool; the prod stage retains them).
