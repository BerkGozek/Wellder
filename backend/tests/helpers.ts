import { randomUUID } from 'node:crypto';
import { startLocalServer } from '../src/local/server.ts';
import { silentLogger } from '../src/log.ts';
import { RecordingPushProvider, RecordingSmsProvider, RecordingVoiceProvider } from '../src/notify/providers.ts';
import { MemoryTable } from '../src/store/memoryTable.ts';

/** Controllable clock for deterministic escalation tests. */
export class Clock {
  t: number;
  constructor(iso = '2026-03-10T15:00:00.000Z') {
    this.t = Date.parse(iso);
  }
  now = () => new Date(this.t);
  advance(seconds: number) {
    this.t += seconds * 1000;
  }
  iso(offsetSeconds = 0) {
    return new Date(this.t + offsetSeconds * 1000).toISOString();
  }
}

export async function startTestServer(clock = new Clock()) {
  const table = new MemoryTable(clock.now);
  const server = await startLocalServer({ port: 0, table, log: silentLogger, sweepIntervalSeconds: 0, now: clock.now, devJwtSecret: 'test-secret' });
  // Swap in recording providers we can inspect (SMS/voice "enabled" to exercise escalation).
  const push = new RecordingPushProvider();
  const sms = new RecordingSmsProvider();
  const voice = new RecordingVoiceProvider();
  server.deps.providers.push = push;
  server.deps.providers.sms = sms;
  server.deps.providers.voice = voice;
  const base = `http://127.0.0.1:${server.port}`;

  async function call(method: string, path: string, token?: string, body?: unknown) {
    const res = await fetch(base + path, {
      method,
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
    });
    return { status: res.status, body: (await res.json()) as any };
  }

  async function user(name: string, roles: ('alpha' | 'beta')[], phoneNumber?: string) {
    const email = `${name.toLowerCase()}-${randomUUID().slice(0, 6)}@example.test`;
    const reg = await call('POST', '/dev/auth/register', undefined, { email, password: 'correct horse battery' });
    if (reg.status !== 201) throw new Error(`register failed ${reg.status}`);
    const token = reg.body.idToken as string;
    const me = await call('PUT', '/v1/me', token, { name, roles, timeZone: 'America/New_York', ...(phoneNumber ? { phoneNumber } : {}) });
    if (me.status !== 200) throw new Error(`profile failed ${me.status} ${JSON.stringify(me.body)}`);
    return { token, userId: reg.body.userId as string, email, name };
  }

  return { server, call, user, push, sms, voice, clock, close: () => server.close() };
}

export const capabilities = {
  healthKit: true,
  heartRate: true,
  backgroundLocation: true,
  motionActivity: true,
  pedometer: true,
  systemFallDetection: false,
  experimentalFallDetection: true,
  pushNotifications: true,
};

export const id = () => randomUUID();
