import { createHash } from 'node:crypto';
import type {
  Alert,
  AlertDelivery,
  AlertType,
  AuditEntry,
  Device,
  DeviceEvent,
  Invitation,
  MonitoringRelationship,
  MonitoringSettings,
  MonitorSnapshot,
  SampleKind,
  SettingsChangeRequest,
  TelemetrySample,
  UserProfile,
} from '../domain/types.ts';
import { ConditionFailedError, type Item, type Table } from './table.ts';

// Single-table key design (documented in docs/architecture.md#data-model):
//
//   pk                      sk                         gsi1pk / gsi1sk            gsi2pk / gsi2sk
//   USER#<uid>              PROFILE
//   USER#<uid>              SETTINGS
//   USER#<uid>              DEVICE#<deviceId>
//   USER#<uid>              SNAPSHOT                                              MONITOR#<shard> / <uid>
//   ALPHA#<a>               REL#<b>                    BETA#<b> / REL#<a>
//   INVITE#<sha256(code)>   INVITE                     INVITES#<a> / <createdAt>
//   T#<a>#<kind>            <timestamp>#<sampleId>     (TTL = retention)
//   ALPHA#<a>               EVENT#<eventId>            (idempotency marker, TTL 30d)
//   ALPHA#<a>               ALERT#<alertId>                                       ESCALATION#<shard> / <nextAt>#<a>#<alertId>
//   ALPHA#<a>               ACTIVE#<alertType>         (one open alert per type: dedupe lock)
//   ALPHA#<a>               COOLDOWN#<alertType>       (TTL = cooldown end)
//   ALPHA#<a>               DELIVERY#<alertId>#<id>
//   ALPHA#<a>               SCR#<requestId>
//   ALPHA#<a>               AUDIT#<auditId>            (TTL 1y)
//   RATE#<uid>#<bucket>     RATE                       (TTL = window end)

export const SHARDS = 4;
const DAY = 86400;

export function shardOf(id: string): number {
  return createHash('sha1').update(id).digest()[0]! % SHARDS;
}

const epoch = (iso: string) => Math.floor(Date.parse(iso) / 1000);

function strip<T>(item: Item | undefined): T | undefined {
  if (!item) return undefined;
  const { pk, sk, gsi1pk, gsi1sk, gsi2pk, gsi2sk, ttl, ...rest } = item;
  void pk, sk, gsi1pk, gsi1sk, gsi2pk, gsi2sk, ttl;
  return rest as T;
}

export class Repository {
  readonly table: Table;

  constructor(table: Table) {
    this.table = table;
  }

  // ---------- Users ----------

  async getProfile(userId: string): Promise<UserProfile | undefined> {
    return strip(await this.table.get(`USER#${userId}`, 'PROFILE'));
  }

  async putProfile(p: UserProfile): Promise<void> {
    await this.table.put({ pk: `USER#${p.userId}`, sk: 'PROFILE', ...p });
  }

  async getSettings(alphaId: string): Promise<MonitoringSettings | undefined> {
    return strip(await this.table.get(`USER#${alphaId}`, 'SETTINGS'));
  }

  /** Optimistic concurrency: `expectedVersion` undefined means "must not exist yet". */
  async putSettings(s: MonitoringSettings, expectedVersion?: number): Promise<void> {
    await this.table.put(
      { pk: `USER#${s.alphaId}`, sk: 'SETTINGS', ...s },
      expectedVersion === undefined ? { kind: 'notExists' } : { kind: 'versionEquals', version: expectedVersion },
    );
  }

  // ---------- Devices ----------

  async putDevice(d: Device): Promise<void> {
    await this.table.put({ pk: `USER#${d.userId}`, sk: `DEVICE#${d.deviceId}`, ...d });
  }

  async getDevice(userId: string, deviceId: string): Promise<Device | undefined> {
    return strip(await this.table.get(`USER#${userId}`, `DEVICE#${deviceId}`));
  }

  async listDevices(userId: string): Promise<Device[]> {
    const res = await this.table.query({ pk: `USER#${userId}`, sk: { beginsWith: 'DEVICE#' } });
    return res.items.map((i) => strip<Device>(i)!);
  }

  // ---------- Snapshot ----------

