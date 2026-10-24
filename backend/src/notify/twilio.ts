import type { SendResult, SmsProvider, VoiceProvider } from './providers.ts';

// Twilio REST integration. These classes are only constructed when SMS_PROVIDER / VOICE_PROVIDER
// is explicitly set to "twilio" AND credentials exist in Secrets Manager — they place real,
// billable messages and calls. They must never be used to contact emergency services.

export interface TwilioCredentials {
  accountSid: string;
  authToken: string;
  fromNumber: string; // E.164 number owned by the Twilio account
}

async function twilioPost(creds: TwilioCredentials, resource: string, form: Record<string, string>): Promise<SendResult> {
  const url = `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(creds.accountSid)}/${resource}.json`;
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        authorization: `Basic ${Buffer.from(`${creds.accountSid}:${creds.authToken}`).toString('base64')}`,
        'content-type': 'application/x-www-form-urlencoded',
      },
      body: new URLSearchParams(form),
      signal: AbortSignal.timeout(10_000),
    });
    const json = (await res.json().catch(() => ({}))) as { sid?: string; message?: string; status?: string };
    if (!res.ok) return { ok: false, detail: `Twilio ${res.status}: ${json.message ?? 'error'}` };
    // "queued"/"initiated" — Twilio accepted the request; delivery is reported later via status callbacks.
    return { ok: true, ...(json.sid ? { providerMessageId: json.sid } : {}), detail: `accepted by Twilio (${json.status ?? 'queued'})` };
  } catch (err) {
    return { ok: false, detail: `Twilio request failed: ${(err as Error).name}` };
  }
}

const escapeXml = (s: string) =>
  s.replace(/[<>&'"]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', "'": '&apos;', '"': '&quot;' })[c] ?? c);

export class TwilioSmsProvider implements SmsProvider {
  readonly name = 'twilio-sms';
  readonly enabled = true;
  private readonly creds: TwilioCredentials;
  constructor(creds: TwilioCredentials) {
    this.creds = creds;
  }
  send(to: string, body: string): Promise<SendResult> {
    return twilioPost(this.creds, 'Messages', { To: to, From: this.creds.fromNumber, Body: body });
  }
}

export class TwilioVoiceProvider implements VoiceProvider {
  readonly name = 'twilio-voice';
  readonly enabled = true;
  private readonly creds: TwilioCredentials;
  constructor(creds: TwilioCredentials) {
    this.creds = creds;
  }
  call(to: string, spokenMessage: string): Promise<SendResult> {
    const say = `<Say voice="alice">${escapeXml(spokenMessage)}</Say><Pause length="1"/>`;
    return twilioPost(this.creds, 'Calls', {
      To: to,
      From: this.creds.fromNumber,
      Twiml: `<Response>${say}${say}</Response>`,
    });
  }
}
