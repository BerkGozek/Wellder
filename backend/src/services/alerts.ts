import { badRequest, conflict, notFound } from '../domain/errors.ts';
import { sortableId } from '../domain/ids.ts';
import { defaultSettings } from '../domain/settings.ts';
import type {
  Alert,
  AlertCategory,
  AlertDelivery,
  AlertSeverity,
  AlertType,
  DeliveryChannel,
  MonitoringRelationship,
  MonitoringSettings,
} from '../domain/types.ts';
import { ConditionFailedError } from '../store/table.ts';
import { audit } from './access.ts';
import type { Deps } from './deps.ts';

// Alert engine: creation with deduplication, the escalation state machine, and delivery records.
//
// Escalation (critical safety alerts only):
//   step 0  in-app + push to every Beta with `receiveAlerts`
//   step 1  after escalationDelaySeconds: push reminder + SMS (if enabled and configured)
//   step 2  after another delay:          push reminder + voice call (if enabled and configured)
// Warnings and technical alerts stop after step 0. Acknowledgement or resolution stops escalation.
// Simulated alerts never use SMS or voice.

export const MAX_STEP = 2;
const AWAIT_GRACE_SECONDS = 30; // network slack after the on-device countdown expires
const ESCALATION_LEASE_SECONDS = 120; // re-run a step if a worker dies mid-send

type StoredAlert = Alert & { version: number };

export interface RaiseSpec {
  alphaId: string;
  type: AlertType;
  severity: AlertSeverity;
  title: string;
  message: string;
  detectedAt: string;
  simulated: boolean;
  sourceEventId?: string;
  evidence?: Record<string, string | number | boolean>;
  /** Start in `awaitingAlphaResponse`; the backend escalates on its own if no answer arrives. */
  awaitAlphaResponseSeconds?: number;
  cooldownSeconds?: number;
}

const CATEGORY: Record<AlertType, AlertCategory> = {
  possibleFall: 'safety',
  heartRateHigh: 'safety',
  heartRateLow: 'safety',
  prolongedInactivity: 'safety',
  manualHelpRequest: 'safety',
  monitoringInterrupted: 'technical',
  deviceDisconnected: 'technical',
  lowBattery: 'technical',
  locationUnavailable: 'technical',
};

/** Types that bypass cooldown: every occurrence matters. */
const NO_COOLDOWN: AlertType[] = ['possibleFall', 'manualHelpRequest'];

const addSeconds = (d: Date, s: number) => new Date(d.getTime() + s * 1000).toISOString();

export class AlertEngine {
  private readonly deps: Deps;

  constructor(deps: Deps) {
    this.deps = deps;
  }

  private async settingsFor(alphaId: string): Promise<MonitoringSettings> {
    return (await this.deps.repo.getSettings(alphaId)) ?? defaultSettings(alphaId, 'UTC', this.deps.now());
  }

