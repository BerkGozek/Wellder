import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { evaluateHeartRate } from '../src/domain/heartRate.ts';
import { hasPermission } from '../src/domain/permissions.ts';
import { isNightTime, minuteInWindow } from '../src/domain/schedule.ts';
import { defaultSettings, validateSettingsPatch } from '../src/domain/settings.ts';
import type { HeartRateSample, MonitoringRelationship, SleepSchedule } from '../src/domain/types.ts';
import { computeStatus } from '../src/services/queries.ts';
import { inactivityReference, lastWakeTime } from '../src/services/sweeper.ts';

const schedule = (over: Partial<SleepSchedule> = {}): SleepSchedule => ({
  enabled: true,
  bedtime: '22:00',
  wakeTime: '07:00',
  timeZone: 'America/New_York',
  keepFallDetectionAtNight: true,
  ...over,
});

describe('night schedule', () => {
  it('handles windows spanning midnight', () => {
    assert.equal(minuteInWindow(23 * 60, 22 * 60, 7 * 60), true);
    assert.equal(minuteInWindow(3 * 60, 22 * 60, 7 * 60), true);
    assert.equal(minuteInWindow(7 * 60, 22 * 60, 7 * 60), false, 'wake time itself is day');
    assert.equal(minuteInWindow(12 * 60, 22 * 60, 7 * 60), false);
  });
  it('handles same-day windows and zero-length windows', () => {
    assert.equal(minuteInWindow(14 * 60, 13 * 60, 15 * 60), true);
    assert.equal(minuteInWindow(16 * 60, 13 * 60, 15 * 60), false);
    assert.equal(minuteInWindow(10, 600, 600), false);
  });
  it('evaluates in the schedule time zone', () => {
    // 03:30 UTC = 23:30 New York (EDT, UTC-4) in July
    assert.equal(isNightTime(schedule(), new Date('2026-07-01T03:30:00Z')), true);
    assert.equal(isNightTime(schedule({ timeZone: 'Europe/Istanbul' }), new Date('2026-07-01T03:30:00Z')), true); // 06:30
    assert.equal(isNightTime(schedule({ timeZone: 'Asia/Tokyo' }), new Date('2026-07-01T03:30:00Z')), false); // 12:30
  });
  it('keeps wall-clock bedtime across DST transitions', () => {
    // US DST starts 2026-03-08. 22:30 local is 03:30Z before, 02:30Z after.
    assert.equal(isNightTime(schedule(), new Date('2026-03-07T03:30:00Z')), true);
    assert.equal(isNightTime(schedule(), new Date('2026-03-09T02:30:00Z')), true);
    // 21:30 local after DST = 01:30Z — still day
    assert.equal(isNightTime(schedule(), new Date('2026-03-09T01:30:00Z')), false);
    // Fall back (2026-11-01): 06:30 local EST = 11:30Z is night, 07:30 EST = 12:30Z is day
    assert.equal(isNightTime(schedule(), new Date('2026-11-01T11:30:00Z')), true);
    assert.equal(isNightTime(schedule(), new Date('2026-11-01T12:30:00Z')), false);
  });
  it('honours manual overrides until they expire', () => {
    const at = new Date('2026-07-01T16:00:00Z'); // noon NY
    assert.equal(isNightTime(schedule({ override: { mode: 'forceNight', until: '2026-07-01T17:00:00Z' } }), at), true);
    assert.equal(isNightTime(schedule({ override: { mode: 'forceNight', until: '2026-07-01T15:00:00Z' } }), at), false);
    const night = new Date('2026-07-01T04:00:00Z');
    assert.equal(isNightTime(schedule({ override: { mode: 'forceDay', until: '2026-07-01T05:00:00Z' } }), night), false);
  });
  it('is never night when disabled or misconfigured', () => {
    assert.equal(isNightTime(schedule({ enabled: false }), new Date('2026-07-01T03:30:00Z')), false);
    assert.equal(isNightTime(schedule({ timeZone: 'Not/AZone' }), new Date('2026-07-01T03:30:00Z')), false);
  });
});

const hr = (minutesAgo: number, bpm: number): HeartRateSample => ({
  kind: 'heartRate',
  sampleId: `s${minutesAgo}`,
  timestamp: new Date(Date.parse('2026-03-10T12:00:00Z') - minutesAgo * 60_000).toISOString(),
  bpm,
  sourceDevice: 'Apple Watch',
});

