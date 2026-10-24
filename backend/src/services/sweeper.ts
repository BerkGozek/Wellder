import { isNightTime, localMinutesOfDay, parseHHMM } from '../domain/schedule.ts';
import { defaultSettings } from '../domain/settings.ts';
import type { MonitoringSettings, MonitorSnapshot } from '../domain/types.ts';
import { SHARDS } from '../store/repository.ts';
import { AlertEngine } from './alerts.ts';
import type { Deps } from './deps.ts';

// Periodic background work (EventBridge every minute in AWS; a timer in local dev):
//   1. due escalation steps (including the possible-fall no-response fallback)
//   2. monitoring interruptions (no data for `staleAfterMinutes`)
//   3. prolonged inactivity — only when data IS flowing, so "no data" is never mistaken for
//      "not moving", and never during the night window.

/** Most recent wake-up time before `now`, so inactivity is not counted across the night. */
export function lastWakeTime(settings: MonitoringSettings, now: Date): Date | null {
  const s = settings.sleepSchedule;
  if (!s.enabled) return null;
  const wake = parseHHMM(s.wakeTime);
  if (wake === null) return null;
  const minutesSinceWake = (localMinutesOfDay(now, s.timeZone) - wake + 1440) % 1440;
  return new Date(now.getTime() - minutesSinceWake * 60_000);
}

export function inactivityReference(snapshot: MonitorSnapshot, settings: MonitoringSettings, now: Date): Date | null {
  const candidates = [snapshot.lastMovementAt, snapshot.lastInteractionAt].filter((x): x is string => !!x).map((x) => Date.parse(x));
  const wake = lastWakeTime(settings, now);
  if (wake) candidates.push(wake.getTime());
  return candidates.length ? new Date(Math.max(...candidates)) : null;
}

export interface SweepReport {
  escalations: number;
  alphasChecked: number;
  interruptions: number;
  inactivity: number;
}

export async function sweep(deps: Deps): Promise<SweepReport> {
  const engine = new AlertEngine(deps);
  const now = deps.now();
  const report: SweepReport = { escalations: 0, alphasChecked: 0, interruptions: 0, inactivity: 0 };

  for (let shard = 0; shard < SHARDS; shard++) {
    for (const due of await deps.repo.dueEscalations(shard, now.toISOString())) {
      try {
        await engine.processDueEscalation(due.alphaId, due.alertId);
        report.escalations++;
      } catch (err) {
        deps.log.error('sweep.escalation_failed', { alertId: due.alertId, error: (err as Error).name });
      }
    }
  }

  for (let shard = 0; shard < SHARDS; shard++) {
    let cursor: string | undefined;
    do {
      const page = await deps.repo.listMonitoredAlphaIds(shard, cursor);
      cursor = page.cursor;
      for (const alphaId of page.ids) {
        try {
          const r = await checkAlpha(deps, engine, alphaId, now);
          report.alphasChecked++;
          if (r === 'interrupted') report.interruptions++;
          if (r === 'inactive') report.inactivity++;
        } catch (err) {
          deps.log.error('sweep.alpha_failed', { alphaId, error: (err as Error).name });
        }
      }
    } while (cursor);
  }
  if (report.escalations || report.interruptions || report.inactivity) deps.log.info('sweep.done', { ...report });
  return report;
}

async function checkAlpha(deps: Deps, engine: AlertEngine, alphaId: string, now: Date): Promise<'ok' | 'interrupted' | 'inactive' | 'skipped'> {
  const rels = (await deps.repo.listRelationshipsForAlpha(alphaId)).filter((r) => r.status === 'active');
  if (rels.length === 0) return 'skipped';
  const snapshot = await deps.repo.getSnapshot(alphaId);
  if (!snapshot?.lastSyncAt) return 'skipped';
  const settings = (await deps.repo.getSettings(alphaId)) ?? defaultSettings(alphaId, 'UTC', now);
  const name = (await deps.repo.getProfile(alphaId))?.name ?? 'Your contact';

  const silentMinutes = (now.getTime() - Date.parse(snapshot.lastSyncAt)) / 60_000;
  if (silentMinutes > settings.staleAfterMinutes) {
    const r = await engine.raise({
      alphaId,
      type: 'monitoringInterrupted',
      severity: 'warning',
      title: 'Monitoring data not received',
      message: `No data has been received from ${name}'s devices since ${snapshot.lastSyncAt}. The phone may be off, out of battery, offline, or the app may have been closed. This does not mean they are unsafe or safe.`,
      detectedAt: now.toISOString(),
      simulated: snapshot.simulated === true,
      cooldownSeconds: 6 * 3600,
    });
    return r.created ? 'interrupted' : 'ok';
  }

  if (!settings.movement.enabled || isNightTime(settings.sleepSchedule, now)) return 'ok';
  const devices = await deps.repo.listDevices(alphaId);
  const canSenseMotion = devices.some((d) => d.deviceType === 'iPhone' && (d.capabilities.motionActivity || d.capabilities.pedometer));
  if (!canSenseMotion) return 'ok';
  const ref = inactivityReference(snapshot, settings, now);
  if (!ref) return 'ok';
  const inactiveMinutes = (now.getTime() - ref.getTime()) / 60_000;
  if (inactiveMinutes < settings.movement.inactivityThresholdMinutes) return 'ok';
  const r = await engine.raise({
    alphaId,
    type: 'prolongedInactivity',
    severity: 'warning',
    title: 'No movement detected recently',
    message: `${name}'s phone has not detected walking or app use for about ${Math.round(inactiveMinutes / 60)} h. They may simply not be carrying the phone.`,
    detectedAt: now.toISOString(),
    simulated: snapshot.simulated === true,
    cooldownSeconds: settings.movement.inactivityThresholdMinutes * 60,
    evidence: { inactiveMinutes: Math.round(inactiveMinutes), since: ref.toISOString() },
  });
  return r.created ? 'inactive' : 'ok';
}