  /** Creates an alert or folds it into the open alert of the same type. */
  async raise(spec: RaiseSpec): Promise<{ alert: Alert | null; created: boolean; suppressed?: 'cooldown' }> {
    const { repo, log } = this.deps;
    const now = this.deps.now();
    for (let attempt = 0; attempt < 3; attempt++) {
      // Cooldown starts when an alert of this type is resolved; an alert that is still open
      // absorbs repeats instead (see the lock below).
      const openId = await repo.getActiveAlertId(spec.alphaId, spec.type);
      if (!openId && !NO_COOLDOWN.includes(spec.type) && (await repo.inCooldown(spec.alphaId, spec.type))) {
        log.info('alert.suppressed_cooldown', { alphaId: spec.alphaId, type: spec.type });
        return { alert: null, created: false, suppressed: 'cooldown' };
      }
      const alertId = sortableId(now);
      const existingId = await repo.acquireActiveAlert(spec.alphaId, spec.type, alertId);
      if (existingId) {
        const existing = await repo.getAlert(spec.alphaId, existingId);
        if (!existing || existing.status === 'resolved') {
          await repo.releaseActiveAlert(spec.alphaId, spec.type); // stale lock
          continue;
        }
        try {
          const updated = await repo.updateAlert({ ...existing, occurrences: existing.occurrences + 1 });
          return { alert: updated, created: false };
        } catch (err) {
          if (err instanceof ConditionFailedError) continue;
          throw err;
        }
      }

      const settings = await this.settingsFor(spec.alphaId);
      const awaiting = spec.awaitAlphaResponseSeconds !== undefined;
      const alert: Alert = {
        alertId,
        alphaId: spec.alphaId,
        type: spec.type,
        category: CATEGORY[spec.type],
        severity: spec.severity,
        status: awaiting ? 'awaitingAlphaResponse' : 'open',
        title: spec.title,
        message: spec.message,
        simulated: spec.simulated,
        occurrences: 1,
        detectedAt: spec.detectedAt,
        receivedAt: now.toISOString(),
        escalationStep: 0,
        retentionDays: settings.dataRetention.alertDays,
        ...(spec.cooldownSeconds ? { cooldownSeconds: spec.cooldownSeconds } : {}),
        ...(spec.sourceEventId ? { sourceEventId: spec.sourceEventId } : {}),
        ...(spec.evidence ? { evidence: spec.evidence } : {}),
        ...(awaiting
          ? { nextEscalationAt: addSeconds(new Date(Math.max(Date.parse(spec.detectedAt), now.getTime() - 3600_000)), (spec.awaitAlphaResponseSeconds ?? 0) + AWAIT_GRACE_SECONDS) }
          : {}),
      };
      await repo.createAlert(alert);
      log.info('alert.created', { alertId, alphaId: spec.alphaId, type: spec.type, severity: spec.severity, simulated: spec.simulated });

      const stored = (await repo.getAlert(spec.alphaId, alertId))!;
      const final = awaiting ? stored : await this.runStep(stored, 0, settings);
      return { alert: final, created: true };
    }
    throw conflict('Could not create alert due to concurrent updates; retry');
  }

  /** Writes an informational record (no notifications, already resolved). */
  async record(spec: RaiseSpec & { resolution: NonNullable<Alert['resolution']> }): Promise<Alert> {
    const now = this.deps.now();
    const settings = await this.settingsFor(spec.alphaId);
    const alert: Alert = {
      alertId: sortableId(now),
      alphaId: spec.alphaId,
      type: spec.type,
      category: CATEGORY[spec.type],
      severity: 'info',
      status: 'resolved',
      title: spec.title,
      message: spec.message,
      simulated: spec.simulated,
      occurrences: 1,
      detectedAt: spec.detectedAt,
      receivedAt: now.toISOString(),
      resolvedAt: now.toISOString(),
      resolvedBy: spec.alphaId,
      resolution: spec.resolution,
      escalationStep: 0,
      retentionDays: settings.dataRetention.alertDays,
      ...(spec.sourceEventId ? { sourceEventId: spec.sourceEventId } : {}),
      ...(spec.evidence ? { evidence: spec.evidence } : {}),
    };
    await this.deps.repo.createAlert(alert);
    return alert;
  }

  /** Moves an `awaitingAlphaResponse` alert to `open` and notifies (no response / needs help). */
  async openNow(alphaId: string, alertId: string, patch: Partial<Pick<Alert, 'title' | 'message' | 'severity'>> = {}): Promise<Alert | undefined> {
    for (let attempt = 0; attempt < 3; attempt++) {
      const alert = await this.deps.repo.getAlert(alphaId, alertId);
      if (!alert || alert.status !== 'awaitingAlphaResponse') return alert;
      try {
        const opened = await this.deps.repo.updateAlert({ ...alert, ...patch, status: 'open' });
        return await this.runStep(opened, 0, await this.settingsFor(alphaId));
      } catch (err) {
        if (!(err instanceof ConditionFailedError)) throw err;
      }
    }
    return undefined;
  }

