// Simulated Alpha device for local development. Talks to a RUNNING local backend over HTTP,
// exactly like the iOS app does, and marks everything `simulated: true` (so alerts are labelled
// "[SIMULATION]" and never use SMS or voice).
//
//   cd backend && npm run dev                       # terminal 1
//   node simulations/simulate-alpha.ts setup        # terminal 2: creates Alpha + Beta, pairs them
//   node simulations/simulate-alpha.ts stream       # uploads live synthetic telemetry every 15 s
//   node simulations/simulate-alpha.ts <scenario>   # one-off scenario, see SCENARIOS below
//
// Sign in to the iOS app (Simulator) with the printed Beta credentials to watch the dashboard.
import { randomUUID } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const API = process.env.AB_API ?? 'http://127.0.0.1:8787';
const STATE_FILE = fileURLToPath(new URL('./.sim-state.json', import.meta.url));
const HOME = { lat: 41.8781, lon: -87.6298 };

interface State {
  alpha: { email: string; password: string; token: string; userId: string };
  beta: { email: string; password: string; token: string; userId: string };
  deviceId: string;
}

async function call(method: string, path: string, token?: string, body?: unknown): Promise<any> {
  const res = await fetch(API + path, {
    method,
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status} ${JSON.stringify(json)}`);
  return json;
}

const iso = (msAgo = 0) => new Date(Date.now() - msAgo).toISOString();
const sim = { simulated: true } as const;

function loadState(): State {
  if (!existsSync(STATE_FILE)) throw new Error('Run "setup" first');
  return JSON.parse(readFileSync(STATE_FILE, 'utf8')) as State;
}

async function login(email: string, password: string) {
  return call('POST', '/dev/auth/login', undefined, { email, password });
}

async function refreshTokens(s: State): Promise<State> {
  // The local server's signing key changes on restart; re-login keeps old state usable.
  for (const who of ['alpha', 'beta'] as const) {
    const r = await login(s[who].email, s[who].password).catch(() => null);
    if (!r) throw new Error('Accounts not found on this server instance (in-memory store restarted?). Run "setup" again.');
    s[who].token = r.idToken;
  }
  return s;
}

async function upload(s: State, samples: unknown[], events: unknown[] = []) {
  const r = await call('POST', '/v1/telemetry', s.alpha.token, { deviceId: s.deviceId, samples, events });
  const alerts = r.alerts.map((a: { type: string; status: string; created: boolean }) => `${a.type}:${a.status}${a.created ? ' (new)' : ''}`);
  console.log(`  uploaded ${r.accepted} samples, ${r.eventsProcessed} events${alerts.length ? ` → alerts ${alerts.join(', ')}` : ''}`);
  return r;
}

function hr(bpm: number, msAgo = 0) {
  return { kind: 'heartRate', sampleId: randomUUID(), timestamp: iso(msAgo), bpm, sourceDevice: 'Simulated Apple Watch', ...sim };
}
function loc(t: number, msAgo = 0) {
  return {
    kind: 'location', sampleId: randomUUID(), timestamp: iso(msAgo),
    latitude: HOME.lat + 0.004 * Math.sin(t / 7), longitude: HOME.lon + 0.004 * Math.cos(t / 11),
    horizontalAccuracy: 10 + Math.random() * 30, source: 'standard', ...sim,
  };
}
function activity(type: string, msAgo = 0) {
  return { kind: 'activity', sampleId: randomUUID(), timestamp: iso(msAgo), activityType: type, confidence: 'high', ...sim };
}

const SCENARIOS: Record<string, (s: State) => Promise<void>> = {
  /** Backfills 6 h of history (ending 15 min ago) with a deliberate 40-minute location gap. */
  async history(s) {
    const samples: unknown[] = [];
    for (let m = 360; m >= 15; m -= 5) {
      samples.push(hr(Math.round(66 + 8 * Math.sin(m / 40) + Math.random() * 4), m * 60_000));
      if (m < 150 || m > 190) samples.push(loc(m, m * 60_000));
      if (m % 30 === 0) samples.push(activity(m % 60 === 0 ? 'walking' : 'stationary', m * 60_000));
    }
    await upload(s, samples);
  },
  /** Three readings above 120 bpm over 10 minutes → heartRateHigh (warning). */
  async 'high-hr'(s) {
    await upload(s, [hr(132, 10 * 60_000), hr(138, 5 * 60_000), hr(135)]);
  },
  async 'low-hr'(s) {
    await upload(s, [hr(39, 10 * 60_000), hr(38, 5 * 60_000), hr(40)]);
  },
  /** Fall candidate with no answer: the backend opens the alert after countdown + 30 s grace. */
  async 'fall-no-response'(s) {
    await upload(s, [], [{ eventId: randomUUID(), type: 'fallCandidate', detectedAt: iso(), confidence: 0.82, countdownSeconds: 30, ...sim }]);
    console.log('  Alpha "did not answer". Watch the Beta dashboard: alert opens in ~60 s (sweeper runs every 15 s locally).');
  },
  /** Fall candidate, then "I'm okay" 5 s later: resolved without notifying anyone. */
  async 'fall-ok'(s) {
    const id = randomUUID();
    await upload(s, [], [{ eventId: id, type: 'fallCandidate', detectedAt: iso(), confidence: 0.7, countdownSeconds: 60, ...sim }]);
    await new Promise((r) => setTimeout(r, 5000));
    await upload(s, [], [{ eventId: randomUUID(), type: 'fallUserOk', detectedAt: iso(), relatedEventId: id, ...sim }]);
  },
  async help(s) {
    await upload(s, [], [{ eventId: randomUUID(), type: 'manualHelpRequest', detectedAt: iso(), ...sim }]);
  },
  /** Lowers the Alpha's inactivity threshold to 30 min (the minimum) and reports "stationary";
   *  the history's last walk is ≥ 1 h old, so the sweeper raises prolongedInactivity. */
  async inactivity(s) {
    const { settings } = await call('GET', `/v1/alphas/${s.alpha.userId}/settings`, s.alpha.token);
    await call('PUT', '/v1/me/settings', s.alpha.token, {
      version: settings.version,
      changes: { movement: { ...settings.movement, inactivityThresholdMinutes: 30 } },
    });
    console.log('  Inactivity threshold set to 30 min for this simulated Alpha.');
    await upload(s, [activity('stationary', 60_000), hr(64)]);
    console.log('  The sweeper raises the alert within ~15 s (not during night mode).');
  },
  /** Queues 10 minutes of samples "offline", then uploads them in one late batch. */
  async 'connectivity-failure'(s) {
    const queued: unknown[] = [];
    for (let m = 10; m >= 1; m--) queued.push(hr(70, m * 60_000), loc(m, m * 60_000));
    console.log('  Device offline: 20 samples queued locally…');
    await new Promise((r) => setTimeout(r, 3000));
    console.log('  Back online: uploading the queue (timestamps keep their original measurement time).');
    await upload(s, queued);
  },
};

async function setup() {
  const suffix = randomUUID().slice(0, 6);
  const mk = async (name: string, roles: string[], phoneNumber?: string) => {
    const email = `${name.toLowerCase().split(' ')[0]}-${suffix}@sim.local`;
    const password = 'simulation-password';
    const r = await call('POST', '/dev/auth/register', undefined, { email, password });
    await call('PUT', '/v1/me', r.idToken, { name, roles, timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone, ...(phoneNumber ? { phoneNumber } : {}) });
    return { email, password, token: r.idToken as string, userId: r.userId as string };
  };
  const alpha = await mk('Margaret Simulated', ['alpha']);
  const beta = await mk('Daniel Simulated', ['beta'], '+15555550100');
  const inv = await call('POST', '/v1/invitations', alpha.token, {});
  const red = await call('POST', '/v1/invitations/redeem', beta.token, { code: inv.code });
  await call('POST', `/v1/relationships/${red.relationship.relationshipId}/approve`, alpha.token, {});
  const deviceId = randomUUID();
  await call('PUT', `/v1/devices/${deviceId}`, alpha.token, {
    deviceType: 'iPhone', appVersion: 'simulator', monitoringState: 'active', batteryLevel: 0.76,
    capabilities: { healthKit: true, heartRate: true, backgroundLocation: true, motionActivity: true, pedometer: true, systemFallDetection: false, experimentalFallDetection: true, pushNotifications: false },
  });
  const state: State = { alpha, beta, deviceId };
  writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
  await SCENARIOS.history!(state);
  console.log(`\nPaired. Sign in to the app as the caregiver:\n  email:    ${beta.email}\n  password: ${beta.password}\n(Alpha: ${alpha.email} / ${alpha.password})`);
}

async function stream(s: State) {
  console.log(`Streaming synthetic telemetry to ${API} every 15 s (Ctrl-C to stop)…`);
  let t = 0;
  for (;;) {
    t++;
    await upload(s, [hr(Math.round(68 + 6 * Math.sin(t / 5) + Math.random() * 3)), loc(t), ...(t % 4 === 0 ? [activity(t % 8 === 0 ? 'walking' : 'stationary')] : [])]);
    await new Promise((r) => setTimeout(r, 15_000));
  }
}

const cmd = process.argv[2] ?? 'help-text';
if (cmd === 'setup') {
  await setup();
} else if (cmd === 'stream') {
  await stream(await refreshTokens(loadState()));
} else if (SCENARIOS[cmd]) {
  console.log(`Scenario: ${cmd}`);
  await SCENARIOS[cmd]!(await refreshTokens(loadState()));
} else {
  console.log(`Usage: node simulations/simulate-alpha.ts <setup|stream|${Object.keys(SCENARIOS).join('|')}>`);
}
