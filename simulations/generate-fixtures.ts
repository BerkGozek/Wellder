// Drives the real backend (in-process, in-memory store) through a scenario and writes its JSON
// responses to packages/WellderKit/Tests/SharedModelsTests/Fixtures. The Swift tests decode
// these files, so any drift between the TypeScript and Swift models fails a test.
//
//   node simulations/generate-fixtures.ts
import { randomUUID } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { startLocalServer } from '../backend/src/local/server.ts';
import { silentLogger } from '../backend/src/log.ts';
import { sweep } from '../backend/src/services/sweeper.ts';
import { MemoryTable } from '../backend/src/store/memoryTable.ts';

const out = fileURLToPath(new URL('../packages/WellderKit/Tests/SharedModelsTests/Fixtures/', import.meta.url));
mkdirSync(out, { recursive: true });

let t = Date.parse('2026-05-04T14:00:00.000Z');
const now = () => new Date(t);
const server = await startLocalServer({ port: 0, table: new MemoryTable(now), log: silentLogger, now, devJwtSecret: 'fixtures', sweepIntervalSeconds: 0 });
const base = `http://127.0.0.1:${server.port}`;
const call = async (method: string, path: string, token?: string, body?: unknown) => {
  const res = await fetch(base + path, {
    method,
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
  const json = (await res.json()) as any;
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status} ${JSON.stringify(json)}`);
  return json;
};
const save = (name: string, value: unknown) => writeFileSync(`${out}${name}.json`, JSON.stringify(value, null, 2) + '\n');
const iso = (offsetMin: number) => new Date(t + offsetMin * 60_000).toISOString();

const reg = async (email: string, name: string, roles: string[]) => {
  const r = await call('POST', '/dev/auth/register', undefined, { email, password: 'fixture-password' });
  const me = await call('PUT', '/v1/me', r.idToken, { name, roles, timeZone: 'America/Chicago', phoneNumber: '+15555550142' });
  return { token: r.idToken as string, userId: r.userId as string, me };
};
const alpha = await reg('alpha@fixture.test', 'Margaret Lee', ['alpha']);
const beta = await reg('beta@fixture.test', 'Daniel Lee', ['beta']);
save('profile', alpha.me);

const invite = await call('POST', '/v1/invitations', alpha.token, {});
save('invitation-created', invite);
save('invitations', await call('GET', '/v1/invitations', alpha.token));
const redeemed = await call('POST', '/v1/invitations/redeem', beta.token, { code: invite.code });
await call('POST', `/v1/relationships/${redeemed.relationship.relationshipId}/approve`, alpha.token, {});
save('relationships', await call('GET', '/v1/relationships', beta.token));

const deviceId = randomUUID();
await call('PUT', `/v1/devices/${deviceId}`, alpha.token, {
  deviceType: 'iPhone', appVersion: '0.1.0', monitoringState: 'active', batteryLevel: 0.8,
  capabilities: { healthKit: true, heartRate: true, backgroundLocation: true, motionActivity: true, pedometer: true, systemFallDetection: false, experimentalFallDetection: true, pushNotifications: true },
});
const samples = [
  ...[90, 60, 30, 10].map((m, i) => ({ kind: 'heartRate', sampleId: randomUUID(), timestamp: iso(-m), bpm: 66 + i, sourceDevice: 'Apple Watch' })),
  ...[80, 70, 20, 10].map((m, i) => ({ kind: 'location', sampleId: randomUUID(), timestamp: iso(-m), latitude: 41.88 + i * 0.001, longitude: -87.63, horizontalAccuracy: 15, source: 'standard' })),
  { kind: 'activity', sampleId: randomUUID(), timestamp: iso(-15), activityType: 'walking', confidence: 'high' },
  { kind: 'steps', sampleId: randomUUID(), timestamp: iso(-25), endTimestamp: iso(-15), count: 412 },
  { kind: 'interaction', sampleId: randomUUID(), timestamp: iso(-5), source: 'checkIn' },
];
save('ingest-result', await call('POST', '/v1/telemetry', alpha.token, { deviceId, samples }));
const fall = randomUUID();
await call('POST', '/v1/telemetry', alpha.token, {
  deviceId,
  events: [{ eventId: fall, type: 'fallCandidate', detectedAt: iso(0), confidence: 0.75, countdownSeconds: 60, simulated: true, details: { detector: 'experimental' } }],
});
t += 120_000;
await sweep(server.deps); // no answer → server opens the alert

const dash = await call('GET', '/v1/dashboard', beta.token);
save('dashboard', dash);
save('summary', await call('GET', `/v1/alphas/${alpha.userId}/summary`, alpha.token));
const range = `from=${iso(-180)}&to=${iso(0)}`;
save('locations', await call('GET', `/v1/alphas/${alpha.userId}/locations?${range}`, beta.token));
save('heart-rate', await call('GET', `/v1/alphas/${alpha.userId}/heart-rate?${range}`, beta.token));
save('activity', await call('GET', `/v1/alphas/${alpha.userId}/activity?${range}`, beta.token));
const alerts = await call('GET', `/v1/alphas/${alpha.userId}/alerts`, beta.token);
save('alerts', alerts);
save('alert-detail', await call('GET', `/v1/alphas/${alpha.userId}/alerts/${alerts.alerts[0].alertId}`, beta.token));
save('settings', await call('GET', `/v1/alphas/${alpha.userId}/settings`, alpha.token));
await call('PUT', `/v1/relationships/${redeemed.relationship.relationshipId}/permissions`, alpha.token, { permissions: { manageSettings: true } });
const s = (await call('GET', `/v1/alphas/${alpha.userId}/settings`, beta.token)).settings;
const req = await call('POST', `/v1/alphas/${alpha.userId}/settings-requests`, beta.token, {
  changes: { sleepSchedule: { ...s.sleepSchedule, enabled: true, override: { mode: 'forceNight', until: iso(60) } } },
  reason: 'Try night mode',
});
save('settings-request', req);
save('settings-requests', await call('GET', `/v1/alphas/${alpha.userId}/settings-requests`, alpha.token));
save('audit', await call('GET', '/v1/me/audit', alpha.token));
await server.close();
console.log(`Fixtures written to ${out}`);
