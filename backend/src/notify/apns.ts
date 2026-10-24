import { createPrivateKey, sign } from 'node:crypto';
import { connect, type ClientHttp2Session } from 'node:http2';
import type { PushMessage, PushProvider, SendResult } from './providers.ts';

export interface ApnsCredentials {
  teamId: string;
  keyId: string;
  privateKey: string; // contents of the .p8 file
  bundleId: string; // apns-topic, e.g. com.berkgozek.AlphaBeta
}

/** Token-based (JWT/ES256) Apple Push Notification service client over HTTP/2. */
export class ApnsPushProvider implements PushProvider {
  readonly name = 'apns';
  private readonly creds: ApnsCredentials;
  private jwt?: { token: string; issuedAt: number };
  private sessions = new Map<string, ClientHttp2Session>();

  constructor(creds: ApnsCredentials) {
    this.creds = creds;
  }

  private bearer(): string {
    const now = Math.floor(Date.now() / 1000);
    // Apple rejects tokens older than 1h and throttles refreshes more often than every 20 min.
    if (this.jwt && now - this.jwt.issuedAt < 50 * 60) return this.jwt.token;
    const header = Buffer.from(JSON.stringify({ alg: 'ES256', kid: this.creds.keyId })).toString('base64url');
    const claims = Buffer.from(JSON.stringify({ iss: this.creds.teamId, iat: now })).toString('base64url');
    const signature = sign('sha256', Buffer.from(`${header}.${claims}`), {
      key: createPrivateKey(this.creds.privateKey),
      dsaEncoding: 'ieee-p1363',
    }).toString('base64url');
    this.jwt = { token: `${header}.${claims}.${signature}`, issuedAt: now };
    return this.jwt.token;
  }

  private session(environment: PushMessage['environment']): ClientHttp2Session {
    const host = environment === 'production' ? 'https://api.push.apple.com' : 'https://api.sandbox.push.apple.com';
    const existing = this.sessions.get(host);
    if (existing && !existing.closed && !existing.destroyed) return existing;
    const s = connect(host);
    s.on('error', () => this.sessions.delete(host));
    s.on('close', () => this.sessions.delete(host));
    this.sessions.set(host, s);
    return s;
  }

  async send(message: PushMessage): Promise<SendResult> {
    const payload = JSON.stringify({
      aps: {
        alert: { title: message.title, body: message.body },
        sound: message.interruptionLevel === 'critical' ? { critical: 1, name: 'default', volume: 1.0 } : 'default',
        'interruption-level': message.interruptionLevel,
        'thread-id': message.threadId,
        category: 'ALPHA_ALERT',
      },
      ...message.data,
    });
    return new Promise<SendResult>((resolve) => {
      const req = this.session(message.environment).request({
        ':method': 'POST',
        ':path': `/3/device/${message.deviceToken}`,
        authorization: `bearer ${this.bearer()}`,
        'apns-topic': this.creds.bundleId,
        'apns-push-type': 'alert',
        'apns-priority': '10',
        'apns-expiration': String(Math.floor(Date.now() / 1000) + 3600),
      });
      let status = 0;
      let body = '';
      let apnsId: string | undefined;
      req.setTimeout(10_000, () => {
        req.close();
        resolve({ ok: false, detail: 'APNs request timed out' });
      });
      req.on('response', (headers) => {
        status = Number(headers[':status']);
        apnsId = headers['apns-id'] as string | undefined;
      });
      req.setEncoding('utf8');
      req.on('data', (chunk: string) => (body += chunk));
      req.on('error', (err) => resolve({ ok: false, detail: `APNs connection error: ${err.message}` }));
      req.on('end', () => {
        if (status === 200) {
          // 200 means APNs accepted the notification. It does NOT confirm the device displayed it.
          resolve({ ok: true, ...(apnsId ? { providerMessageId: apnsId } : {}), detail: 'accepted by APNs' });
          return;
        }
        let reason = 'unknown';
        try {
          reason = (JSON.parse(body) as { reason?: string }).reason ?? reason;
        } catch {
          // keep "unknown"
        }
        resolve({
          ok: false,
          detail: `APNs ${status}: ${reason}`,
          invalidToken: status === 410 || reason === 'BadDeviceToken' || reason === 'Unregistered',
        });
      });
      req.end(payload);
    });
  }
}
