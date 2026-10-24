import type { Principal } from '../auth/auth.ts';
import { badRequest } from '../domain/errors.ts';
import { evaluateHeartRate } from '../domain/heartRate.ts';
import { defaultSettings } from '../domain/settings.ts';
import type {
  ActivityType,
  Confidence,
  DeviceEvent,
  DeviceEventType,
  HeartRateSample,
  MonitorSnapshot,
  TelemetrySample,
} from '../domain/types.ts';
import { UUIDISH, arr, isoTimestamp, num, obj, oneOf, optBool, optNum, str, type Json } from '../domain/validation.ts';
import { requireProfile } from './access.ts';
import { AlertEngine } from './alerts.ts';
import type { Deps } from './deps.ts';

const MAX_SAMPLES = 1000;
const MAX_EVENTS = 50;
const MAX_AGE_MS = 8 * 24 * 3600_000; // Core Motion keeps ~7 days of history; allow late uploads
const MAX_CLOCK_SKEW_MS = 5 * 60_000;
const ACTIVITY_TYPES: ActivityType[] = ['stationary', 'walking', 'running', 'cycling', 'automotive', 'unknown'];
const CONFIDENCES: Confidence[] = ['low', 'medium', 'high'];
const MOVING: ActivityType[] = ['walking', 'running', 'cycling'];
const EVENT_TYPES: DeviceEventType[] = [
  'fallCandidate',
  'systemFallDetected',
  'fallUserOk',
  'fallNeedHelp',
  'fallNoResponse',
  'manualHelpRequest',
  'lowBattery',
  'locationUnavailable',
];

export interface IngestResult {
  accepted: number;
  dropped: number; // e.g. location samples while location sharing is off
  eventsProcessed: number;
  eventsDuplicate: number;
  alerts: { alertId: string; type: string; status: string; created: boolean }[];
  settingsVersion: number; // lets the device notice settings changes and re-fetch
  serverTime: string;
}

function parseSample(raw: unknown, i: number, bounds: { notBefore?: number; notAfter?: number }): TelemetrySample {
  const o = obj(raw, `samples[${i}]`);
  const base = {
    sampleId: str(o, 'sampleId', { max: 64, pattern: UUIDISH }),
    timestamp: isoTimestamp(o, 'timestamp', bounds),
    ...(optBool(o, 'simulated') ? { simulated: true } : {}),
  };
  const kind = oneOf(o, 'kind', ['heartRate', 'location', 'activity', 'steps', 'interaction'] as const);
  switch (kind) {
    case 'heartRate':
      return { ...base, kind, bpm: num(o, 'bpm', 20, 250), sourceDevice: str(o, 'sourceDevice', { max: 64 }) };
    case 'location':
      return {
        ...base,
        kind,
        latitude: num(o, 'latitude', -90, 90),
        longitude: num(o, 'longitude', -180, 180),
        horizontalAccuracy: num(o, 'horizontalAccuracy', 0, 50_000),
        source: oneOf(o, 'source', ['standard', 'significantChange', 'visit'] as const),
      };
    case 'activity':
      return { ...base, kind, activityType: oneOf(o, 'activityType', ACTIVITY_TYPES), confidence: oneOf(o, 'confidence', CONFIDENCES) };
    case 'steps': {
      const endTimestamp = isoTimestamp(o, 'endTimestamp', bounds);
      if (endTimestamp < base.timestamp) throw badRequest(`samples[${i}].endTimestamp precedes timestamp`);
      return { ...base, kind, count: num(o, 'count', 0, 100_000, { integer: true }), endTimestamp };
    }
    case 'interaction':
      return { ...base, kind, source: oneOf(o, 'source', ['app', 'checkIn', 'watchApp'] as const) };
  }
}

function parseEvent(raw: unknown, i: number, bounds: { notBefore: number; notAfter: number }): DeviceEvent {
  const o = obj(raw, `events[${i}]`);
  const details = o.details === undefined ? undefined : obj(o.details, 'details');
  if (details) {
    for (const [k, v] of Object.entries(details)) {
      if (k.length > 40 || !['string', 'number', 'boolean'].includes(typeof v) || (typeof v === 'string' && v.length > 200)) {
        throw badRequest(`events[${i}].details has an invalid entry`);
      }
    }
    if (Object.keys(details).length > 20) throw badRequest(`events[${i}].details has too many entries`);
  }
  const confidence = optNum(o, 'confidence', 0, 1);
  const countdownSeconds = optNum(o, 'countdownSeconds', 5, 600, { integer: true });
  const relatedEventId = o.relatedEventId === undefined ? undefined : str(o, 'relatedEventId', { max: 64, pattern: UUIDISH });
  return {
    eventId: str(o, 'eventId', { max: 64, pattern: UUIDISH }),
    type: oneOf(o, 'type', EVENT_TYPES),
    detectedAt: isoTimestamp(o, 'detectedAt', bounds),
    ...(relatedEventId ? { relatedEventId } : {}),
    ...(confidence !== undefined ? { confidence } : {}),
    ...(countdownSeconds !== undefined ? { countdownSeconds } : {}),
    ...(details ? { details: details as Record<string, string | number | boolean> } : {}),
    ...(optBool(o, 'simulated') ? { simulated: true } : {}),
  };
}

