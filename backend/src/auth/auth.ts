import { createHmac, randomBytes, scryptSync, timingSafeEqual } from 'node:crypto';
import { badRequest, conflict, unauthorized } from '../domain/errors.ts';
import { uuid } from '../domain/ids.ts';
import { EMAIL, obj, str } from '../domain/validation.ts';
import type { Table } from '../store/table.ts';

export interface Principal {
  userId: string;
  email: string;
  provider: 'cognito' | 'dev';
}

// ---------- Cognito (production) ----------
// API Gateway's JWT authorizer validates the Cognito ID token (signature, issuer, audience,
// expiry) before the Lambda runs. We only read the verified claims it forwards; the user ID
// always comes from `sub`, never from the request body.

export function principalFromCognitoClaims(claims: Record<string, unknown> | undefined): Principal {
  const sub = claims?.sub;
  const email = claims?.email;
  if (typeof sub !== 'string' || !sub) throw unauthorized();
  if (claims?.token_use !== undefined && claims.token_use !== 'id') throw unauthorized('ID token required');
  return { userId: sub, email: typeof email === 'string' ? email : '', provider: 'cognito' };
}

// ---------- Local development auth ----------
// HS256 tokens signed with a per-process secret. Only wired up when AUTH_MODE=dev, which the
// AWS deployment never sets (infrastructure/lib/stack.ts hard-codes AUTH_MODE=cognito).

const b64 = (v: string | Buffer) => Buffer.from(v).toString('base64url');

export class DevAuth {
  private readonly secret: Buffer;
  private readonly table: Table;
  private readonly ttlSeconds = 7 * 24 * 3600;

  constructor(table: Table, secret?: string) {
    this.table = table;
    this.secret = secret ? Buffer.from(secret) : randomBytes(32);
  }

  issue(userId: string, email: string): { idToken: string; expiresAt: string } {
    const now = Math.floor(Date.now() / 1000);
    const header = b64(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
    const payload = b64(JSON.stringify({ sub: userId, email, iat: now, exp: now + this.ttlSeconds, token_use: 'id', iss: 'wellder-dev' }));
    const sig = createHmac('sha256', this.secret).update(`${header}.${payload}`).digest('base64url');
    return { idToken: `${header}.${payload}.${sig}`, expiresAt: new Date((now + this.ttlSeconds) * 1000).toISOString() };
  }

  verify(authorization: string | undefined): Principal {
    const token = authorization?.startsWith('Bearer ') ? authorization.slice(7) : undefined;
    if (!token) throw unauthorized();
    const [header, payload, sig] = token.split('.');
    if (!header || !payload || !sig) throw unauthorized('Malformed token');
    const expected = createHmac('sha256', this.secret).update(`${header}.${payload}`).digest();
    const given = Buffer.from(sig, 'base64url');
    if (given.length !== expected.length || !timingSafeEqual(given, expected)) throw unauthorized('Invalid token');
    let claims: { sub?: unknown; email?: unknown; exp?: unknown };
    try {
      claims = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8')) as typeof claims;
    } catch {
      throw unauthorized('Malformed token');
    }
    if (typeof claims.exp !== 'number' || claims.exp * 1000 < Date.now()) throw unauthorized('Token expired');
    if (typeof claims.sub !== 'string') throw unauthorized('Invalid token');
    return { userId: claims.sub, email: typeof claims.email === 'string' ? claims.email : '', provider: 'dev' };
  }

  async register(body: unknown): Promise<{ userId: string; idToken: string; expiresAt: string }> {
    const o = obj(body);
    const email = str(o, 'email', { max: 254, pattern: EMAIL }).toLowerCase();
    const password = str(o, 'password', { min: 8, max: 128 });
    const salt = randomBytes(16);
    const hash = scryptSync(password, salt, 32);
    const userId = uuid();
    try {
      await this.table.put(
        { pk: `DEVAUTH#${email}`, sk: 'CRED', userId, salt: salt.toString('hex'), hash: hash.toString('hex') },
        { kind: 'notExists' },
      );
    } catch {
      throw conflict('An account with this email already exists');
    }
    return { userId, ...this.issue(userId, email) };
  }

  async login(body: unknown): Promise<{ userId: string; idToken: string; expiresAt: string }> {
    const o = obj(body);
    const email = str(o, 'email', { max: 254 }).toLowerCase();
    const password = str(o, 'password', { min: 1, max: 128 });
    const cred = await this.table.get(`DEVAUTH#${email}`, 'CRED');
    // Hash even when the account is missing so timing does not reveal which emails exist.
    const salt = typeof cred?.salt === 'string' ? Buffer.from(cred.salt, 'hex') : randomBytes(16);
    const hash = scryptSync(password, salt, 32);
    const stored = typeof cred?.hash === 'string' ? Buffer.from(cred.hash, 'hex') : Buffer.alloc(32);
    if (!cred || !timingSafeEqual(hash, stored)) throw badRequest('Incorrect email or password');
    const userId = cred.userId as string;
    return { userId, ...this.issue(userId, email) };
  }

  async deleteCredentials(email: string): Promise<void> {
    await this.table.delete(`DEVAUTH#${email.toLowerCase()}`, 'CRED');
  }
}
