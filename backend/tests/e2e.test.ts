import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';
import { sweep } from '../src/services/sweeper.ts';
import { capabilities, id, startTestServer } from './helpers.ts';

// End-to-end over real HTTP against the local server (same router/services as Lambda).
// Mirrors the acceptance criteria in the project brief, numbered in comments.

type T = Awaited<ReturnType<typeof startTestServer>>;

async function pair(t: T, alpha: { token: string }, beta: { token: string }, permissions?: Record<string, boolean>) {
  const inv = await t.call('POST', '/v1/invitations', alpha.token, permissions ? { permissions } : {});
  assert.equal(inv.status, 201);
  const redeem = await t.call('POST', '/v1/invitations/redeem', beta.token, { code: inv.body.code });
  assert.equal(redeem.status, 200);
  const relId = redeem.body.relationship.relationshipId as string;
  const ok = await t.call('POST', `/v1/relationships/${relId}/approve`, alpha.token, {});
  assert.equal(ok.status, 200);
  return relId;
}

async function registerDevice(t: T, token: string, deviceType: 'iPhone' | 'appleWatch' = 'iPhone') {
  const deviceId = id();
  const r = await t.call('PUT', `/v1/devices/${deviceId}`, token, {
    deviceType,
    appVersion: '0.1.0',
    capabilities,
    monitoringState: 'active',
    apnsToken: 'ab'.repeat(32),
    apnsEnvironment: 'sandbox',
  });
  assert.equal(r.status, 200);
  return deviceId;
}

