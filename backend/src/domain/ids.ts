import { createHash, randomBytes, randomUUID } from 'node:crypto';

/** Time-sortable identifier: 10 chars of base-36 milliseconds + 12 random hex chars. */
export function sortableId(at: Date = new Date()): string {
  return at.getTime().toString(36).padStart(10, '0') + randomBytes(6).toString('hex');
}

export function uuid(): string {
  return randomUUID();
}

// Crockford-style alphabet without 0/O/1/I/L/U to avoid read-aloud mistakes.
const CODE_ALPHABET = '23456789ABCDEFGHJKMNPQRSTVWXYZ';

/** 8-character invitation code (~39 bits). Short-lived, single-use, rate-limited on redemption. */
export function invitationCode(): string {
  const bytes = randomBytes(8);
  let out = '';
  for (const b of bytes) out += CODE_ALPHABET[b % CODE_ALPHABET.length];
  return out;
}

export function normalizeInvitationCode(code: string): string {
  return code.toUpperCase().replace(/[^0-9A-Z]/g, '');
}

export function hashSecret(value: string): string {
  return createHash('sha256').update(value).digest('hex');
}