describe('heart-rate threshold evaluation', () => {
  const thresholds = defaultSettings('a', 'UTC', new Date()).heartRate; // 45..120, 300s persistence
  it('ignores a single spike when persistence is required', () => {
    assert.equal(evaluateHeartRate([hr(10, 80), hr(0, 150)], thresholds), null);
  });
  it('fires when abnormal readings span the persistence window', () => {
    const f = evaluateHeartRate([hr(20, 80), hr(6, 130), hr(3, 140), hr(0, 135)], thresholds);
    assert.ok(f);
    assert.equal(f.direction, 'high');
    assert.equal(f.readings, 3);
    assert.equal(f.extremeBpm, 140);
  });
  it('does not fire when the newest reading is back to normal', () => {
    assert.equal(evaluateHeartRate([hr(10, 140), hr(5, 140), hr(0, 90)], thresholds), null);
  });
  it('detects low heart rate and supports zero persistence', () => {
    const f = evaluateHeartRate([hr(0, 38)], { ...thresholds, persistenceSeconds: 0 });
    assert.equal(f?.direction, 'low');
  });
  it('does not mix directions in one run', () => {
    assert.equal(evaluateHeartRate([hr(10, 30), hr(0, 150)], thresholds), null);
  });
  it('respects the enabled flag', () => {
    assert.equal(evaluateHeartRate([hr(10, 150), hr(0, 150)], { ...thresholds, enabled: false }), null);
  });
});

describe('settings validation', () => {
  it('rejects automatic emergency services', () => {
    assert.throws(() => validateSettingsPatch({ emergency: { automaticEmergencyServices: true, emergencyNumber: '911', contacts: [] } }));
  });
  it('rejects inverted thresholds and unknown sections', () => {
    assert.throws(() => validateSettingsPatch({ heartRate: { enabled: true, upperBpm: 60, lowerBpm: 80, persistenceSeconds: 0, cooldownSeconds: 600 } }));
    assert.throws(() => validateSettingsPatch({ telemetryUploadUrl: 'x' }));
  });
  it('rejects invalid time zones and times', () => {
    const base = { enabled: true, bedtime: '22:00', wakeTime: '07:00', timeZone: 'UTC', keepFallDetectionAtNight: true };
    assert.ok(validateSettingsPatch({ sleepSchedule: base }).sleepSchedule);
    assert.throws(() => validateSettingsPatch({ sleepSchedule: { ...base, timeZone: 'Mars/Olympus' } }));
    assert.throws(() => validateSettingsPatch({ sleepSchedule: { ...base, bedtime: '25:00' } }));
  });
  it('validates phone numbers as E.164', () => {
    assert.throws(() => validateSettingsPatch({ emergency: { emergencyNumber: '911', contacts: [{ name: 'A', phoneNumber: '555-1234' }] } }));
  });
});

describe('permissions', () => {
  const rel = (status: MonitoringRelationship['status']): MonitoringRelationship => ({
    relationshipId: 'a.b',
    alphaId: 'a',
    betaId: 'b',
    alphaName: 'A',
    betaName: 'B',
    betaEmail: 'b@x',
    permissions: { viewLocation: true, viewMovementHistory: false, viewHeartRate: true, viewActivity: true, receiveAlerts: true, manageSettings: false, manageEmergencyContacts: false },
    status,
    createdAt: '',
  });
  it('requires an active relationship', () => {
    assert.equal(hasPermission(rel('active'), 'viewLocation'), true);
    assert.equal(hasPermission(rel('pendingAlphaApproval'), 'viewLocation'), false);
    assert.equal(hasPermission(rel('revoked'), 'viewLocation'), false);
    assert.equal(hasPermission(rel('active'), 'viewMovementHistory'), false);
    assert.equal(hasPermission(undefined, 'viewLocation'), false);
  });
});

describe('dashboard status & freshness', () => {
  const settings = defaultSettings('a', 'UTC', new Date());
  const now = new Date('2026-03-10T12:00:00Z');
  it('treats missing data as gray, never green', () => {
    assert.equal(computeStatus(undefined, [], settings, now).status, 'gray');
    assert.equal(computeStatus({ alphaId: 'a' }, [], settings, now).status, 'gray');
  });
  it('treats stale data as gray', () => {
    assert.equal(computeStatus({ alphaId: 'a', lastSyncAt: '2026-03-10T08:00:00Z' }, [], settings, now).status, 'gray');
    assert.equal(computeStatus({ alphaId: 'a', lastSyncAt: '2026-03-10T11:30:00Z' }, [], settings, now).status, 'green');
  });
  it('shows red for unacknowledged critical safety alerts even when data is stale', () => {
    const alert = { severity: 'critical', status: 'open', category: 'safety', title: 'Possible fall' } as never;
    assert.equal(computeStatus({ alphaId: 'a', lastSyncAt: '2026-03-10T01:00:00Z' }, [alert], settings, now).status, 'red');
  });
});

describe('inactivity reference', () => {
  it('does not count inactivity across the night window', () => {
    const settings = defaultSettings('a', 'America/New_York', new Date());
    settings.sleepSchedule.enabled = true; // 22:00 → 07:00
    const now = new Date('2026-07-01T11:30:00Z'); // 07:30 EDT
    const wake = lastWakeTime(settings, now)!;
    assert.equal(wake.toISOString(), '2026-07-01T11:00:00.000Z');
    const ref = inactivityReference({ alphaId: 'a', lastMovementAt: '2026-07-01T01:00:00Z' }, settings, now)!;
    assert.equal(ref.toISOString(), wake.toISOString());
  });
});