const newer = (a: string | undefined, b: string) => !a || b > a;

function updateSnapshot(prev: MonitorSnapshot, samples: TelemetrySample[], now: string, simulated: boolean): MonitorSnapshot {
  const s: MonitorSnapshot = { ...prev, lastSyncAt: now, ...(simulated ? { simulated: true } : {}) };
  for (const x of samples) {
    switch (x.kind) {
      case 'heartRate':
        if (newer(s.lastHeartRate?.timestamp, x.timestamp)) s.lastHeartRate = { bpm: x.bpm, timestamp: x.timestamp, sourceDevice: x.sourceDevice };
        break;
      case 'location':
        if (newer(s.lastLocation?.timestamp, x.timestamp)) {
          s.lastLocation = { latitude: x.latitude, longitude: x.longitude, horizontalAccuracy: x.horizontalAccuracy, timestamp: x.timestamp };
        }
        break;
      case 'activity':
        if (newer(s.lastActivity?.timestamp, x.timestamp)) s.lastActivity = { activityType: x.activityType, confidence: x.confidence, timestamp: x.timestamp };
        if (MOVING.includes(x.activityType) && x.confidence !== 'low' && newer(s.lastMovementAt, x.timestamp)) s.lastMovementAt = x.timestamp;
        break;
      case 'steps':
        if (x.count > 0 && newer(s.lastMovementAt, x.endTimestamp)) s.lastMovementAt = x.endTimestamp;
        if (newer(s.recentSteps?.to, x.endTimestamp)) s.recentSteps = { count: x.count, from: x.timestamp, to: x.endTimestamp };
        break;
      case 'interaction':
        if (newer(s.lastInteractionAt, x.timestamp)) s.lastInteractionAt = x.timestamp;
        break;
    }
  }
  return s;
}