  /** Called by the sweeper for alerts whose nextEscalationAt has passed. */
  async processDueEscalation(alphaId: string, alertId: string): Promise<void> {
    const now = this.deps.now();
    const alert = await this.deps.repo.getAlert(alphaId, alertId);
    if (!alert?.nextEscalationAt || Date.parse(alert.nextEscalationAt) > now.getTime()) return;
    if (alert.status === 'acknowledged' || alert.status === 'resolved') {
      await this.casUpdate(alert, (a) => ({ ...a, nextEscalationAt: undefined }));
      return;
    }
    const settings = await this.settingsFor(alphaId);
    if (alert.status === 'awaitingAlphaResponse') {
      // Server-side dead-man's switch: the device may have been damaged in the fall.
      const name = await this.alphaName(alphaId);
      await this.openNow(
        alphaId,
        alertId,
        alert.type === 'possibleFall'
          ? {
              title: 'No response after possible fall',
              message: `${name} did not respond to a possible-fall check. This does not confirm an injury — please check on them.`,
            }
          : { message: `${alert.message} ${name} didn't cancel it as a false alarm on their device.` },
      );
      return;
    }
    const nextStep = alert.escalationStep + 1;
    if (nextStep > MAX_STEP) {
      await this.casUpdate(alert, (a) => ({ ...a, nextEscalationAt: undefined }));
      return;
    }
    // Lease first so a parallel sweeper skips it; if this worker dies the lease expires and retries.
    const leased = await this.casUpdate(alert, (a) => ({ ...a, nextEscalationAt: addSeconds(now, ESCALATION_LEASE_SECONDS) }));
    if (!leased) return;
    await this.runStep(leased, nextStep, settings);
  }

  private async casUpdate(alert: StoredAlert, change: (a: StoredAlert) => StoredAlert): Promise<StoredAlert | null> {
    try {
      const next = change(alert);
      if (next.nextEscalationAt === undefined) delete next.nextEscalationAt;
      return await this.deps.repo.updateAlert(next);
    } catch (err) {
      if (err instanceof ConditionFailedError) return null;
      throw err;
    }
  }

  private async alphaName(alphaId: string): Promise<string> {
    return (await this.deps.repo.getProfile(alphaId))?.name ?? 'Your contact';
  }

  private async recipients(alphaId: string, settings: MonitoringSettings): Promise<MonitoringRelationship[]> {
    const rels = (await this.deps.repo.listRelationshipsForAlpha(alphaId)).filter((r) => r.status === 'active' && r.permissions.receiveAlerts);
    const order = settings.notifications.contactOrder;
    const rank = (id: string) => (order.indexOf(id) === -1 ? order.length : order.indexOf(id));
    return rels.sort((a, b) => rank(a.betaId) - rank(b.betaId));
  }

