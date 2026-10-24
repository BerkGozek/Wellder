import type { Principal } from '../auth/auth.ts';
import { badRequest, conflict, forbidden, notFound, tooManyRequests } from '../domain/errors.ts';
import { hashSecret, invitationCode, normalizeInvitationCode, uuid } from '../domain/ids.ts';
import { defaultPermissions, noPermissions, parseRelationshipId, relationshipId } from '../domain/permissions.ts';
import type { Invitation, MonitoringRelationship } from '../domain/types.ts';
import { obj, permissionSet, str } from '../domain/validation.ts';
import { audit, requireProfile } from './access.ts';
import type { Deps } from './deps.ts';

const INVITE_TTL_HOURS = 24;
const MAX_OPEN_INVITES = 10;
const REDEEM_LIMIT_PER_HOUR = 10;

async function notifyUser(deps: Deps, userId: string, title: string, body: string, data: Record<string, string>): Promise<void> {
  for (const d of (await deps.repo.listDevices(userId)).filter((x) => x.apnsToken)) {
    await deps.providers.push.send({
      deviceToken: d.apnsToken!,
      environment: d.apnsEnvironment ?? 'production',
      title,
      body,
      interruptionLevel: 'active',
      threadId: 'relationships',
      data,
    });
  }
}

export async function createInvitation(deps: Deps, principal: Principal, body: unknown): Promise<{ invitation: Invitation; code: string; link: string }> {
  const alpha = await requireProfile(deps, principal.userId, 'alpha');
  const o = body === undefined || body === null ? {} : obj(body);
  const permissions = o.permissions === undefined ? defaultPermissions() : permissionSet(o.permissions, noPermissions());
  const open = (await deps.repo.listInvitations(alpha.userId)).filter((i) => Date.parse(i.expiresAt) > deps.now().getTime());
  if (open.length >= MAX_OPEN_INVITES) throw conflict('Too many open invitations; cancel some first');

  const now = deps.now();
  const code = invitationCode();
  const invitation: Invitation = {
    invitationId: uuid(),
    alphaId: alpha.userId,
    alphaName: alpha.name,
    permissions,
    createdAt: now.toISOString(),
    expiresAt: new Date(now.getTime() + INVITE_TTL_HOURS * 3600_000).toISOString(),
    codeHint: code.slice(-2),
  };
  await deps.repo.putInvitation(hashSecret(code), invitation);
  await audit(deps, alpha.userId, alpha.userId, 'invitation.created', { invitationId: invitation.invitationId });
  return { invitation, code, link: `wellder://invite/${code}` };
}

export async function listInvitations(deps: Deps, principal: Principal): Promise<{ invitations: Invitation[] }> {
  await requireProfile(deps, principal.userId, 'alpha');
  const now = deps.now().getTime();
  const invitations = (await deps.repo.listInvitations(principal.userId))
    .filter((i) => Date.parse(i.expiresAt) > now)
    .map(({ codeHash: _h, ...rest }) => (void _h, rest));
  return { invitations };
}

export async function cancelInvitation(deps: Deps, principal: Principal, invitationId: string): Promise<{ cancelled: boolean }> {
  await requireProfile(deps, principal.userId, 'alpha');
  const inv = (await deps.repo.listInvitations(principal.userId)).find((i) => i.invitationId === invitationId);
  if (!inv) throw notFound();
  await deps.repo.deleteInvitation(inv.codeHash);
  await audit(deps, principal.userId, principal.userId, 'invitation.cancelled', { invitationId });
  return { cancelled: true };
}

/** A Beta redeems a code. The link is created as PENDING — the Alpha must still approve it,
 *  after seeing exactly who redeemed the code. Codes are single-use. */
export async function redeemInvitation(deps: Deps, principal: Principal, body: unknown): Promise<{ relationship: MonitoringRelationship }> {
  const beta = await requireProfile(deps, principal.userId, 'beta');
  const now = deps.now();
  const attempts = await deps.repo.countAttempt(beta.userId, 'redeem', 3600, now);
  if (attempts > REDEEM_LIMIT_PER_HOUR) throw tooManyRequests('Too many attempts; try again later');

  const code = normalizeInvitationCode(str(obj(body), 'code', { max: 32 }));
  const codeHash = hashSecret(code);
  const inv = await deps.repo.getInvitationByHash(codeHash);
  if (!inv || Date.parse(inv.expiresAt) <= now.getTime()) throw notFound('Invitation code is invalid or has expired');
  if (inv.alphaId === beta.userId) throw badRequest('You cannot monitor yourself');

  const existing = await deps.repo.getRelationship(inv.alphaId, beta.userId);
  if (existing && (existing.status === 'active' || existing.status === 'pendingAlphaApproval')) {
    throw conflict('You are already connected or awaiting approval');
  }
  const relationship: MonitoringRelationship = {
    relationshipId: relationshipId(inv.alphaId, beta.userId),
    alphaId: inv.alphaId,
    betaId: beta.userId,
    alphaName: inv.alphaName,
    betaName: beta.name,
    betaEmail: beta.email,
    permissions: inv.permissions,
    status: 'pendingAlphaApproval',
    createdAt: now.toISOString(),
  };
  await deps.repo.putRelationship(relationship);
  await deps.repo.deleteInvitation(codeHash);
  await audit(deps, inv.alphaId, beta.userId, 'relationship.requested', { betaId: beta.userId, invitationId: inv.invitationId });
  await notifyUser(deps, inv.alphaId, `${beta.name} wants to connect`, 'Open Wellder to approve or decline.', { relationshipId: relationship.relationshipId });
  return { relationship };
}