  async getSnapshot(alphaId: string): Promise<MonitorSnapshot | undefined> {
    return strip(await this.table.get(`USER#${alphaId}`, 'SNAPSHOT'));
  }

  async putSnapshot(s: MonitorSnapshot): Promise<void> {
    await this.table.put({
      pk: `USER#${s.alphaId}`,
      sk: 'SNAPSHOT',
      gsi2pk: `MONITOR#${shardOf(s.alphaId)}`,
      gsi2sk: s.alphaId,
      ...s,
    });
  }

  async listMonitoredAlphaIds(shard: number, cursor?: string): Promise<{ ids: string[]; cursor?: string }> {
    const res = await this.table.query({ index: 'gsi2', pk: `MONITOR#${shard}`, limit: 200, ...(cursor ? { cursor } : {}) });
    return { ids: res.items.map((i) => i.alphaId as string), ...(res.cursor ? { cursor: res.cursor } : {}) };
  }

  // ---------- Relationships ----------

  async getRelationship(alphaId: string, betaId: string): Promise<MonitoringRelationship | undefined> {
    return strip(await this.table.get(`ALPHA#${alphaId}`, `REL#${betaId}`));
  }

  async putRelationship(r: MonitoringRelationship): Promise<void> {
    await this.table.put({
      pk: `ALPHA#${r.alphaId}`,
      sk: `REL#${r.betaId}`,
      gsi1pk: `BETA#${r.betaId}`,
      gsi1sk: `REL#${r.alphaId}`,
      ...r,
    });
  }

  async deleteRelationship(alphaId: string, betaId: string): Promise<void> {
    await this.table.delete(`ALPHA#${alphaId}`, `REL#${betaId}`);
  }

  async listRelationshipsForAlpha(alphaId: string): Promise<MonitoringRelationship[]> {
    const res = await this.table.query({ pk: `ALPHA#${alphaId}`, sk: { beginsWith: 'REL#' } });
    return res.items.map((i) => strip<MonitoringRelationship>(i)!);
  }

  async listRelationshipsForBeta(betaId: string): Promise<MonitoringRelationship[]> {
    const res = await this.table.query({ index: 'gsi1', pk: `BETA#${betaId}`, sk: { beginsWith: 'REL#' } });
    // GSIs are eventually consistent; re-read from the base table so a just-revoked
    // relationship is never served as active.
    const fresh = await Promise.all(res.items.map((i) => this.getRelationship(i.alphaId as string, betaId)));
    return fresh.filter((r): r is MonitoringRelationship => r !== undefined);
  }

  // ---------- Invitations ----------

  async putInvitation(codeHash: string, inv: Invitation): Promise<void> {
    await this.table.put(
      {
        pk: `INVITE#${codeHash}`,
        sk: 'INVITE',
        gsi1pk: `INVITES#${inv.alphaId}`,
        gsi1sk: inv.createdAt,
        ttl: epoch(inv.expiresAt),
        codeHash,
        ...inv,
      },
      { kind: 'notExists' },
    );
  }

  async getInvitationByHash(codeHash: string): Promise<Invitation | undefined> {
    return strip(await this.table.get(`INVITE#${codeHash}`, 'INVITE'));
  }

  async listInvitations(alphaId: string): Promise<(Invitation & { codeHash: string })[]> {
    const res = await this.table.query({ index: 'gsi1', pk: `INVITES#${alphaId}`, forward: false, limit: 50 });
    return res.items.map((i) => strip<Invitation & { codeHash: string }>(i)!);
  }

  async deleteInvitation(codeHash: string): Promise<void> {
    await this.table.delete(`INVITE#${codeHash}`, 'INVITE');
  }

  // ---------- Telemetry ----------

  async putSamples(alphaId: string, samples: TelemetrySample[], retentionDays: number, locationRetentionDays: number): Promise<void> {
    await this.table.batchPut(
      samples.map((s) => ({
        pk: `T#${alphaId}#${s.kind}`,
        sk: `${s.timestamp}#${s.sampleId}`,
        ttl: epoch(s.timestamp) + (s.kind === 'location' ? locationRetentionDays : retentionDays) * DAY,
        ...s,
      })),
    );
  }

