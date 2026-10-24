import type { Principal } from '../auth/auth.ts';
import { badRequest, conflict } from '../domain/errors.ts';
import { isValidTimeZone } from '../domain/schedule.ts';
import { defaultSettings } from '../domain/settings.ts';
import type { Device, DeviceCapabilities, MonitoringState, Role, UserProfile } from '../domain/types.ts';
import { PHONE_E164, UUIDISH, arr, bool, obj, oneOf, optNum, optStr, str } from '../domain/validation.ts';
import { ConditionFailedError } from '../store/table.ts';
import { audit, requireProfile } from './access.ts';
import type { Deps } from './deps.ts';

const SAMPLE_KINDS = ['heartRate', 'location', 'activity', 'steps', 'interaction'] as const;

export async function getMe(deps: Deps, principal: Principal): Promise<{ profile: UserProfile | null }> {
  return { profile: (await deps.repo.getProfile(principal.userId)) ?? null };
}

/** Creates or updates the caller's profile. Roles can be added; removing the Alpha role requires
 *  that no caregivers are linked (so monitoring never silently disappears). */
export async function putMe(deps: Deps, principal: Principal, body: unknown): Promise<{ profile: UserProfile }> {
  const o = obj(body);
  const name = str(o, 'name', { max: 80 });
  const phoneNumber = optStr(o, 'phoneNumber', { max: 16, pattern: PHONE_E164 });
  const roles = [...new Set(arr(o, 'roles', 2).map((r) => (r === 'alpha' || r === 'beta' ? r : null)))] as (Role | null)[];
  if (roles.length === 0 || roles.includes(null)) throw badRequest('roles must contain "alpha" and/or "beta"');
  const timeZone = optStr(o, 'timeZone', { max: 64 }) ?? 'UTC';
  if (!isValidTimeZone(timeZone)) throw badRequest('timeZone must be an IANA time zone');

  const now = deps.now();
  const existing = await deps.repo.getProfile(principal.userId);
  if (existing?.roles.includes('alpha') && !roles.includes('alpha')) {
    const linked = (await deps.repo.listRelationshipsForAlpha(principal.userId)).some((r) => r.status === 'active' || r.status === 'pendingAlphaApproval');
    if (linked) throw conflict('Remove all caregivers before removing the Alpha role');
  }
  const profile: UserProfile = {
    userId: principal.userId,
    name,
    email: principal.email || existing?.email || '',
    ...(phoneNumber ? { phoneNumber } : {}),
    roles: roles as Role[],
    authenticationProvider: principal.provider,
    createdAt: existing?.createdAt ?? now.toISOString(),
    updatedAt: now.toISOString(),
  };
  await deps.repo.putProfile(profile);
  if (roles.includes('alpha') && !(await deps.repo.getSettings(principal.userId))) {
    try {
      await deps.repo.putSettings(defaultSettings(principal.userId, timeZone, now));
    } catch (err) {
      if (!(err instanceof ConditionFailedError)) throw err;
    }
    await audit(deps, principal.userId, principal.userId, 'alpha.onboarded');
  }
  return { profile };
}

export async function putDevice(deps: Deps, principal: Principal, deviceId: string, body: unknown): Promise<{ device: Device }> {
  if (!UUIDISH.test(deviceId)) throw badRequest('deviceId has an invalid format');
  await requireProfile(deps, principal.userId);
  const o = obj(body);
  const caps = obj(o.capabilities, 'capabilities');
  const capabilities: DeviceCapabilities = {
    healthKit: bool(caps, 'healthKit'),
    heartRate: bool(caps, 'heartRate'),
    backgroundLocation: bool(caps, 'backgroundLocation'),
    motionActivity: bool(caps, 'motionActivity'),
    pedometer: bool(caps, 'pedometer'),
    systemFallDetection: bool(caps, 'systemFallDetection'),
    experimentalFallDetection: bool(caps, 'experimentalFallDetection'),
    pushNotifications: bool(caps, 'pushNotifications'),
  };
  const apnsToken = optStr(o, 'apnsToken', { max: 200, pattern: /^[0-9a-fA-F]{32,200}$/ });
  const states: MonitoringState[] = ['active', 'reduced', 'night', 'temporarilyDisconnected', 'permissionsUnavailable', 'dataStale', 'disabled'];
  const batteryLevel = optNum(o, 'batteryLevel', 0, 1);
  const model = optStr(o, 'model', { max: 64 });
  const osVersion = optStr(o, 'osVersion', { max: 32 });
  const device: Device = {
    deviceId,
    userId: principal.userId,
    deviceType: oneOf(o, 'deviceType', ['iPhone', 'appleWatch'] as const),
    appVersion: str(o, 'appVersion', { max: 32 }),
    capabilities,
    monitoringState: oneOf(o, 'monitoringState', states),
    lastSeen: deps.now().toISOString(),
    ...(model ? { model } : {}),
    ...(osVersion ? { osVersion } : {}),
    ...(apnsToken ? { apnsToken, apnsEnvironment: oneOf(o, 'apnsEnvironment', ['sandbox', 'production'] as const) } : {}),
    ...(batteryLevel !== undefined ? { batteryLevel } : {}),
  };
  await deps.repo.putDevice(device);
  return { device };
}

/** Deletes the caller's data. Alpha: all telemetry, alerts, settings, audit, links.
 *  Beta: their links are removed (and recorded in each Alpha's audit log). */
export async function deleteMe(deps: Deps, principal: Principal): Promise<{ deleted: number }> {
  const uid = principal.userId;
  let deleted = 0;
  for (const rel of await deps.repo.listRelationshipsForBeta(uid)) {
    await deps.repo.deleteRelationship(rel.alphaId, uid);
    await audit(deps, rel.alphaId, uid, 'relationship.removed', { reason: 'caregiver account deleted' });
    deleted++;
  }
  for (const rel of await deps.repo.listRelationshipsForAlpha(uid)) {
    await deps.repo.deleteRelationship(uid, rel.betaId);
    deleted++;
  }
  for (const inv of await deps.repo.listInvitations(uid)) {
    await deps.repo.deleteInvitation(inv.codeHash);
    deleted++;
  }
  for (const kind of SAMPLE_KINDS) deleted += await deps.repo.deletePartition(`T#${uid}#${kind}`);
  deleted += await deps.repo.deletePartition(`ALPHA#${uid}`);
  deleted += await deps.repo.deletePartition(`USER#${uid}`);
  await deps.deleteIdentity?.(principal);
  deps.log.info('account.deleted', { userId: uid, items: deleted });
  return { deleted };
}
