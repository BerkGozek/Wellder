import { badRequest } from './errors.ts';
import { PERMISSIONS, type PermissionSet } from './types.ts';

// Minimal, dependency-free validators. Each one either returns a typed value or throws a 400.
// Error messages name the field but never echo the submitted value (it may be health data).

export type Json = Record<string, unknown>;

export function obj(value: unknown, field = 'body'): Json {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw badRequest(`${field} must be an object`);
  return value as Json;
}

export function str(o: Json, key: string, opts: { min?: number; max?: number; pattern?: RegExp } = {}): string {
  const v = o[key];
  if (v === undefined || v === null) throw badRequest(`${key} is required`);
  if (typeof v !== 'string') throw badRequest(`${key} must be a string`);
  const t = v.trim();
  if (t.length < (opts.min ?? 1)) throw badRequest(`${key} is too short`);
  if (t.length > (opts.max ?? 256)) throw badRequest(`${key} is too long`);
  if (opts.pattern && !opts.pattern.test(t)) throw badRequest(`${key} has an invalid format`);
  return t;
}

export function optStr(o: Json, key: string, opts: { min?: number; max?: number; pattern?: RegExp } = {}): string | undefined {
  return o[key] === undefined || o[key] === null ? undefined : str(o, key, opts);
}

export function num(o: Json, key: string, min: number, max: number, opts: { integer?: boolean } = {}): number {
  const v = o[key];
  if (typeof v !== 'number' || !Number.isFinite(v)) throw badRequest(`${key} must be a number`);
  if (v < min || v > max) throw badRequest(`${key} must be between ${min} and ${max}`);
  if (opts.integer && !Number.isInteger(v)) throw badRequest(`${key} must be an integer`);
  return v;
}

export function optNum(o: Json, key: string, min: number, max: number, opts: { integer?: boolean } = {}): number | undefined {
  return o[key] === undefined || o[key] === null ? undefined : num(o, key, min, max, opts);
}

export function bool(o: Json, key: string): boolean {
  const v = o[key];
  if (typeof v !== 'boolean') throw badRequest(`${key} must be a boolean`);
  return v;
}

export function optBool(o: Json, key: string): boolean | undefined {
  return o[key] === undefined || o[key] === null ? undefined : bool(o, key);
}

export function oneOf<T extends string>(o: Json, key: string, allowed: readonly T[]): T {
  const v = o[key];
  if (typeof v !== 'string' || !(allowed as readonly string[]).includes(v)) {
    throw badRequest(`${key} must be one of: ${allowed.join(', ')}`);
  }
  return v as T;
}

export function arr(o: Json, key: string, max: number, opts: { optional?: boolean } = {}): unknown[] {
  const v = o[key];
  if (v === undefined && opts.optional) return [];
  if (!Array.isArray(v)) throw badRequest(`${key} must be an array`);
  if (v.length > max) throw badRequest(`${key} may contain at most ${max} items`);
  return v;
}

export const UUIDISH = /^[A-Za-z0-9-]{8,64}$/;
export const PHONE_E164 = /^\+[1-9]\d{6,14}$/;
export const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function isoTimestamp(o: Json, key: string, opts: { notBefore?: number; notAfter?: number } = {}): string {
  const v = str(o, key, { max: 40 });
  // Require an explicit offset: Date.parse would read "2026-01-01T10:00:00" as server-local time.
  if (!/(Z|[+-]\d{2}:\d{2})$/.test(v)) throw badRequest(`${key} must include a time-zone offset (e.g. Z)`);
  const t = Date.parse(v);
  if (Number.isNaN(t)) throw badRequest(`${key} must be an ISO-8601 timestamp`);
  if (opts.notBefore !== undefined && t < opts.notBefore) throw badRequest(`${key} is too far in the past`);
  if (opts.notAfter !== undefined && t > opts.notAfter) throw badRequest(`${key} is in the future`);
  return new Date(t).toISOString();
}

export function permissionSet(value: unknown, base: PermissionSet): PermissionSet {
  const o = obj(value, 'permissions');
  const out = { ...base };
  for (const [k, v] of Object.entries(o)) {
    if (!(PERMISSIONS as readonly string[]).includes(k)) throw badRequest(`Unknown permission: ${k}`);
    if (typeof v !== 'boolean') throw badRequest(`permissions.${k} must be a boolean`);
    out[k as keyof PermissionSet] = v;
  }
  return out;
}

export function parseTimeRange(query: Record<string, string | undefined>, now: Date, maxDays = 31): { from: string; to: string } {
  const to = query.to ? Date.parse(query.to) : now.getTime();
  const from = query.from ? Date.parse(query.from) : to - 24 * 3600_000;
  if (Number.isNaN(from) || Number.isNaN(to)) throw badRequest('from/to must be ISO-8601 timestamps');
  if (from > to) throw badRequest('from must be before to');
  if (to - from > maxDays * 24 * 3600_000) throw badRequest(`Range may not exceed ${maxDays} days`);
  return { from: new Date(from).toISOString(), to: new Date(to).toISOString() };
}