  async querySamples<K extends SampleKind>(
    alphaId: string,
    kind: K,
    from: string,
    to: string,
    opts: { limit?: number; cursor?: string; newestFirst?: boolean } = {},
  ): Promise<{ samples: Extract<TelemetrySample, { kind: K }>[]; cursor?: string }> {
    const res = await this.table.query({
      pk: `T#${alphaId}#${kind}`,
      sk: { between: [from, `${to}￿`] },
      limit: opts.limit ?? 2000,
      forward: !opts.newestFirst,
      ...(opts.cursor ? { cursor: opts.cursor } : {}),
    });
    return {
      samples: res.items.map((i) => strip<Extract<TelemetrySample, { kind: K }>>(i)!),
      ...(res.cursor ? { cursor: res.cursor } : {}),
    };
  }

  // ---------- Events (idempotency) ----------

  /** Returns false when the event was already processed. */
  async markEventProcessed(alphaId: string, event: DeviceEvent, receivedAt: string): Promise<boolean> {
    try {
      await this.table.put(
        { pk: `ALPHA#${alphaId}`, sk: `EVENT#${event.eventId}`, ttl: epoch(receivedAt) + 30 * DAY, ...event, receivedAt },
        { kind: 'notExists' },
      );
      return true;
    } catch (err) {
      if (err instanceof ConditionFailedError) return false;
      throw err;
    }
  }

  async getEvent(alphaId: string, eventId: string): Promise<(DeviceEvent & { receivedAt: string; alertId?: string }) | undefined> {
    return strip(await this.table.get(`ALPHA#${alphaId}`, `EVENT#${eventId}`));
  }

  async linkEventToAlert(alphaId: string, eventId: string, alertId: string): Promise<void> {
    const item = await this.table.get(`ALPHA#${alphaId}`, `EVENT#${eventId}`);
    if (item) await this.table.put({ ...item, alertId });
  }

  // ---------- Alerts ----------

  private alertItem(a: Alert & { version: number }): Item {
    return {
      pk: `ALPHA#${a.alphaId}`,
      sk: `ALERT#${a.alertId}`,
      ttl: epoch(a.receivedAt) + a.retentionDays * DAY,
      ...(a.nextEscalationAt
        ? { gsi2pk: `ESCALATION#${shardOf(a.alertId)}`, gsi2sk: `${a.nextEscalationAt}#${a.alphaId}#${a.alertId}` }
        : {}),
      ...a,
    };
  }

  async createAlert(a: Alert): Promise<void> {
    await this.table.put(this.alertItem({ ...a, version: 1 }), { kind: 'notExists' });
  }

  async getAlert(alphaId: string, alertId: string): Promise<(Alert & { version: number }) | undefined> {
    return strip(await this.table.get(`ALPHA#${alphaId}`, `ALERT#${alertId}`));
  }

  /** Compare-and-set update. Throws ConditionFailedError if someone else updated it first. */
  async updateAlert(a: Alert & { version: number }): Promise<Alert & { version: number }> {
    const next = { ...a, version: a.version + 1 };
    await this.table.put(this.alertItem(next), { kind: 'versionEquals', version: a.version });
    return next;
  }

  async listAlerts(alphaId: string, opts: { limit?: number; cursor?: string } = {}): Promise<{ alerts: Alert[]; cursor?: string }> {
    const res = await this.table.query({
      pk: `ALPHA#${alphaId}`,
      sk: { beginsWith: 'ALERT#' },
      forward: false,
      limit: opts.limit ?? 50,
      ...(opts.cursor ? { cursor: opts.cursor } : {}),
    });
    return { alerts: res.items.map((i) => strip<Alert>(i)!), ...(res.cursor ? { cursor: res.cursor } : {}) };
  }

  async dueEscalations(shard: number, now: string): Promise<{ alphaId: string; alertId: string }[]> {
    const res = await this.table.query({ index: 'gsi2', pk: `ESCALATION#${shard}`, sk: { lte: `${now}￿` }, limit: 100 });
    return res.items.map((i) => ({ alphaId: i.alphaId as string, alertId: i.alertId as string }));
  }

