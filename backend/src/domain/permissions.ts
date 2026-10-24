import { PERMISSIONS, type MonitoringRelationship, type Permission, type PermissionSet } from './types.ts';

export function defaultPermissions(): PermissionSet {
  return {
    viewLocation: true,
    viewMovementHistory: true,
    viewHeartRate: true,
    viewActivity: true,
    receiveAlerts: true,
    manageSettings: false,
    manageEmergencyContacts: false,
  };
}

export function noPermissions(): PermissionSet {
  return Object.fromEntries(PERMISSIONS.map((p) => [p, false])) as PermissionSet;
}

export function hasPermission(rel: MonitoringRelationship | undefined, permission: Permission): boolean {
  return rel?.status === 'active' && rel.permissions[permission] === true;
}

export function relationshipId(alphaId: string, betaId: string): string {
  return `${alphaId}.${betaId}`;
}

export function parseRelationshipId(id: string): { alphaId: string; betaId: string } | null {
  const parts = id.split('.');
  if (parts.length !== 2 || !parts[0] || !parts[1]) return null;
  return { alphaId: parts[0], betaId: parts[1] };
}