describe('acceptance workflow', () => {
  let t: T;
  before(async () => (t = await startTestServer()));
  after(async () => t.close());

  it('runs the full Alpha → Beta lifecycle', async () => {
    // 1–2. accounts
    const alpha = await t.user('Margaret', ['alpha']);
    const beta = await t.user('Daniel', ['beta'], '+15555550100');
    const alphaDevice = await registerDevice(t, alpha.token);
    await registerDevice(t, beta.token);

    // Pending link is not visible before the Alpha approves.
    const inv = await t.call('POST', '/v1/invitations', alpha.token, {});
    assert.match(inv.body.code, /^[2-9A-Z]{8}$/);
    const redeem = await t.call('POST', '/v1/invitations/redeem', beta.token, { code: inv.body.code.toLowerCase() });
    assert.equal(redeem.body.relationship.status, 'pendingAlphaApproval');
    const relId = redeem.body.relationship.relationshipId;
    assert.equal((await t.call('GET', `/v1/alphas/${alpha.userId}/summary`, beta.token)).status, 403);
    assert.equal((await t.call('POST', '/v1/invitations/redeem', beta.token, { code: inv.body.code })).status, 404, 'codes are single-use');

    // 3. Alpha authorizes
    assert.equal((await t.call('POST', `/v1/relationships/${relId}/approve`, alpha.token, {})).status, 200);

    // 4. Beta sees Alpha — gray because nothing has been received yet
    let dash = await t.call('GET', '/v1/dashboard', beta.token);
    assert.equal(dash.body.alphas.length, 1);
    assert.equal(dash.body.alphas[0].status, 'gray');

    // 5–6. telemetry upload (authenticated)
    const now = t.clock.now().getTime();
    const ts = (minAgo: number) => new Date(now - minAgo * 60_000).toISOString();
    const samples = [
      ...[60, 45, 30, 15, 5].map((m, i) => ({ kind: 'heartRate', sampleId: id(), timestamp: ts(m), bpm: 70 + i, sourceDevice: 'Apple Watch' })),
      ...[50, 40, 30, 20, 10].map((m, i) => ({ kind: 'location', sampleId: id(), timestamp: ts(m), latitude: 40.0 + i * 0.001, longitude: -74.0, horizontalAccuracy: 20, source: 'standard' })),
      { kind: 'activity', sampleId: id(), timestamp: ts(12), activityType: 'walking', confidence: 'high' },
      { kind: 'steps', sampleId: id(), timestamp: ts(20), endTimestamp: ts(10), count: 340 },
    ];
    const up = await t.call('POST', '/v1/telemetry', alpha.token, { deviceId: alphaDevice, samples });
    assert.equal(up.status, 200);
    assert.equal(up.body.accepted, samples.length);
    assert.equal(up.body.alerts.length, 0);
    assert.equal((await t.call('POST', '/v1/telemetry', undefined, { deviceId: alphaDevice, samples })).status, 401);

    // Re-uploading the same batch (offline queue retry) is idempotent.
    await t.call('POST', '/v1/telemetry', alpha.token, { deviceId: alphaDevice, samples });

    // Years-old Apple Health history in a batch is dropped, not a 400 that blocks the device's queue.
    const stale = await t.call('POST', '/v1/telemetry', alpha.token, {
      deviceId: alphaDevice,
      samples: [
        { kind: 'heartRate', sampleId: id(), timestamp: new Date(now - 3 * 365 * 86_400_000).toISOString(), bpm: 65, sourceDevice: 'Apple Watch' },
        { kind: 'heartRate', sampleId: id(), timestamp: new Date(now + 3600_000).toISOString(), bpm: 66, sourceDevice: 'Apple Watch' },
      ],
    });
    assert.equal(stale.status, 200);
    assert.equal(stale.body.accepted, 0);
    assert.equal(stale.body.dropped, 2);

    // 7. latest info
    dash = await t.call('GET', '/v1/dashboard', beta.token);
    const card = dash.body.alphas[0];
    assert.equal(card.status, 'green');
    assert.equal(card.snapshot.lastHeartRate.bpm, 74);
    assert.equal(card.snapshot.lastHeartRate.timestamp, ts(5));
    assert.ok(card.snapshot.lastLocation);
    assert.equal(card.snapshot.lastMovementAt, ts(10));

    // 8. location history
    const loc = await t.call('GET', `/v1/alphas/${alpha.userId}/locations?from=${ts(120)}&to=${ts(0)}`, beta.token);
    assert.equal(loc.status, 200);
    assert.equal(loc.body.samples.length, 5, 'duplicates collapsed');
    assert.ok(loc.body.samples[0].timestamp < loc.body.samples[4].timestamp, 'chronological');

    // 9. heart-rate history with stats
    const hr = await t.call('GET', `/v1/alphas/${alpha.userId}/heart-rate?from=${ts(120)}&to=${ts(0)}`, beta.token);
    assert.deepEqual(hr.body.stats, { min: 70, max: 74, count: 5 });

    // 10. Beta requests a settings change → nothing applies until the Alpha approves.
    assert.equal(
      (await t.call('POST', `/v1/alphas/${alpha.userId}/settings-requests`, beta.token, { changes: { heartRate: { enabled: true, upperBpm: 110, lowerBpm: 45, persistenceSeconds: 300, cooldownSeconds: 1800 } } })).status,
      403,
      'manageSettings not granted by default',
    );
    await t.call('PUT', `/v1/relationships/${relId}/permissions`, alpha.token, { permissions: { manageSettings: true } });
    const req = await t.call('POST', `/v1/alphas/${alpha.userId}/settings-requests`, beta.token, {
      changes: { heartRate: { enabled: true, upperBpm: 110, lowerBpm: 45, persistenceSeconds: 300, cooldownSeconds: 1800 } },
      reason: 'Doctor suggested 110',
    });
    assert.equal(req.status, 201);
    let s = await t.call('GET', `/v1/alphas/${alpha.userId}/settings`, alpha.token);
    assert.equal(s.body.settings.heartRate.upperBpm, 120);
    const approved = await t.call('POST', `/v1/me/settings-requests/${req.body.request.requestId}/approve`, alpha.token);
    assert.equal(approved.status, 200);
    s = await t.call('GET', `/v1/alphas/${alpha.userId}/settings`, beta.token);
    assert.equal(s.body.settings.heartRate.upperBpm, 110);
    const audit = await t.call('GET', '/v1/me/audit', alpha.token);
    assert.ok(audit.body.entries.some((e: { action: string }) => e.action === 'settings.change_approved'));

    // 11–12. simulated abnormal event → backend alert
    const help = await t.call('POST', '/v1/telemetry', alpha.token, {
      deviceId: alphaDevice,
      events: [{ eventId: id(), type: 'manualHelpRequest', detectedAt: t.clock.iso(), simulated: true }],
    });
    assert.equal(help.body.alerts.length, 1);
    const alertId = help.body.alerts[0].alertId;
    assert.ok(t.push.sent.some((m) => m.title.startsWith('[SIMULATION]')), 'simulation is labelled in push');

    // 13. Beta receives an in-app alert (and the fetch marks in-app delivery as delivered)
    dash = await t.call('GET', '/v1/dashboard', beta.token);
    assert.equal(dash.body.alphas[0].status, 'red');
    assert.equal(dash.body.alphas[0].openAlerts[0].alertId, alertId);
    const detail = await t.call('GET', `/v1/alphas/${alpha.userId}/alerts/${alertId}`, beta.token);
    assert.ok(detail.body.alert.receivedAt && detail.body.alert.firstNotificationSentAt);
    assert.ok(detail.body.deliveries.some((d: { channel: string; status: string }) => d.channel === 'inApp' && d.status === 'delivered'));

    // Simulated alerts never use paid channels even after escalation.
    t.clock.advance(200);
    await sweep(t.server.deps);
    assert.equal(t.sms.sent.length, 0);

    // 14. acknowledge
    const ack = await t.call('POST', `/v1/alphas/${alpha.userId}/alerts/${alertId}/acknowledge`, beta.token);
    assert.equal(ack.body.alert.status, 'acknowledged');
    assert.equal(ack.body.alert.nextEscalationAt, undefined);
    dash = await t.call('GET', '/v1/dashboard', beta.token);
    assert.equal(dash.body.alphas[0].status, 'yellow');

    // 15. Alpha revokes
    const rev = await t.call('POST', `/v1/relationships/${relId}/revoke`, alpha.token);
    assert.equal(rev.body.relationship.status, 'revoked');

    // 16. Revoked Beta can no longer read protected telemetry
    for (const path of ['summary', 'locations', 'heart-rate', 'activity', 'alerts', 'settings']) {
      assert.equal((await t.call('GET', `/v1/alphas/${alpha.userId}/${path}`, beta.token)).status, 403, path);
    }
    dash = await t.call('GET', '/v1/dashboard', beta.token);
    assert.equal(dash.body.alphas.length, 0);
  });
});

