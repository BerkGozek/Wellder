// Storage abstraction modelled on DynamoDB's single-table primitives. The repository is written
// once against this interface; MemoryTable backs local dev/tests and DynamoTable backs AWS
// (and DynamoDB Local). Keeping the surface this small is what keeps both honest.

export interface Item {
  pk: string;
  sk: string;
  gsi1pk?: string;
  gsi1sk?: string;
  gsi2pk?: string;
  gsi2sk?: string;
  ttl?: number; // epoch seconds; DynamoDB TTL attribute
  version?: number;
  [key: string]: unknown;
}

export type IndexName = 'gsi1' | 'gsi2';

export interface SortKeyCondition {
  beginsWith?: string;
  between?: [string, string]; // inclusive
  lte?: string;
}

export interface QueryInput {
  index?: IndexName;
  pk: string;
  sk?: SortKeyCondition;
  limit?: number;
  forward?: boolean; // default true (ascending)
  cursor?: string;
}

export interface QueryResult {
  items: Item[];
  cursor?: string;
}

export type PutCondition = { kind: 'notExists' } | { kind: 'versionEquals'; version: number };

export class ConditionFailedError extends Error {
  constructor() {
    super('Conditional write failed');
    this.name = 'ConditionFailedError';
  }
}

export interface Table {
  get(pk: string, sk: string): Promise<Item | undefined>;
  /** Throws ConditionFailedError when `condition` does not hold. */
  put(item: Item, condition?: PutCondition): Promise<void>;
  delete(pk: string, sk: string): Promise<void>;
  query(input: QueryInput): Promise<QueryResult>;
  /** Unconditional writes; callers rely on deterministic keys for idempotency. */
  batchPut(items: Item[]): Promise<void>;
  batchDelete(keys: { pk: string; sk: string }[]): Promise<void>;
  /** Atomically adds `by` to a numeric attribute, creating the item if needed. Returns the new value. */
  increment(pk: string, sk: string, attribute: string, by: number, ttl?: number): Promise<number>;
}

export function encodeCursor(key: Record<string, unknown>): string {
  return Buffer.from(JSON.stringify(key)).toString('base64url');
}

export function decodeCursor(cursor: string): Record<string, unknown> {
  try {
    const parsed: unknown = JSON.parse(Buffer.from(cursor, 'base64url').toString('utf8'));
    if (typeof parsed === 'object' && parsed !== null) return parsed as Record<string, unknown>;
  } catch {
    // fall through
  }
  throw new Error('Invalid cursor');
}