export async function listRelationships(deps: Deps, principal: Principal): Promise<{ asAlpha: MonitoringRelationship[]; asBeta: MonitoringRelationship[] }> {
  const profile = await requireProfile(deps, principal.userId);
  const asAlpha = profile.roles.includes('alpha') ? await deps.repo.listRelationshipsForAlpha(profile.userId) : [];
  const asBeta = profile.roles.includes('beta') ? await deps.repo.listRelationshipsForBeta(profile.userId) : [];
  return { asAlpha, asBeta };
}

async function loadForAlpha(deps: Deps, principal: Principal, id: string): Promise<MonitoringRelationship> {
  const parsed = parseRelationshipId(id);
  if (!parsed || parsed.alphaId !== principal.userId) throw forbidden();
  await requireProfile(deps, principal.userId, 'alpha');
  const rel = await deps.repo.getRelationship(parsed.alphaId, parsed.betaId);
  if (!rel) throw notFound();
  return rel;
}

export async function approveRelationship(deps: Deps, principal: Principal, id: string, body: unknown): Promise<{ relationship: MonitoringRelationship }> {
  const rel = await loadForAlpha(deps, principal, id);
  if (rel.status !== 'pendingAlphaApproval') throw conflict('Only pending requests can be approved');
  const o = body === undefined || body === null ? {} : obj(body);
  const permissions = o.permissions === undefined ? rel.permissions : permissionSet(o.permissions, rel.permissions);
  const updated: MonitoringRelationship = { ...rel, permissions, status: 'active', approvedAt: deps.now().toISOString() };
  await deps.repo.putRelationship(updated);
  await audit(deps, rel.alphaId, principal.userId, 'relationship.approved', { betaId: rel.betaId });
  await notifyUser(deps, rel.betaId, `${rel.alphaName} approved your request`, 'You can now see their shared information.', { relationshipId: rel.relationshipId });
  return { relationship: updated };
}

export async function rejectRelationship(deps: Deps, principal: Principal, id: string): Promise<{ relationship: MonitoringRelationship }> {
  const rel = await loadForAlpha(deps, principal, id);
  if (rel.status !== 'pendingAlphaApproval') throw conflict('Only pending requests can be rejected');
  const updated: MonitoringRelationship = { ...rel, status: 'rejected', permissions: noPermissions() };
  await deps.repo.putRelationship(updated);
  await audit(deps, rel.alphaId, principal.userId, 'relationship.rejected', { betaId: rel.betaId });
  return { relationship: updated };
}

/** Either party can end a link. Takes effect immediately: every data read re-checks status. */
export async function revokeRelationship(deps: Deps, principal: Principal, id: string): Promise<{ relationship: MonitoringRelationship }> {
  const parsed = parseRelationshipId(id);
  if (!parsed || (parsed.alphaId !== principal.userId && parsed.betaId !== principal.userId)) throw forbidden();
  const rel = await deps.repo.getRelationship(parsed.alphaId, parsed.betaId);
  if (!rel) throw notFound();
  if (rel.status === 'revoked') return { relationship: rel };
  const by = parsed.alphaId === principal.userId ? 'alpha' : 'beta';
  const updated: MonitoringRelationship = {
    ...rel,
    status: 'revoked',
    permissions: noPermissions(),
    revokedAt: deps.now().toISOString(),
    revokedBy: by,
  };
  await deps.repo.putRelationship(updated);
  await audit(deps, rel.alphaId, principal.userId, 'relationship.revoked', { betaId: rel.betaId, by });
  return { relationship: updated };
}

export async function updatePermissions(deps: Deps, principal: Principal, id: string, body: unknown): Promise<{ relationship: MonitoringRelationship }> {
  const rel = await loadForAlpha(deps, principal, id);
  if (rel.status !== 'active' && rel.status !== 'pendingAlphaApproval') throw conflict('Relationship is not active');
  const permissions = permissionSet(obj(body).permissions, rel.permissions);
  const updated = { ...rel, permissions };
  await deps.repo.putRelationship(updated);
  const changed = Object.fromEntries(Object.entries(permissions).filter(([k, v]) => rel.permissions[k as keyof typeof permissions] !== v));
  await audit(deps, rel.alphaId, principal.userId, 'relationship.permissions_changed', { betaId: rel.betaId, ...changed });
  return { relationship: updated };
}