  /** Executes one escalation step and schedules the next one. */
  private async runStep(alert: StoredAlert, step: number, settings: MonitoringSettings): Promise<StoredAlert> {
    const { repo, providers, log } = this.deps;
    const now = this.deps.now();
    const recipients = await this.recipients(alert.alphaId, settings);
    const prefix = alert.simulated ? '[SIMULATION] ' : '';
    const reminder = step > 0 ? 'Still unacknowledged: ' : '';
    let anySent = false;

    const deliver = async (betaId: string, channel: DeliveryChannel, fn: () => Promise<Omit<AlertDelivery, 'deliveryId' | 'alertId' | 'alphaId' | 'betaId' | 'channel' | 'escalationStep' | 'attemptedAt'>>) => {
      const attemptedAt = this.deps.now().toISOString();
      const result = await fn();
      if (result.status === 'sent' || result.status === 'delivered') anySent = true;
      await repo.putDelivery({
        deliveryId: sortableId(),
        alertId: alert.alertId,
        alphaId: alert.alphaId,
        betaId,
        channel,
        escalationStep: step,
        attemptedAt,
        ...result,
      });
    };

    const paidChannelAllowed = alert.category === 'safety' && alert.severity === 'critical';
    const isHeartRate = alert.type === 'heartRateHigh' || alert.type === 'heartRateLow';
    for (const rel of recipients) {
      if (step === 0) {
        // Recorded as "sent"; becomes "delivered" when the Beta's app actually fetches it.
        await deliver(rel.betaId, 'inApp', async () => ({ status: 'sent', detail: 'available in app' }));
      }
      if (settings.notifications.push) {
        const devices = (await repo.listDevices(rel.betaId)).filter((d) => d.apnsToken);
        if (devices.length === 0) {
          await deliver(rel.betaId, 'push', async () => ({ status: 'skipped', detail: 'no device registered for push' }));
        }
        for (const device of devices) {
          await deliver(rel.betaId, 'push', async () => {
            const r = await providers.push.send({
              deviceToken: device.apnsToken!,
              environment: device.apnsEnvironment ?? 'production',
              title: `${prefix}${reminder}${alert.title}`,
              // Same field-level rule as the API: no heart-rate details without viewHeartRate.
              body: isHeartRate && !rel.permissions.viewHeartRate ? 'Heart rate outside the configured range. Open Wellder for details.' : alert.message,
              interruptionLevel: alert.severity === 'critical' ? 'time-sensitive' : 'active',
              threadId: `alpha-${alert.alphaId}`,
              data: { alertId: alert.alertId, alphaId: alert.alphaId, type: alert.type },
            });
            if (r.invalidToken) {
              const { apnsToken: _drop, ...rest } = device;
              void _drop;
              await repo.putDevice(rest);
            }
            return {
              status: r.ok ? 'sent' : 'failed',
              ...(r.providerMessageId ? { providerMessageId: r.providerMessageId } : {}),
              ...(r.detail ? { detail: r.detail } : {}),
            };
          });
        }
      }
      if (step === 1 || step === 2) {
        const channel: DeliveryChannel = step === 1 ? 'sms' : 'voice';
        const enabledInSettings = step === 1 ? settings.notifications.sms : settings.notifications.voice;
        const provider = step === 1 ? providers.sms : providers.voice;
        const phone = (await repo.getProfile(rel.betaId))?.phoneNumber;
        const skip = !paidChannelAllowed
          ? 'not used for this alert severity'
          : alert.simulated
            ? 'simulation: paid channels never used'
            : !enabledInSettings
              ? `${channel} disabled in settings`
              : !provider.enabled
                ? `${channel} provider not configured`
                : !phone
                  ? 'caregiver has no phone number'
                  : null;
        if (skip) {
          await deliver(rel.betaId, channel, async () => ({ status: 'skipped', detail: skip }));
        } else {
          const name = await this.alphaName(alert.alphaId);
          const text = `Wellder alert for ${name}: ${alert.title}. Open the Wellder app to respond.`;
          await deliver(rel.betaId, channel, async () => {
            const r = step === 1 ? await providers.sms.send(phone!, text) : await providers.voice.call(phone!, text);
            return {
              status: r.ok ? 'sent' : 'failed',
              ...(r.providerMessageId ? { providerMessageId: r.providerMessageId } : {}),
              ...(r.detail ? { detail: r.detail } : {}),
            };
          });
        }
      }
    }
    if (recipients.length === 0) log.warn('alert.no_recipients', { alertId: alert.alertId, alphaId: alert.alphaId });

    const escalates = paidChannelAllowed && step < MAX_STEP;
    for (let attempt = 0; attempt < 3; attempt++) {
      const current = (await repo.getAlert(alert.alphaId, alert.alertId))!;
      const stillOpen = current.status === 'open' || current.status === 'awaitingAlphaResponse';
      const next: StoredAlert = {
        ...current,
        escalationStep: step,
        ...(anySent && !current.firstNotificationSentAt ? { firstNotificationSentAt: now.toISOString() } : {}),
      };
      if (escalates && stillOpen) next.nextEscalationAt = addSeconds(now, settings.notifications.escalationDelaySeconds);
      else delete next.nextEscalationAt;
      try {
        const saved = await repo.updateAlert(next);
        log.info('alert.step', { alertId: alert.alertId, step, recipients: recipients.length });
        return saved;
      } catch (err) {
        if (!(err instanceof ConditionFailedError)) throw err;
      }
    }
    return (await repo.getAlert(alert.alphaId, alert.alertId))!;
  }

  // ---------- Caregiver / Alpha actions ----------

  async acknowledge(actorId: string, alphaId: string, alertId: string): Promise<Alert> {
    for (let attempt = 0; attempt < 3; attempt++) {
      const alert = await this.deps.repo.getAlert(alphaId, alertId);
      if (!alert) throw notFound();
      if (alert.status === 'resolved') throw conflict('Alert is already resolved');
      if (alert.status === 'acknowledged') return alert;
      try {
        const { nextEscalationAt: _stop, ...rest } = alert;
        void _stop;
        const updated = await this.deps.repo.updateAlert({
          ...rest,
          status: 'acknowledged',
          acknowledgedAt: this.deps.now().toISOString(),
          acknowledgedBy: actorId,
        });
        await audit(this.deps, alphaId, actorId, 'alert.acknowledged', { alertId, type: alert.type });
        return updated;
      } catch (err) {
        if (!(err instanceof ConditionFailedError)) throw err;
      }
    }
    throw conflict('Alert changed concurrently; retry');
  }

