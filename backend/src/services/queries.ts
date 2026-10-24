import type { Principal } from '../auth/auth.ts';
import { forbidden } from '../domain/errors.ts';
import { isNightTime } from '../domain/schedule.ts';
import { defaultSettings } from '../domain/settings.ts';
import type { Alert, AlertDelivery, MonitoringRelationship, MonitoringSettings, MonitorSnapshot, PermissionSet } from '../domain/types.ts';
import { obj, oneOf, parseTimeRange } from '../domain/validation.ts';
import { authorizeAlphaAccess, can, requireProfile, type AlphaAccess } from './access.ts';
import { AlertEngine, assertResolution } from './alerts.ts';
import type { Deps } from './deps.ts';

export type StatusLevel = 'green' | 'yellow' | 'red' | 'gray';

export interface AlphaSummary {
  alphaId: string;
  name: string;
  permissions: PermissionSet | 'self';
  status: StatusLevel;
  statusReason: string;
  isNight: boolean;
  snapshot: MonitorSnapshot; // fields the caller may not see are removed
  openAlerts: Alert[];
  staleAfterMinutes: number;
}

/** Removes fields the caller is not permitted to see. */
function filterSnapshot(s: MonitorSnapshot, access: AlphaAccess): MonitorSnapshot {
  const out: MonitorSnapshot = { ...s };
  if (!can(access, 'viewHeartRate')) delete out.lastHeartRate;
  if (!can(access, 'viewLocation')) delete out.lastLocation;
  if (!can(access, 'viewActivity')) {
    delete out.lastActivity;
    delete out.lastMovementAt;
    delete out.recentSteps;
    delete out.lastInteractionAt;
  }
  return out;
}

function filterAlert(a: Alert, access: AlphaAccess): Alert {
  if (can(access, 'viewHeartRate') || !a.evidence) return a;
  const { extremeBpm: _x, ...rest } = a.evidence;
  void _x;
  const message = a.type === 'heartRateHigh' || a.type === 'heartRateLow' ? 'Heart rate outside the configured range.' : a.message;
  return { ...a, message, evidence: rest };
}

/**
 * Traffic-light status. Missing or stale data is GRAY — never green: the absence of telemetry
 * is not evidence that the Alpha is safe.
 */
export function computeStatus(snapshot: MonitorSnapshot | undefined, openAlerts: Alert[], settings: MonitoringSettings, now: Date): { status: StatusLevel; reason: string } {
  const unresolved = openAlerts.filter((a) => a.status !== 'resolved');
  const criticalUnacked = unresolved.find((a) => a.severity === 'critical' && a.status !== 'acknowledged' && a.category === 'safety');
  if (criticalUnacked) return { status: 'red', reason: criticalUnacked.title };
  if (!snapshot?.lastSyncAt) return { status: 'gray', reason: 'No data received yet' };
  const ageMin = (now.getTime() - Date.parse(snapshot.lastSyncAt)) / 60000;
  if (ageMin > settings.staleAfterMinutes) return { status: 'gray', reason: `No data for ${Math.round(ageMin)} min` };
  if (unresolved.length > 0) return { status: 'yellow', reason: unresolved[0]!.title };
  return { status: 'green', reason: 'No currently detected concern' };
}

async function summarize(deps: Deps, alphaId: string, name: string, access: AlphaAccess, rel?: MonitoringRelationship): Promise<AlphaSummary> {
  const now = deps.now();
  const settings = (await deps.repo.getSettings(alphaId)) ?? defaultSettings(alphaId, 'UTC', now);
  const snapshot = (await deps.repo.getSnapshot(alphaId)) ?? { alphaId };
  const { alerts } = await deps.repo.listAlerts(alphaId, { limit: 25 });
  const open = alerts.filter((a) => a.status !== 'resolved');
  const { status, reason } = computeStatus(snapshot, open, settings, now);
  const canSeeAlerts = can(access, 'receiveAlerts');
  return {
    alphaId,
    name,
    permissions: access.self ? 'self' : rel!.permissions,
    status: canSeeAlerts || status !== 'red' ? status : 'yellow',
    statusReason: canSeeAlerts ? reason : status === 'gray' ? reason : 'Shared data available',
    isNight: isNightTime(settings.sleepSchedule, now),
    snapshot: filterSnapshot(snapshot, access),
    openAlerts: canSeeAlerts ? open.map((a) => filterAlert(a, access)) : [],
    staleAfterMinutes: settings.staleAfterMinutes,
  };
}