describe('authorization enforcement', () => {
  let t: T;
  before(async () => (t = await startTestServer()));
  after(async () => t.close());

  it('enforces per-permission access and never trusts client IDs', async () => {
    const alpha = await t.user('Rose', ['alpha']);
    const otherAlpha = await t.user('Henry', ['alpha']);
    const beta = await t.user('Lena', ['beta']);
    await pair(t, alpha, beta, { viewLocation: true, viewMovementHistory: false, viewHeartRate: false, viewActivity: true, receiveAlerts: true });
    const device = await registerDevice(t, alpha.token);
    await t.call('POST', '/v1/telemetry', alpha.token, {
      deviceId: device,
      samples: [
        { kind: 'heartRate', sampleId: id(), timestamp: t.clock.iso(-60), bpm: 72, sourceDevice: 'Apple Watch' },
        { kind: 'location', sampleId: id(), timestamp: t.clock.iso(-60), latitude: 1, longitude: 2, horizontalAccuracy: 10, source: 'standard' },
      ],
    });

    assert.equal((await t.call('GET', `/v1/alphas/${alpha.userId}/heart-rate`, beta.token)).status, 403);
    assert.equal((await t.call('GET', `/v1/alphas/${alpha.userId}/locations`, beta.token)).status, 403, 'history needs viewMovementHistory');
    const summary = await t.call('GET', `/v1/alphas/${alpha.userId}/summary`, beta.token);
    assert.equal(summary.body.summary.snapshot.lastHeartRate, undefined, 'hidden heart rate');
    assert.ok(summary.body.summary.snapshot.lastLocation, 'shared location');

    // Unrelated Alpha: same 403 as for non-existent IDs (no probing).
    assert.equal((await t.call('GET', `/v1/alphas/${otherAlpha.userId}/summary`, beta.token)).status, 403);
    assert.equal((await t.call('GET', `/v1/alphas/does-not-exist/summary`, beta.token)).status, 403);

    // Telemetry always lands on the caller's own Alpha ID, whatever the body says.
    await t.call('POST', '/v1/telemetry', otherAlpha.token, {
      deviceId: id(),
      alphaId: alpha.userId,
      samples: [{ kind: 'location', sampleId: id(), timestamp: t.clock.iso(-30), latitude: 50, longitude: 50, horizontalAccuracy: 5, source: 'standard' }],
    });
    const self = await t.call('GET', `/v1/alphas/${alpha.userId}/summary`, alpha.token);
    assert.equal(self.body.summary.snapshot.lastLocation.latitude, 1);

    // A Beta-only account cannot upload telemetry or approve links.
    assert.equal((await t.call('POST', '/v1/telemetry', beta.token, { deviceId: id(), samples: [] })).status, 403);
    assert.equal((await t.call('POST', `/v1/relationships/${alpha.userId}.${beta.userId}/approve`, beta.token, {})).status, 403);
    // Betas cannot change permissions on their own link.
    assert.equal((await t.call('PUT', `/v1/relationships/${alpha.userId}.${beta.userId}/permissions`, beta.token, { permissions: { viewHeartRate: true } })).status, 403);
    // Forged token
    assert.equal((await t.call('GET', '/v1/me', alpha.token.slice(0, -2) + 'xx')).status, 401);
  });

  it('rejects invalid telemetry without echoing values', async () => {
    const alpha = await t.user('Iris', ['alpha']);
    const r = await t.call('POST', '/v1/telemetry', alpha.token, {
      deviceId: id(),
      samples: [{ kind: 'heartRate', sampleId: id(), timestamp: t.clock.iso(), bpm: 999, sourceDevice: 'x' }],
    });
    assert.equal(r.status, 400);
    assert.ok(!JSON.stringify(r.body).includes('999'));
    const future = await t.call('POST', '/v1/telemetry', alpha.token, {
      deviceId: id(),
      samples: [{ kind: 'heartRate', sampleId: id(), timestamp: t.clock.iso(3600), bpm: 80, sourceDevice: 'x' }],
    });
    // Out-of-window timestamps are dropped (counted), not a batch-level 400.
    assert.equal(future.status, 200);
    assert.equal(future.body.dropped, 1);
    const noOffset = await t.call('POST', '/v1/telemetry', alpha.token, {
      deviceId: id(),
      samples: [{ kind: 'heartRate', sampleId: id(), timestamp: t.clock.iso().replace('Z', ''), bpm: 80, sourceDevice: 'x' }],
    });
    assert.equal(noOffset.status, 400, 'timestamps without an offset are ambiguous');
  });

  it('rate-limits invitation code guessing', async () => {
    const beta = await t.user('Guesser', ['beta']);
    let last = 0;
    for (let i = 0; i < 11; i++) last = (await t.call('POST', '/v1/invitations/redeem', beta.token, { code: 'ZZZZZZZZ' })).status;
    assert.equal(last, 429);
  });

  it('drops location samples when the Alpha has turned location sharing off', async () => {
    const alpha = await t.user('Olive', ['alpha']);
    const s = await t.call('GET', `/v1/alphas/${alpha.userId}/settings`, alpha.token);
    const movement = { ...s.body.settings.movement, locationEnabled: false };
    assert.equal((await t.call('PUT', '/v1/me/settings', alpha.token, { version: s.body.settings.version, changes: { movement } })).status, 200);
    assert.equal((await t.call('PUT', '/v1/me/settings', alpha.token, { version: s.body.settings.version, changes: { movement } })).status, 409, 'stale version');
    const r = await t.call('POST', '/v1/telemetry', alpha.token, {
      deviceId: id(),
      samples: [{ kind: 'location', sampleId: id(), timestamp: t.clock.iso(), latitude: 1, longitude: 1, horizontalAccuracy: 5, source: 'standard' }],
    });
    assert.equal(r.body.accepted, 0);
    assert.equal(r.body.dropped, 1);
  });
});