  async resolve(actorId: string, alphaId: string, alertId: string, resolution: NonNullable<Alert['resolution']>): Promise<Alert> {
    for (let attempt = 0; attempt < 3; attempt++) {
      const alert = await this.deps.repo.getAlert(alphaId, alertId);
      if (!alert) throw notFound();
      if (alert.status === 'resolved') return alert;
      try {
        const { nextEscalationAt: _stop, ...rest } = alert;
        void _stop;
        const updated = await this.deps.repo.updateAlert({
          ...rest,
          status: 'resolved',
          resolvedAt: this.deps.now().toISOString(),
          resolvedBy: actorId,
          resolution,
        });
        await this.deps.repo.releaseActiveAlert(alphaId, alert.type);
        if (alert.cooldownSeconds) {
          await this.deps.repo.setCooldown(alphaId, alert.type, new Date(this.deps.now().getTime() + alert.cooldownSeconds * 1000));
        }
        await audit(this.deps, alphaId, actorId, 'alert.resolved', { alertId, type: alert.type, resolution });
        return updated;
      } catch (err) {
        if (!(err instanceof ConditionFailedError)) throw err;
      }
    }
    throw conflict('Alert changed concurrently; retry');
  }

  /** Resolves the open alert of `type`, if any (e.g. movement resumed, sync resumed). */
  async clearCondition(alphaId: string, type: AlertType): Promise<Alert | null> {
    const activeId = await this.deps.repo.getActiveAlertId(alphaId, type);
    return activeId ? this.resolve('system', alphaId, activeId, 'conditionCleared') : null;
  }

  /** The Alpha answered "I'm okay" to a possible-fall prompt. */
  async alphaReportsOk(alphaId: string, alertId: string): Promise<Alert | undefined> {
    const before = await this.deps.repo.getAlert(alphaId, alertId);
    if (!before || before.status === 'resolved') return before;
    const wasNotified = before.status !== 'awaitingAlphaResponse';
    const resolved = await this.resolve(alphaId, alphaId, alertId, 'alphaOk');
    if (wasNotified) {
      // Betas were already alerted; tell them the Alpha responded.
      const settings = await this.settingsFor(alphaId);
      const name = await this.alphaName(alphaId);
      for (const rel of await this.recipients(alphaId, settings)) {
        for (const d of (await this.deps.repo.listDevices(rel.betaId)).filter((x) => x.apnsToken)) {
          await this.deps.providers.push.send({
            deviceToken: d.apnsToken!,
            environment: d.apnsEnvironment ?? 'production',
            title: `${before.simulated ? '[SIMULATION] ' : ''}Update: ${name} responded "I'm okay"`,
            body: 'They answered the possible-fall check. Consider confirming with them directly.',
            interruptionLevel: 'active',
            threadId: `alpha-${alphaId}`,
            data: { alertId, alphaId, type: before.type },
          });
        }
      }
    }
    return resolved;
  }

  /** Marks in-app deliveries as delivered once the Beta's app has actually fetched the alerts. */
  async markFetchedInApp(betaId: string, alerts: Alert[]): Promise<void> {
    const now = this.deps.now().toISOString();
    for (const alert of alerts) {
      if (alert.status === 'resolved') continue;
      const deliveries = await this.deps.repo.listDeliveries(alert.alphaId, alert.alertId);
      const pending = deliveries.filter((d) => d.betaId === betaId && d.channel === 'inApp' && d.status === 'sent');
      for (const d of pending) await this.deps.repo.putDelivery({ ...d, status: 'delivered', deliveredAt: now });
      if (pending.length > 0 && !alert.firstDeliveryConfirmedAt) {
        const stored = await this.deps.repo.getAlert(alert.alphaId, alert.alertId);
        if (stored && !stored.firstDeliveryConfirmedAt) {
          await this.casUpdate(stored, (a) => ({ ...a, firstDeliveryConfirmedAt: now }));
        }
      }
    }
  }
}

export function assertResolution(value: unknown): NonNullable<Alert['resolution']> {
  if (value === 'betaResolved' || value === 'falseAlarm') return value;
  throw badRequest('resolution must be betaResolved or falseAlarm');
}

