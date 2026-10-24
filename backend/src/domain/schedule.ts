import type { SleepSchedule } from './types.ts';

// Night-monitoring schedule evaluation.
//
// Times are compared as local wall-clock minutes in the schedule's IANA time zone, so a
// 22:00 bedtime stays 22:00 across daylight-saving transitions. Schedules where bedtime is
// later than wake time span midnight (the common case: 22:00 → 07:00).

const HHMM = /^([01]\d|2[0-3]):([0-5]\d)$/;

export function parseHHMM(value: string): number | null {
  const m = HHMM.exec(value);
  if (!m) return null;
  return Number(m[1]) * 60 + Number(m[2]);
}

export function localMinutesOfDay(at: Date, timeZone: string): number {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(at);
  const hour = Number(parts.find((p) => p.type === 'hour')?.value ?? '0');
  const minute = Number(parts.find((p) => p.type === 'minute')?.value ?? '0');
  return hour * 60 + minute;
}

export function isValidTimeZone(timeZone: string): boolean {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone });
    return true;
  } catch {
    return false;
  }
}

/** True when `minute` falls inside [start, end) on a 24h clock, wrapping past midnight. */
export function minuteInWindow(minute: number, start: number, end: number): boolean {
  if (start === end) return false; // zero-length window: never night
  return start < end ? minute >= start && minute < end : minute >= start || minute < end;
}

export function isNightTime(schedule: SleepSchedule, at: Date): boolean {
  if (schedule.override && Date.parse(schedule.override.until) > at.getTime()) {
    return schedule.override.mode === 'forceNight';
  }
  if (!schedule.enabled) return false;
  const start = parseHHMM(schedule.bedtime);
  const end = parseHHMM(schedule.wakeTime);
  if (start === null || end === null || !isValidTimeZone(schedule.timeZone)) return false;
  return minuteInWindow(localMinutesOfDay(at, schedule.timeZone), start, end);
}
