// Delivery-channel abstractions. Real providers (APNs, Twilio) and explicitly named stand-ins
// (Recording*, Disabled*) implement the same interfaces, so swapping one for another is a
// configuration change (see config.ts), never a code restructure.

export interface SendResult {
  ok: boolean;
  providerMessageId?: string;
  detail?: string; // short, non-sensitive diagnostic
  invalidToken?: boolean; // the device token should be discarded
}

export interface PushMessage {
  deviceToken: string;
  environment: 'sandbox' | 'production';
  title: string;
  body: string;
  // "critical" requires Apple's Critical Alerts entitlement; without it APNs/iOS treat the
  // notification as time-sensitive at most. See docs/feasibility.md.
  interruptionLevel: 'active' | 'time-sensitive' | 'critical';
  threadId: string; // groups notifications per Alpha
  data: Record<string, string>;
}

export interface PushProvider {
  readonly name: string;
  send(message: PushMessage): Promise<SendResult>;
}

export interface SmsProvider {
  readonly name: string;
  /** False means the channel is not configured; callers record a "skipped" delivery. */
  readonly enabled: boolean;
  send(to: string, body: string): Promise<SendResult>;
}

export interface VoiceProvider {
  readonly name: string;
  readonly enabled: boolean;
  call(to: string, spokenMessage: string): Promise<SendResult>;
}

/** Records messages in memory instead of sending them. Used for local development, simulation
 *  and tests. It does not pretend delivery happened: results carry "recorded, not sent". */
export class RecordingPushProvider implements PushProvider {
  readonly name = 'recording-push';
  readonly sent: PushMessage[] = [];
  async send(message: PushMessage): Promise<SendResult> {
    this.sent.push(message);
    return { ok: true, providerMessageId: `recorded-${this.sent.length}`, detail: 'recorded locally, not sent to APNs' };
  }
}

export class DisabledPushProvider implements PushProvider {
  readonly name = 'disabled-push';
  async send(): Promise<SendResult> {
    return { ok: false, detail: 'push provider not configured' };
  }
}

export class RecordingSmsProvider implements SmsProvider {
  readonly name = 'recording-sms';
  readonly enabled = true;
  readonly sent: { to: string; body: string }[] = [];
  async send(to: string, body: string): Promise<SendResult> {
    this.sent.push({ to, body });
    return { ok: true, providerMessageId: `recorded-${this.sent.length}`, detail: 'recorded locally, no SMS sent' };
  }
}

export class DisabledSmsProvider implements SmsProvider {
  readonly name = 'disabled-sms';
  readonly enabled = false;
  async send(): Promise<SendResult> {
    return { ok: false, detail: 'SMS provider not configured' };
  }
}

export class RecordingVoiceProvider implements VoiceProvider {
  readonly name = 'recording-voice';
  readonly enabled = true;
  readonly calls: { to: string; message: string }[] = [];
  async call(to: string, message: string): Promise<SendResult> {
    this.calls.push({ to, message });
    return { ok: true, providerMessageId: `recorded-${this.calls.length}`, detail: 'recorded locally, no call placed' };
  }
}

export class DisabledVoiceProvider implements VoiceProvider {
  readonly name = 'disabled-voice';
  readonly enabled = false;
  async call(): Promise<SendResult> {
    return { ok: false, detail: 'voice provider not configured' };
  }
}