  /** Acquire the per-type dedupe lock. Returns the existing alertId when one is already open. */
  async acquireActiveAlert(alphaId: string, type: AlertType, alertId: string): Promise<string | null> {
    try {
      await this.table.put({ pk: `ALPHA#${alphaId}`, sk: `ACTIVE#${type}`, alertId }, { kind: 'notExists' });
      return null;
    } catch (err) {
      if (!(err instanceof ConditionFailedError)) throw err;
      const existing = await this.table.get(`ALPHA#${alphaId}`, `ACTIVE#${type}`);
      return (existing?.alertId as string | undefined) ?? null;
    }
  }

  async getActiveAlertId(alphaId: string, type: AlertType): Promise<string | null> {
    return ((await this.table.get(`ALPHA#${alphaId}`, `ACTIVE#${type}`))?.alertId as string | undefined) ?? null;
  }

  async releaseActiveAlert(alphaId: string, type: AlertType): Promise<void> {
    await this.table.delete(`ALPHA#${alphaId}`, `ACTIVE#${type}`);
  }

  async setCooldown(alphaId: string, type: AlertType, until: Date): Promise<void> {
    await this.table.put({ pk: `ALPHA#${alphaId}`, sk: `COOLDOWN#${type}`, until: until.toISOString(), ttl: Math.floor(until.getTime() / 1000) });
  }

  async inCooldown(alphaId: string, type: AlertType): Promise<boolean> {
    return (await this.table.get(`ALPHA#${alphaId}`, `COOLDOWN#${type}`)) !== undefined;
  }

  async putDelivery(d: AlertDelivery): Promise<void> {
    await this.table.put({ pk: `ALPHA#${d.alphaId}`, sk: `DELIVERY#${d.alertId}#${d.deliveryId}`, ...d });
  }

  async listDeliveries(alphaId: string, alertId: string): Promise<AlertDelivery[]> {
    const res = await this.table.query({ pk: `ALPHA#${alphaId}`, sk: { beginsWith: `DELIVERY#${alertId}#` } });
    return res.items.map((i) => strip<AlertDelivery>(i)!);
  }

  // ---------- Settings change requests ----------

  async putChangeRequest(r: SettingsChangeRequest): Promise<void> {
    await this.table.put({ pk: `ALPHA#${r.alphaId}`, sk: `SCR#${r.requestId}`, ...r });
  }

  async getChangeRequest(alphaId: string, requestId: string): Promise<SettingsChangeRequest | undefined> {
    return strip(await this.table.get(`ALPHA#${alphaId}`, `SCR#${requestId}`));
  }

  async listChangeRequests(alphaId: string): Promise<SettingsChangeRequest[]> {
    const res = await this.table.query({ pk: `ALPHA#${alphaId}`, sk: { beginsWith: 'SCR#' }, forward: false, limit: 50 });
    return res.items.map((i) => strip<SettingsChangeRequest>(i)!);
  }

  // ---------- Audit ----------

  async audit(e: AuditEntry): Promise<void> {
    await this.table.put({ pk: `ALPHA#${e.alphaId}`, sk: `AUDIT#${e.auditId}`, ttl: epoch(e.at) + 365 * DAY, ...e });
  }

  async listAudit(alphaId: string, limit = 100): Promise<AuditEntry[]> {
    const res = await this.table.query({ pk: `ALPHA#${alphaId}`, sk: { beginsWith: 'AUDIT#' }, forward: false, limit });
    return res.items.map((i) => strip<AuditEntry>(i)!);
  }

  // ---------- Rate limiting ----------

  /** Fixed-window counter. Returns the count including this attempt. */
  async countAttempt(userId: string, action: string, windowSeconds: number, now: Date): Promise<number> {
    const bucket = Math.floor(now.getTime() / 1000 / windowSeconds);
    return this.table.increment(`RATE#${userId}#${action}#${bucket}`, 'RATE', 'count', 1, (bucket + 1) * windowSeconds + 60);
  }

  // ---------- Deletion ----------

  /** Deletes every item in a partition (paginated). */
  async deletePartition(pk: string): Promise<number> {
    let deleted = 0;
    for (;;) {
      const res = await this.table.query({ pk, limit: 500 });
      if (res.items.length === 0) return deleted;
      await this.table.batchDelete(res.items.map((i) => ({ pk: i.pk, sk: i.sk })));
      deleted += res.items.length;
    }
  }
}
