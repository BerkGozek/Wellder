import { badRequest } from './errors.ts';
import { isValidTimeZone, parseHHMM } from './schedule.ts';
import type { MonitoringSettings, SettingsSection } from './types.ts';
import { PHONE_E164, arr, bool, num, obj, optStr, str, type Json } from './validation.ts';

export function defaultSettings(alphaId: string, timeZone: string, now: Date): MonitoringSettings {
  return {
    alphaId,
    version: 1,
    sleepSchedule: {
      enabled: false,
      bedtime: '22:00',
      wakeTime: '07:00',
      timeZone,
      keepFallDetectionAtNight: true,
    },
    heartRate: { enabled: true, upperBpm: 120, lowerBpm: 45, persistenceSeconds: 300, cooldownSeconds: 1800 },
    movement: { enabled: true, locationEnabled: true, inactivityThresholdMinutes: 240, locationHistoryRetentionDays: 30 },
    fallDetection: { experimentalEnabled: false, systemFallDetectionEnabled: true, confirmationCountdownSeconds: 30 },
    notifications: { push: true, sms: false, voice: false, escalationDelaySeconds: 180, contactOrder: [] },
    emergency: { automaticEmergencyServices: false, emergencyNumber: '911', contacts: [] },
    dataRetention: { telemetryDays: 30, alertDays: 365 },
    staleAfterMinutes: 120,
    updatedAt: now.toISOString(),
    updatedBy: alphaId,
  };
}

export const SETTINGS_SECTIONS: SettingsSection[] = [
  'sleepSchedule',
  'heartRate',
  'movement',
  'fallDetection',
  'notifications',
  'emergency',
  'dataRetention',
  'staleAfterMinutes',
];

/** Sections a Beta may only propose when they hold `manageEmergencyContacts`. */
export const EMERGENCY_SECTIONS: SettingsSection[] = ['emergency'];

/** Validates a partial settings patch. Each section present is validated and replaced whole. */
export function validateSettingsPatch(input: unknown): Partial<Pick<MonitoringSettings, SettingsSection>> {
  const o = obj(input, 'changes');
  const out: Partial<Pick<MonitoringSettings, SettingsSection>> = {};
  for (const key of Object.keys(o)) {
    if (!(SETTINGS_SECTIONS as string[]).includes(key)) throw badRequest(`Unknown settings section: ${key}`);
  }
  if (o.sleepSchedule !== undefined) {
    const s = obj(o.sleepSchedule, 'sleepSchedule');
    const bedtime = str(s, 'bedtime', { max: 5 });
    const wakeTime = str(s, 'wakeTime', { max: 5 });
    if (parseHHMM(bedtime) === null || parseHHMM(wakeTime) === null) throw badRequest('bedtime/wakeTime must be HH:mm');
    const timeZone = str(s, 'timeZone', { max: 64 });
    if (!isValidTimeZone(timeZone)) throw badRequest('timeZone must be an IANA time zone');
    let override: MonitoringSettings['sleepSchedule']['override'];
    if (s.override !== undefined && s.override !== null) {
      const ov = obj(s.override, 'override');
      const mode = str(ov, 'mode', { max: 16 });
      if (mode !== 'forceNight' && mode !== 'forceDay') throw badRequest('override.mode must be forceNight or forceDay');
      const until = Date.parse(str(ov, 'until', { max: 40 }));
      if (Number.isNaN(until)) throw badRequest('override.until must be ISO-8601');
      override = { mode, until: new Date(until).toISOString() };
    }
    out.sleepSchedule = {
      enabled: bool(s, 'enabled'),
      bedtime,
      wakeTime,
      timeZone,
      keepFallDetectionAtNight: bool(s, 'keepFallDetectionAtNight'),
      ...(override ? { override } : {}),
    };
  }
  if (o.heartRate !== undefined) {
    const h = obj(o.heartRate, 'heartRate');
    const upperBpm = num(h, 'upperBpm', 60, 220, { integer: true });
    const lowerBpm = num(h, 'lowerBpm', 25, 100, { integer: true });
    if (lowerBpm >= upperBpm) throw badRequest('lowerBpm must be below upperBpm');
    out.heartRate = {
      enabled: bool(h, 'enabled'),
      upperBpm,
      lowerBpm,
      persistenceSeconds: num(h, 'persistenceSeconds', 0, 3600, { integer: true }),
      cooldownSeconds: num(h, 'cooldownSeconds', 60, 86400, { integer: true }),
    };
  }
  if (o.movement !== undefined) {
    const m = obj(o.movement, 'movement');
    out.movement = {
      enabled: bool(m, 'enabled'),
      locationEnabled: bool(m, 'locationEnabled'),
      inactivityThresholdMinutes: num(m, 'inactivityThresholdMinutes', 30, 24 * 60, { integer: true }),
      locationHistoryRetentionDays: num(m, 'locationHistoryRetentionDays', 1, 90, { integer: true }),
    };
  }
  if (o.fallDetection !== undefined) {
    const f = obj(o.fallDetection, 'fallDetection');
    out.fallDetection = {
      experimentalEnabled: bool(f, 'experimentalEnabled'),
      systemFallDetectionEnabled: bool(f, 'systemFallDetectionEnabled'),
      confirmationCountdownSeconds: num(f, 'confirmationCountdownSeconds', 15, 300, { integer: true }),
    };
  }
  if (o.notifications !== undefined) {
    const n = obj(o.notifications, 'notifications');
    const contactOrder = arr(n, 'contactOrder', 20).map((v) => {
      if (typeof v !== 'string' || v.length > 64) throw badRequest('contactOrder must contain user IDs');
      return v;
    });
    out.notifications = {
      push: bool(n, 'push'),
      sms: bool(n, 'sms'),
      voice: bool(n, 'voice'),
      escalationDelaySeconds: num(n, 'escalationDelaySeconds', 30, 3600, { integer: true }),
      contactOrder,
    };
  }
  if (o.emergency !== undefined) {
    const e = obj(o.emergency, 'emergency');
    if (e.automaticEmergencyServices !== undefined && e.automaticEmergencyServices !== false) {
      throw badRequest('Automatic emergency-services contact is not supported in this version');
    }
    out.emergency = {
      automaticEmergencyServices: false,
      emergencyNumber: str(e, 'emergencyNumber', { max: 6, pattern: /^\d{2,6}$/ }),
      contacts: arr(e, 'contacts', 10).map((c, i) => {
        const co = obj(c, `contacts[${i}]`) as Json;
        const relation = optStr(co, 'relation', { max: 40 });
        return {
          name: str(co, 'name', { max: 80 }),
          phoneNumber: str(co, 'phoneNumber', { max: 16, pattern: PHONE_E164 }),
          ...(relation ? { relation } : {}),
        };
      }),
    };
  }
  if (o.dataRetention !== undefined) {
    const d = obj(o.dataRetention, 'dataRetention');
    out.dataRetention = {
      telemetryDays: num(d, 'telemetryDays', 1, 90, { integer: true }),
      alertDays: num(d, 'alertDays', 30, 730, { integer: true }),
    };
  }
  if (o.staleAfterMinutes !== undefined) {
    out.staleAfterMinutes = num(o, 'staleAfterMinutes', 15, 24 * 60, { integer: true });
  }
  return out;
}

export function applySettingsPatch(
  current: MonitoringSettings,
  patch: Partial<Pick<MonitoringSettings, SettingsSection>>,
  actorId: string,
  now: Date,
): MonitoringSettings {
  return { ...current, ...patch, version: current.version + 1, updatedAt: now.toISOString(), updatedBy: actorId };
}