export async function ingestTelemetry(deps: Deps, principal: Principal, body: unknown): Promise<IngestResult> {
  const alpha = await requireProfile(deps, principal.userId, 'alpha');
  const alphaId = alpha.userId; // never taken from the request body
  const now = deps.now();
  const bounds = { notBefore: now.getTime() - MAX_AGE_MS, notAfter: now.getTime() + MAX_CLOCK_SKEW_MS };
  const o: Json = obj(body);
  const deviceId = str(o, 'deviceId', { max: 64, pattern: UUIDISH });
  const rawSamples = arr(o, 'samples', MAX_SAMPLES, { optional: true });
  const rawEvents = arr(o, 'events', MAX_EVENTS, { optional: true });
  // Samples outside the accepted time window are dropped rather than failing the batch: one stale
  // reading (e.g. old Apple Health history) must not block everything queued behind it.
  const parsed = rawSamples.map((s, i) => parseSample(s, i, {}));
  const samples = parsed.filter((s) => {
    const t = Date.parse(s.timestamp);
    return t >= bounds.notBefore && t <= bounds.notAfter;
  });
  const events = rawEvents.map((e, i) => parseEvent(e, i, bounds));

  const settings = (await deps.repo.getSettings(alphaId)) ?? defaultSettings(alphaId, 'UTC', now);
  const allowed = samples.filter((s) => {
    if (s.kind === 'location') return settings.movement.locationEnabled;
    if (s.kind === 'heartRate') return settings.heartRate.enabled;
    if (s.kind === 'activity' || s.kind === 'steps') return settings.movement.enabled;
    return true;
  });
  await deps.repo.putSamples(alphaId, allowed, settings.dataRetention.telemetryDays, settings.movement.locationHistoryRetentionDays);

  const simulated = allowed.some((s) => s.simulated) || events.some((e) => e.simulated);
  const prevSnapshot = (await deps.repo.getSnapshot(alphaId)) ?? { alphaId };
  const snapshot = updateSnapshot(prevSnapshot, allowed, now.toISOString(), simulated);
  const device = await deps.repo.getDevice(alphaId, deviceId);
  if (device) {
    await deps.repo.putDevice({ ...device, lastSeen: now.toISOString() });
    snapshot.monitoringState = device.monitoringState;
    if (device.batteryLevel !== undefined) snapshot.batteryLevel = device.batteryLevel;
  }
  await deps.repo.putSnapshot(snapshot);

  const engine = new AlertEngine(deps);
  const alerts: IngestResult['alerts'] = [];
  const push = (r: Awaited<ReturnType<AlertEngine['raise']>>) => {
    if (r.alert) alerts.push({ alertId: r.alert.alertId, type: r.alert.type, status: r.alert.status, created: r.created });
  };

  // Conditions that cleared because data is flowing again.
  await engine.clearCondition(alphaId, 'monitoringInterrupted');
  if (snapshot.lastMovementAt !== prevSnapshot.lastMovementAt || snapshot.lastInteractionAt !== prevSnapshot.lastInteractionAt) {
    await engine.clearCondition(alphaId, 'prolongedInactivity');
  }

  // Heart rate: evaluate the recent window, including what was just stored. Every new reading is
  // checked as the end of a run, not only the newest: live heart rate arrives in 15 s batches, and
  // a spike that has already come down by the end of a batch still counts.
  // Heart-rate alerts are not auto-resolved when a normal reading follows: with readings every few
  // seconds they would close before any caregiver saw them. A caregiver acknowledges/resolves them.
  const hr = allowed.filter((s): s is HeartRateSample => s.kind === 'heartRate');
  if (hr.length > 0 && settings.heartRate.enabled) {
    const sortedNew = [...hr].sort((a, b) => Date.parse(a.timestamp) - Date.parse(b.timestamp));
    const newest = sortedNew[sortedNew.length - 1]!;
    const lookback = Math.max(settings.heartRate.persistenceSeconds * 2, 3600) * 1000;
    const windowStart = new Date(Date.parse(sortedNew[0]!.timestamp) - lookback).toISOString();
    const { samples: recent } = await deps.repo.querySamples(alphaId, 'heartRate', windowStart, newest.timestamp);
    let finding: ReturnType<typeof evaluateHeartRate> = null;
    for (const s of sortedNew) {
      const upTo = recent.filter((r) => r.timestamp <= s.timestamp);
      finding = evaluateHeartRate(upTo, settings.heartRate) ?? finding;
    }
    if (finding) {
      const high = finding.direction === 'high';
      push(
        await engine.raise({
          alphaId,
          type: high ? 'heartRateHigh' : 'heartRateLow',
          severity: 'warning',
          title: high ? 'Heart rate above threshold' : 'Heart rate below threshold',
          message: `${alpha.name}'s heart rate was ${high ? 'above' : 'below'} ${high ? settings.heartRate.upperBpm : settings.heartRate.lowerBpm} bpm in ${finding.readings} reading(s), most recently measured at ${finding.lastAbnormalAt}.`,
          detectedAt: finding.lastAbnormalAt,
          simulated: hr.some((s) => s.simulated),
          cooldownSeconds: settings.heartRate.cooldownSeconds,
          // False-alarm window: the Alpha's devices ring first; caregivers are told only if the
          // Alpha doesn't cancel (or the server's own timer runs out).
          awaitAlphaResponseSeconds: settings.fallDetection.confirmationCountdownSeconds,
          evidence: { extremeBpm: finding.extremeBpm, readings: finding.readings, firstAbnormalAt: finding.firstAbnormalAt, lastAbnormalAt: finding.lastAbnormalAt },
        }),
      );
    }
  }

  // Device events — each processed at most once.
  let eventsProcessed = 0;
  let eventsDuplicate = 0;
  for (const e of [...events].sort((a, b) => a.detectedAt.localeCompare(b.detectedAt))) {
    if (!(await deps.repo.markEventProcessed(alphaId, e, now.toISOString()))) {
      eventsDuplicate++;
      continue;
    }
    eventsProcessed++;
    const sim = e.simulated === true;
    const related = e.relatedEventId ? await deps.repo.getEvent(alphaId, e.relatedEventId) : undefined;
    switch (e.type) {
      case 'fallCandidate': {
        const r = await engine.raise({
          alphaId,
          type: 'possibleFall',
          severity: 'critical',
          title: 'Possible fall detected',
          message: `A possible fall was detected for ${alpha.name} (experimental detection). They are being asked if they are okay.`,
          detectedAt: e.detectedAt,
          simulated: sim,
          sourceEventId: e.eventId,
          awaitAlphaResponseSeconds: e.countdownSeconds ?? settings.fallDetection.confirmationCountdownSeconds,
          evidence: { detector: 'experimental', ...(e.confidence !== undefined ? { confidence: e.confidence } : {}) },
        });
        if (r.alert) await deps.repo.linkEventToAlert(alphaId, e.eventId, r.alert.alertId);
        push(r);
        break;
      }
      case 'systemFallDetected': {
        // CMFallDetectionEvent.resolution: confirmed | dismissed | rejected | unresponsive
        const resolution = String(e.details?.resolution ?? 'unknown');
        if (resolution === 'dismissed' || resolution === 'rejected') {
          const a = await engine.record({
            alphaId,
            type: 'possibleFall',
            severity: 'info',
            title: 'Apple Watch fall alert dismissed',
            message: `Apple Watch Fall Detection triggered and ${alpha.name} indicated they are okay.`,
            detectedAt: e.detectedAt,
            simulated: sim,
            sourceEventId: e.eventId,
            resolution: 'alphaOk',
            evidence: { detector: 'appleWatchFallDetection', resolution },
          });
          alerts.push({ alertId: a.alertId, type: a.type, status: a.status, created: true });
        } else {
          push(
            await engine.raise({
              alphaId,
              type: 'possibleFall',
              severity: 'critical',
              title: resolution === 'unresponsive' ? 'Fall detected — no response' : 'Fall detected by Apple Watch',
              message: `Apple Watch Fall Detection reported a fall for ${alpha.name} (${resolution}). Please check on them.`,
              detectedAt: e.detectedAt,
              simulated: sim,
              sourceEventId: e.eventId,
              evidence: { detector: 'appleWatchFallDetection', resolution },
            }),
          );
        }
        break;
      }
      case 'fallUserOk': {
        if (related?.alertId) {
          const a = await engine.alphaReportsOk(alphaId, related.alertId);
          if (a) alerts.push({ alertId: a.alertId, type: a.type, status: a.status, created: false });
        }
        break;
      }
      case 'fallNeedHelp':
      case 'fallNoResponse': {
        const needHelp = e.type === 'fallNeedHelp';
        const patch = needHelp
          ? { title: `${alpha.name} needs help after a possible fall`, message: `${alpha.name} answered "I need help" after a possible fall.` }
          : {
              title: 'No response after possible fall',
              message: `${alpha.name} did not respond to a possible-fall check. This does not confirm an injury — please check on them.`,
            };
        const opened = related?.alertId ? await engine.openNow(alphaId, related.alertId, patch) : undefined;
        if (opened) {
          alerts.push({ alertId: opened.alertId, type: opened.type, status: opened.status, created: false });
        } else if (needHelp) {
          push(await engine.raise({ alphaId, type: 'manualHelpRequest', severity: 'critical', ...patch, detectedAt: e.detectedAt, simulated: sim, sourceEventId: e.eventId }));
        }
        break;
      }
      case 'manualHelpRequest':
        push(
          await engine.raise({
            alphaId,
            type: 'manualHelpRequest',
            severity: 'critical',
            title: `${alpha.name} requested help`,
            message: `${alpha.name} pressed the help button in Wellder.`,
            detectedAt: e.detectedAt,
            simulated: sim,
            sourceEventId: e.eventId,
          }),
        );
        break;
      case 'lowBattery':
        push(
          await engine.raise({
            alphaId,
            type: 'lowBattery',
            severity: 'warning',
            title: 'Device battery low',
            message: `${alpha.name}'s ${String(e.details?.deviceType ?? 'device')} battery is low; monitoring may stop when it runs out.`,
            detectedAt: e.detectedAt,
            simulated: sim,
            cooldownSeconds: 6 * 3600,
          }),
        );
        break;
      case 'locationUnavailable':
        push(
          await engine.raise({
            alphaId,
            type: 'locationUnavailable',
            severity: 'warning',
            title: 'Location unavailable',
            message: `Location updates for ${alpha.name} are unavailable (${String(e.details?.reason ?? 'unknown reason')}).`,
            detectedAt: e.detectedAt,
            simulated: sim,
            cooldownSeconds: 6 * 3600,
          }),
        );
        break;
    }
  }

  deps.log.info('telemetry.ingested', { alphaId, deviceId, samples: allowed.length, events: eventsProcessed, simulated });
  return {
    accepted: allowed.length,
    dropped: parsed.length - allowed.length,
    eventsProcessed,
    eventsDuplicate,
    alerts,
    settingsVersion: settings.version,
    serverTime: now.toISOString(),
  };
}
