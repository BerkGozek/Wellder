import { forbidden } from '../domain/errors.ts';
import { sortableId } from '../domain/ids.ts';
import type { MonitoringRelationship, Permission, Role, UserProfile } from '../domain/types.ts';
import type { Deps } from './deps.ts';

// Server-side authorization. Every protected read/write goes through one of these helpers.
// Identity comes only from the verified token (Principal.userId); client-supplied role flags
// or Alpha IDs are treated as requests to be checked, never as facts.

export async function requireProfile(deps: Deps, userId: string, role?: Role): Promise<UserProfile> {
  const profile = await deps.repo.getProfile(userId);
  if (!profile) throw forbidden('Complete onboarding first');
  if (role && !profile.roles.includes(role)) throw forbidden(`This action requires the ${role} role`);
  return profile;
}

export interface AlphaAccess {
  self: boolean;
  relationship?: MonitoringRelationship;
}

/**
 * Grants access to an Alpha's data when the caller IS that Alpha, or holds an ACTIVE
 * relationship with the requested permission. `permission: null` means "any active link".
 * Missing Alpha and missing permission produce the same 403 so IDs cannot be probed.
 */
export async function authorizeAlphaAccess(deps: Deps, userId: string, alphaId: string, permission: Permission | null): Promise<AlphaAccess> {
  if (userId === alphaId) {
    await requireProfile(deps, userId, 'alpha');
    return { self: true };
  }
  const rel = await deps.repo.getRelationship(alphaId, userId);
  if (!rel || rel.status !== 'active') throw forbidden();
  if (permission && !rel.permissions[permission]) throw forbidden();
  return { self: false, relationship: rel };
}

export function can(access: AlphaAccess, permission: Permission): boolean {
  return access.self || access.relationship?.permissions[permission] === true;
}

export async function audit(
  deps: Deps,
  alphaId: string,
  actorId: string,
  action: string,
  detail?: Record<string, string | number | boolean>,
): Promise<void> {
  const at = deps.now();
  await deps.repo.audit({ auditId: sortableId(at), alphaId, actorId, action, at: at.toISOString(), ...(detail ? { detail } : {}) });
}