export async function dashboard(deps: Deps, principal: Principal): Promise<{ alphas: AlphaSummary[]; pending: MonitoringRelationship[] }> {
  await requireProfile(deps, principal.userId, 'beta');
  const rels = await deps.repo.listRelationshipsForBeta(principal.userId);
  const active = rels.filter((r) => r.status === 'active');
  const alphas = await Promise.all(active.map((r) => summarize(deps, r.alphaId, r.alphaName, { self: false, relationship: r }, r)));
  const order: Record<StatusLevel, number> = { red: 0, yellow: 1, gray: 2, green: 3 };
  alphas.sort((a, b) => order[a.status] - order[b.status] || a.name.localeCompare(b.name));
  const engine = new AlertEngine(deps);
  await engine.markFetchedInApp(principal.userId, alphas.flatMap((a) => a.openAlerts));
  return { alphas, pending: rels.filter((r) => r.status === 'pendingAlphaApproval') };
}

export async function alphaSummary(deps: Deps, principal: Principal, alphaId: string): Promise<{ summary: AlphaSummary }> {
  const access = await authorizeAlphaAccess(deps, principal.userId, alphaId, null);
  const name = access.self ? (await requireProfile(deps, alphaId)).name : access.relationship!.alphaName;
  const summary = await summarize(deps, alphaId, name, access, access.relationship);
  if (!access.self) await new AlertEngine(deps).markFetchedInApp(principal.userId, summary.openAlerts);
  return { summary };
}

const MAX_POINTS = 5000;

export async function locationHistory(deps: Deps, principal: Principal, alphaId: string, query: Record<string, string | undefined>) {
  const access = await authorizeAlphaAccess(deps, principal.userId, alphaId, 'viewLocation');
  if (!can(access, 'viewMovementHistory')) throw forbidden('Movement history is not shared with you');
  const { from, to } = parseTimeRange(query, deps.now());
  const { samples, cursor } = await deps.repo.querySamples(alphaId, 'location', from, to, { limit: MAX_POINTS, ...(query.cursor ? { cursor: query.cursor } : {}) });
  return { from, to, samples, ...(cursor ? { cursor } : {}) };
}

export async function heartRateHistory(deps: Deps, principal: Principal, alphaId: string, query: Record<string, string | undefined>) {
  await authorizeAlphaAccess(deps, principal.userId, alphaId, 'viewHeartRate');
  const { from, to } = parseTimeRange(query, deps.now());
  const { samples, cursor } = await deps.repo.querySamples(alphaId, 'heartRate', from, to, { limit: MAX_POINTS, ...(query.cursor ? { cursor: query.cursor } : {}) });
  const bpms = samples.map((s) => s.bpm);
  const settings = (await deps.repo.getSettings(alphaId)) ?? defaultSettings(alphaId, 'UTC', deps.now());
  return {
    from,
    to,
    samples,
    stats: bpms.length ? { min: Math.min(...bpms), max: Math.max(...bpms), count: bpms.length } : null,
    thresholds: { upperBpm: settings.heartRate.upperBpm, lowerBpm: settings.heartRate.lowerBpm },
    ...(cursor ? { cursor } : {}),
  };
}