describe('alerts: dedupe, escalation and fall flow', () => {
  let t: T;
  before(async () => (t = await startTestServer()));
  after(async () => t.close());

  it('deduplicates repeated abnormal heart-rate readings', async () => {
    const alpha = await t.user('Walter', ['alpha']);
    const beta = await t.user('Kim', ['beta']);
    const limited = await t.user('Lou', ['beta']);
    await pair(t, alpha, beta);
    await pair(t, alpha, limited, { viewHeartRate: false, receiveAlerts: true });
    await registerDevice(t, beta.token);
    await registerDevice(t, limited.token);
    const device = await registerDevice(t, alpha.token);
    const upload = (offsets: number[], bpm: number) =>
      t.call('POST', '/v1/telemetry', alpha.token, {
        deviceId: device,
        samples: offsets.map((o) => ({ kind: 'heartRate', sampleId: id(), timestamp: t.clock.iso(o), bpm, sourceDevice: 'Apple Watch' })),
      });
    const first = await upload([-600, -300, -10], 140);
    assert.equal(first.body.alerts.length, 1);
    // False-alarm window: the Alpha's devices ring first; caregivers aren't told yet.
    assert.equal(first.body.alerts[0].status, 'awaitingAlphaResponse');
    assert.equal(t.push.sent.filter((m) => m.data.type === 'heartRateHigh').length, 0);
    // The Alpha didn't cancel: the device reports it, caregivers are notified now.
    const opened = await t.call('POST', `/v1/alphas/${alpha.userId}/alerts/${first.body.alerts[0].alertId}/respond`, alpha.token, { response: 'noResponse' });
    assert.equal(opened.status, 200);
    assert.equal(opened.body.alert.status, 'open');
    assert.equal((await t.call('POST', `/v1/alphas/${alpha.userId}/alerts/${first.body.alerts[0].alertId}/respond`, beta.token, { response: 'ok' })).status, 403, 'only the Alpha answers');
    const hrPushes = t.push.sent.filter((m) => m.data.type === 'heartRateHigh');
    assert.equal(hrPushes.length, 2);
    assert.equal(hrPushes.filter((m) => m.body.includes('above 120 bpm')).length, 1, 'only the Beta with viewHeartRate gets details');
    assert.equal(first.body.alerts[0].created, true);
    const second = await upload([-5], 145);
    assert.equal(second.body.alerts[0].created, false, 'folded into the open alert');
    const { body } = await t.call('GET', `/v1/alphas/${alpha.userId}/alerts`, beta.token);
    const hrAlerts = body.alerts.filter((a: { type: string }) => a.type === 'heartRateHigh');
    assert.equal(hrAlerts.length, 1);
    assert.equal(hrAlerts[0].occurrences, 2);
    assert.equal(hrAlerts[0].severity, 'warning');

    // Back to normal → the alert stays open until a caregiver handles it (live readings every few
    // seconds would otherwise close it before anyone saw it).
    await upload([0], 80);
    const stillOpen = (await t.call('GET', `/v1/alphas/${alpha.userId}/alerts`, beta.token)).body.alerts.find((a: { type: string }) => a.type === 'heartRateHigh');
    assert.notEqual(stillOpen.status, 'resolved');

    // A spike that has come down by the end of a batch still alerts (single-reading threshold).
    // Resolved by the caregiver → cooldown then suppresses an immediate re-alert.
    assert.equal((await t.call('POST', `/v1/alphas/${alpha.userId}/alerts/${stillOpen.alertId}/resolve`, beta.token, {})).status, 200);
    t.clock.advance(60);
    const again = await upload([-400, -200, 0], 150);
    assert.equal(again.body.alerts.length, 0, 'cooldown');
  });

  it('heart-rate false alarm: the Alpha cancels within the window and nobody is notified', async () => {
    const alpha = await t.user('Pat', ['alpha']);
    const beta = await t.user('Lee', ['beta']);
    await pair(t, alpha, beta);
    await registerDevice(t, beta.token);
    const device = await registerDevice(t, alpha.token);
    const before = t.push.sent.length;
    const r = await t.call('POST', '/v1/telemetry', alpha.token, {
      deviceId: device,
      samples: [-600, -300, -10].map((o) => ({ kind: 'heartRate', sampleId: id(), timestamp: t.clock.iso(o), bpm: 150, sourceDevice: 'Apple Watch' })),
    });
    const alertId = r.body.alerts[0].alertId;
    const ok = await t.call('POST', `/v1/alphas/${alpha.userId}/alerts/${alertId}/respond`, alpha.token, { response: 'ok' });
    assert.equal(ok.body.alert.status, 'resolved');
    t.clock.advance(120);
    await sweep(t.server.deps);
    assert.equal(t.push.sent.length, before, 'a cancelled false alarm never reaches caregivers');
  });

  it('heart-rate alert opens on the server timer if the Alpha never answers', async () => {
    const alpha = await t.user('Ray', ['alpha']);
    const beta = await t.user('Ida', ['beta']);
    await pair(t, alpha, beta);
    await registerDevice(t, beta.token);
    const device = await registerDevice(t, alpha.token);
    const r = await t.call('POST', '/v1/telemetry', alpha.token, {
      deviceId: device,
      samples: [-600, -300, -10].map((o) => ({ kind: 'heartRate', sampleId: id(), timestamp: t.clock.iso(o), bpm: 150, sourceDevice: 'Apple Watch' })),
    });
    const alertId = r.body.alerts[0].alertId;
    t.clock.advance(70); // 30 s window + 30 s grace
    await sweep(t.server.deps);
    const a = (await t.call('GET', `/v1/alphas/${alpha.userId}/alerts/${alertId}`, beta.token)).body.alert;
    assert.equal(a.status, 'open');
    assert.ok(t.push.sent.some((m) => m.data.alertId === alertId));
  });

  it('alerts on a spike in the middle of a batch with a single-reading threshold', async () => {
    const alpha = await t.user('Mo', ['alpha']);
    const beta = await t.user('Jo', ['beta']);
    await pair(t, alpha, beta);
    const device = await registerDevice(t, alpha.token);
    const settings = (await t.call('GET', `/v1/alphas/${alpha.userId}/settings`, alpha.token)).body.settings;
    const set = await t.call('PUT', '/v1/me/settings', alpha.token, {
      version: settings.version,
      changes: { heartRate: { ...settings.heartRate, persistenceSeconds: 0 } },
    });
    assert.equal(set.status, 200);
    const r = await t.call('POST', '/v1/telemetry', alpha.token, {
      deviceId: device,
      samples: [[-15, 133], [-10, 124], [-5, 116], [0, 109]].map(([o, bpm]) => ({ kind: 'heartRate', sampleId: id(), timestamp: t.clock.iso(o!), bpm, sourceDevice: 'Apple Watch' })),
    });
    assert.equal(r.body.alerts.length, 1);
    assert.equal(r.body.alerts[0].type, 'heartRateHigh');
  });

  it('escalates an unanswered possible fall on the server, then SMS and voice in order', async () => {
    const alpha = await t.user('Edith', ['alpha']);
    const beta1 = await t.user('Sam', ['beta'], '+15555550111');
    const beta2 = await t.user('Ana', ['beta'], '+15555550122');
    await pair(t, alpha, beta1);
    await pair(t, alpha, beta2);
    await registerDevice(t, beta1.token);
    const device = await registerDevice(t, alpha.token);

    // Enable SMS + voice; contact order beta2 before beta1.
    const s = (await t.call('GET', `/v1/alphas/${alpha.userId}/settings`, alpha.token)).body.settings;
    await t.call('PUT', '/v1/me/settings', alpha.token, {
      version: s.version,
      changes: { notifications: { ...s.notifications, sms: true, voice: true, escalationDelaySeconds: 120, contactOrder: [beta2.userId, beta1.userId] } },
    });

    const fallId = id();
    const r = await t.call('POST', '/v1/telemetry', alpha.token, {
      deviceId: device,
      events: [{ eventId: fallId, type: 'fallCandidate', detectedAt: t.clock.iso(), confidence: 0.8, countdownSeconds: 60 }],
    });
    const alertId = r.body.alerts[0].alertId;
    assert.equal(r.body.alerts[0].status, 'awaitingAlphaResponse');
    const pushesBefore = t.push.sent.length;

    // Nothing is sent to Betas while the Alpha is being asked.
    await sweep(t.server.deps);
    assert.equal(t.push.sent.length, pushesBefore);

    // Device never answers (e.g. damaged): server opens the alert after countdown + grace.
    t.clock.advance(95);
    await sweep(t.server.deps);
    let a = (await t.call('GET', `/v1/alphas/${alpha.userId}/alerts/${alertId}`, beta1.token)).body.alert;
    assert.equal(a.status, 'open');
    assert.equal(a.title, 'No response after possible fall');
    assert.equal(t.sms.sent.length, 0);

    t.clock.advance(121);
    await sweep(t.server.deps);
    assert.deepEqual(t.sms.sent.map((m) => m.to), ['+15555550122', '+15555550111'], 'contact order respected');
    assert.equal(t.voice.calls.length, 0);

    t.clock.advance(121);
    await sweep(t.server.deps);
    assert.equal(t.voice.calls.length, 2);

    t.clock.advance(600);
    await sweep(t.server.deps);
    assert.equal(t.voice.calls.length, 2, 'escalation stops after the last step');
    a = (await t.call('GET', `/v1/alphas/${alpha.userId}/alerts/${alertId}`, beta1.token)).body.alert;
    assert.equal(a.escalationStep, 2);

    // Replaying the same event does nothing.
    const dup = await t.call('POST', '/v1/telemetry', alpha.token, {
      deviceId: device,
      events: [{ eventId: fallId, type: 'fallCandidate', detectedAt: t.clock.iso(-900), confidence: 0.8, countdownSeconds: 60 }],
    });
    assert.equal(dup.body.eventsDuplicate, 1);
  });

  it('resolves silently when the Alpha answers "I\'m okay" in time', async () => {
    const alpha = await t.user('Frank', ['alpha']);
    const beta = await t.user('Joy', ['beta']);
    await pair(t, alpha, beta);
    await registerDevice(t, beta.token);
    const device = await registerDevice(t, alpha.token);
    const fallId = id();
    const before = t.push.sent.length;
    await t.call('POST', '/v1/telemetry', alpha.token, {
      deviceId: device,
      events: [{ eventId: fallId, type: 'fallCandidate', detectedAt: t.clock.iso(), confidence: 0.6, countdownSeconds: 30 }],
    });
    t.clock.advance(10);
    const ok = await t.call('POST', '/v1/telemetry', alpha.token, {
      deviceId: device,
      events: [{ eventId: id(), type: 'fallUserOk', detectedAt: t.clock.iso(), relatedEventId: fallId }],
    });
    assert.equal(ok.body.alerts[0].status, 'resolved');
    t.clock.advance(300);
    await sweep(t.server.deps);
    assert.equal(t.push.sent.length, before, 'Betas were never disturbed');
  });

  it('raises monitoring-interrupted (not inactivity) when data stops', async () => {
    const alpha = await t.user('Gus', ['alpha']);
    const beta = await t.user('Pia', ['beta']);
    await pair(t, alpha, beta);
    const device = await registerDevice(t, alpha.token);
    await t.call('POST', '/v1/telemetry', alpha.token, {
      deviceId: device,
      samples: [{ kind: 'activity', sampleId: id(), timestamp: t.clock.iso(-60), activityType: 'walking', confidence: 'high' }],
    });
    t.clock.advance(3 * 3600);
    await sweep(t.server.deps);
    const { body } = await t.call('GET', `/v1/alphas/${alpha.userId}/alerts`, beta.token);
    const types = body.alerts.map((a: { type: string }) => a.type);
    assert.ok(types.includes('monitoringInterrupted'));
    assert.ok(!types.includes('prolongedInactivity'));
    const dash = await t.call('GET', '/v1/dashboard', beta.token);
    assert.equal(dash.body.alphas.find((x: { alphaId: string }) => x.alphaId === alpha.userId).status, 'gray');

    // Data resumes → interruption auto-resolves.
    await t.call('POST', '/v1/telemetry', alpha.token, { deviceId: device, samples: [] });
    const after = await t.call('GET', `/v1/alphas/${alpha.userId}/alerts`, beta.token);
    assert.equal(after.body.alerts.find((a: { type: string }) => a.type === 'monitoringInterrupted').status, 'resolved');
  });

  it('raises prolonged inactivity only while data is flowing and outside the night window', async () => {
    const alpha = await t.user('Hal', ['alpha']);
    const beta = await t.user('Uma', ['beta']);
    await pair(t, alpha, beta);
    const device = await registerDevice(t, alpha.token);
    const s = (await t.call('GET', `/v1/alphas/${alpha.userId}/settings`, alpha.token)).body.settings;
    await t.call('PUT', '/v1/me/settings', alpha.token, { version: s.version, changes: { staleAfterMinutes: 600, movement: { ...s.movement, inactivityThresholdMinutes: 120 } } });
    await t.call('POST', '/v1/telemetry', alpha.token, {
      deviceId: device,
      samples: [{ kind: 'activity', sampleId: id(), timestamp: t.clock.iso(-3 * 3600), activityType: 'walking', confidence: 'high' }],
    });
    await sweep(t.server.deps);
    const { body } = await t.call('GET', `/v1/alphas/${alpha.userId}/alerts`, beta.token);
    assert.ok(body.alerts.some((a: { type: string }) => a.type === 'prolongedInactivity'));
  });

  it('deletes all of an Alpha\'s data on account deletion', async () => {
    const alpha = await t.user('Ivy', ['alpha']);
    const beta = await t.user('Ned', ['beta']);
    await pair(t, alpha, beta);
    const device = await registerDevice(t, alpha.token);
    await t.call('POST', '/v1/telemetry', alpha.token, {
      deviceId: device,
      samples: [{ kind: 'heartRate', sampleId: id(), timestamp: t.clock.iso(), bpm: 70, sourceDevice: 'w' }],
    });
    const del = await t.call('DELETE', '/v1/me', alpha.token);
    assert.equal(del.status, 200);
    assert.ok(del.body.deleted > 3);
    const rels = await t.call('GET', '/v1/relationships', beta.token);
    assert.equal(rels.body.asBeta.length, 0);
    const { samples } = await t.server.deps.repo.querySamples(alpha.userId, 'heartRate', '2000-01-01', '2100-01-01');
    assert.equal(samples.length, 0);
    const login = await t.call('POST', '/dev/auth/login', undefined, { email: alpha.email, password: 'correct horse battery' });
    assert.equal(login.status, 400, 'sign-in identity is deleted too');
  });
});
