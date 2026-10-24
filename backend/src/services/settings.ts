import type { Principal } from '../auth/auth.ts';
import { conflict, forbidden, notFound } from '../domain/errors.ts';
import { sortableId } from '../domain/ids.ts';
import { EMERGENCY_SECTIONS, applySettingsPatch, defaultSettings, validateSettingsPatch } from '../domain/settings.ts';
import type { MonitoringSettings, SettingsChangeRequest, SettingsSection } from '../domain/types.ts';
import { num, obj, optStr } from '../domain/validation.ts';
import { ConditionFailedError } from '../store/table.ts';
import { audit, authorizeAlphaAccess, requireProfile } from './access.ts';
import type { Deps } from './deps.ts';

async function loadSettings(deps: Deps, alphaId: string): Promise<MonitoringSettings> {
  return (await deps.repo.getSettings(alphaId)) ?? defaultSettings(alphaId, 'UTC', deps.now());
}

export async function getSettings(deps: Deps, principal: Principal, alphaId: string): Promise<{ settings: MonitoringSettings }> {
  const access = await authorizeAlphaAccess(deps, principal.userId, alphaId, null);
  const settings = await loadSettings(deps, alphaId);
  // Emergency contacts are only visible to the Alpha and Betas allowed to manage them.
  if (!access.self && !access.relationship?.permissions.manageEmergencyContacts) {
    return { settings: { ...settings, emergency: { ...settings.emergency, contacts: [] } } };
  }
  return { settings };
}

/** Direct update by the Alpha. `version` must match the stored version (optimistic locking). */
export async function updateOwnSettings(deps: Deps, principal: Principal, body: unknown): Promise<{ settings: MonitoringSettings }> {
  await requireProfile(deps, principal.userId, 'alpha');
  const o = obj(body);
  const version = num(o, 'version', 1, Number.MAX_SAFE_INTEGER, { integer: true });
  const patch = validateSettingsPatch(o.changes);
  const current = await loadSettings(deps, principal.userId);
  if (current.version !== version) throw conflict('Settings changed on another device; reload and retry');
  const next = applySettingsPatch(current, patch, principal.userId, deps.now());
  try {
    await deps.repo.putSettings(next, current.version);
  } catch (err) {
    if (err instanceof ConditionFailedError) throw conflict('Settings changed on another device; reload and retry');
    throw err;
  }
  await audit(deps, principal.userId, principal.userId, 'settings.updated', { sections: Object.keys(patch).join(','), version: next.version });
  return { settings: next };
}

/** A Beta proposes a change. Nothing is applied until the Alpha approves it. */
export async function requestSettingsChange(deps: Deps, principal: Principal, alphaId: string, body: unknown): Promise<{ request: SettingsChangeRequest }> {
  const access = await authorizeAlphaAccess(deps, principal.userId, alphaId, null);
  if (access.self) throw conflict('Alphas update their settings directly');
  const o = obj(body);
  const changes = validateSettingsPatch(o.changes);
  const sections = Object.keys(changes) as SettingsSection[];
  if (sections.length === 0) throw conflict('No changes requested');
  const perms = access.relationship!.permissions;
  for (const section of sections) {
    const needed = EMERGENCY_SECTIONS.includes(section) ? perms.manageEmergencyContacts : perms.manageSettings;
    if (!needed) throw forbidden(`You do not have permission to change ${section}`);
  }
  const beta = await requireProfile(deps, principal.userId);
  const now = deps.now();
  const reason = optStr(o, 'reason', { max: 280 });
  const request: SettingsChangeRequest = {
    requestId: sortableId(now),
    alphaId,
    requestedBy: principal.userId,
    requestedByName: beta.name,
    changes,
    status: 'pending',
    createdAt: now.toISOString(),
    ...(reason ? { reason } : {}),
  };
  await deps.repo.putChangeRequest(request);
  await audit(deps, alphaId, principal.userId, 'settings.change_requested', { requestId: request.requestId, sections: sections.join(',') });
  for (const d of (await deps.repo.listDevices(alphaId)).filter((x) => x.apnsToken)) {
    await deps.providers.push.send({
      deviceToken: d.apnsToken!,
      environment: d.apnsEnvironment ?? 'production',
      title: `${beta.name} suggested a settings change`,
      body: 'Open Wellder to review it. Nothing changes unless you approve.',
      interruptionLevel: 'active',
      threadId: 'settings',
      data: { requestId: request.requestId },
    });
  }
  return { request };
}

export async function listSettingsRequests(deps: Deps, principal: Principal, alphaId: string): Promise<{ requests: SettingsChangeRequest[] }> {
  const access = await authorizeAlphaAccess(deps, principal.userId, alphaId, null);
  const all = await deps.repo.listChangeRequests(alphaId);
  return { requests: access.self ? all : all.filter((r) => r.requestedBy === principal.userId) };
}

export async function decideSettingsRequest(
  deps: Deps,
  principal: Principal,
  requestId: string,
  approve: boolean,
): Promise<{ request: SettingsChangeRequest; settings: MonitoringSettings }> {
  await requireProfile(deps, principal.userId, 'alpha');
  const req = await deps.repo.getChangeRequest(principal.userId, requestId);
  if (!req) throw notFound();
  if (req.status !== 'pending') throw conflict('Request was already decided');
  const now = deps.now();
  let settings = await loadSettings(deps, principal.userId);
  if (approve) {
    // Re-check: the Beta may have lost permission since asking.
    const rel = await deps.repo.getRelationship(principal.userId, req.requestedBy);
    const stillAllowed =
      rel?.status === 'active' &&
      (Object.keys(req.changes) as SettingsSection[]).every((s) =>
        EMERGENCY_SECTIONS.includes(s) ? rel.permissions.manageEmergencyContacts : rel.permissions.manageSettings,
      );
    if (!stillAllowed) {
      await deps.repo.putChangeRequest({ ...req, status: 'superseded', decidedAt: now.toISOString() });
      throw conflict('The requesting caregiver is no longer connected or no longer has this permission');
    }
    const next = applySettingsPatch(settings, req.changes, req.requestedBy, now);
    try {
      await deps.repo.putSettings(next, settings.version);
    } catch (err) {
      if (err instanceof ConditionFailedError) throw conflict('Settings changed concurrently; retry');
      throw err;
    }
    settings = next;
  }
  const decided: SettingsChangeRequest = { ...req, status: approve ? 'approved' : 'rejected', decidedAt: now.toISOString() };
  await deps.repo.putChangeRequest(decided);
  await audit(deps, principal.userId, principal.userId, approve ? 'settings.change_approved' : 'settings.change_rejected', {
    requestId,
    requestedBy: req.requestedBy,
    sections: Object.keys(req.changes).join(','),
  });
  return { request: decided, settings };
}

export async function getAuditLog(deps: Deps, principal: Principal) {
  await requireProfile(deps, principal.userId, 'alpha');
  return { entries: await deps.repo.listAudit(principal.userId) };
}