export async function activityHistory(deps: Deps, principal: Principal, alphaId: string, query: Record<string, string | undefined>) {
  await authorizeAlphaAccess(deps, principal.userId, alphaId, 'viewActivity');
  const { from, to } = parseTimeRange(query, deps.now());
  const [activity, steps, interactions] = await Promise.all([
    deps.repo.querySamples(alphaId, 'activity', from, to, { limit: MAX_POINTS }),
    deps.repo.querySamples(alphaId, 'steps', from, to, { limit: MAX_POINTS }),
    deps.repo.querySamples(alphaId, 'interaction', from, to, { limit: MAX_POINTS }),
  ]);
  return { from, to, activity: activity.samples, steps: steps.samples, interactions: interactions.samples };
}

export async function listAlerts(deps: Deps, principal: Principal, alphaId: string, query: Record<string, string | undefined>) {
  const access = await authorizeAlphaAccess(deps, principal.userId, alphaId, null);
  if (!can(access, 'receiveAlerts')) throw forbidden('Alerts are not shared with you');
  const limit = Math.min(Math.max(Number(query.limit ?? 50) || 50, 1), 100);
  const { alerts, cursor } = await deps.repo.listAlerts(alphaId, { limit, ...(query.cursor ? { cursor: query.cursor } : {}) });
  if (!access.self) await new AlertEngine(deps).markFetchedInApp(principal.userId, alerts);
  return { alerts: alerts.map((a) => filterAlert(a, access)), ...(cursor ? { cursor } : {}) };
}

export async function alertDetail(deps: Deps, principal: Principal, alphaId: string, alertId: string): Promise<{ alert: Alert; deliveries: AlertDelivery[] }> {
  const access = await authorizeAlphaAccess(deps, principal.userId, alphaId, null);
  if (!can(access, 'receiveAlerts')) throw forbidden();
  const alert = await deps.repo.getAlert(alphaId, alertId);
  if (!alert) throw forbidden();
  const deliveries = await deps.repo.listDeliveries(alphaId, alertId);
  return { alert: filterAlert(alert, access), deliveries: access.self ? deliveries : deliveries.filter((d) => d.betaId === principal.userId) };
}

export async function acknowledgeAlert(deps: Deps, principal: Principal, alphaId: string, alertId: string) {
  const access = await authorizeAlphaAccess(deps, principal.userId, alphaId, 'receiveAlerts');
  if (access.self) throw forbidden('Alerts are acknowledged by caregivers');
  return { alert: await new AlertEngine(deps).acknowledge(principal.userId, alphaId, alertId) };
}

/**
 * The Alpha's answer during the false-alarm window of an `awaitingAlphaResponse` alert:
 * `ok` (false alarm) resolves it without notifying anyone; `help` or `noResponse` (countdown ran
 * out on the device) notifies caregivers now instead of waiting for the server's own timer.
 */
export async function respondToAlert(deps: Deps, principal: Principal, alphaId: string, alertId: string, body: unknown) {
  const access = await authorizeAlphaAccess(deps, principal.userId, alphaId, null);
  if (!access.self) throw forbidden('Only the monitored person can answer this');
  const response = oneOf(obj(body), 'response', ['ok', 'help', 'noResponse'] as const);
  const engine = new AlertEngine(deps);
  if (response === 'ok') return { alert: await engine.alphaReportsOk(alphaId, alertId) };
  // `noResponse` keeps the original message (it carries the details, redacted per caregiver).
  const name = (await deps.repo.getProfile(alphaId))?.name ?? 'They';
  const patch = response === 'help' ? { title: `${name} asked for help`, severity: 'critical' as const } : {};
  return { alert: await engine.openNow(alphaId, alertId, patch) };
}

export async function resolveAlert(deps: Deps, principal: Principal, alphaId: string, alertId: string, body: unknown) {
  const access = await authorizeAlphaAccess(deps, principal.userId, alphaId, principal.userId === alphaId ? null : 'receiveAlerts');
  const resolution = access.self ? 'alphaOk' : assertResolution((body as { resolution?: unknown } | null)?.resolution ?? 'betaResolved');
  return { alert: await new AlertEngine(deps).resolve(principal.userId, alphaId, alertId, resolution) };
}
