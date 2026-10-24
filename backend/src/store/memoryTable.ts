import {
  ConditionFailedError,
  decodeCursor,
  encodeCursor,
  type Item,
  type PutCondition,
  type QueryInput,
  type QueryResult,
  type Table,
} from './table.ts';

/** In-process table for local development and tests. Mirrors DynamoDB semantics closely enough
 *  that the same repository code passes the same tests against both (see tests/store.test.ts). */
export class MemoryTable implements Table {
  private readonly items = new Map<string, Item>();
  private readonly now: () => Date;

  constructor(now: () => Date = () => new Date()) {
    this.now = now;
  }

  private key(pk: string, sk: string): string {
    return `${pk}\u0000${sk}`;
  }

  private expired(item: Item): boolean {
    return item.ttl !== undefined && item.ttl * 1000 <= this.now().getTime();
  }

  async get(pk: string, sk: string): Promise<Item | undefined> {
    const item = this.items.get(this.key(pk, sk));
    return item && !this.expired(item) ? structuredClone(item) : undefined;
  }

  async put(item: Item, condition?: PutCondition): Promise<void> {
    const k = this.key(item.pk, item.sk);
    const existingRaw = this.items.get(k);
    const existing = existingRaw && !this.expired(existingRaw) ? existingRaw : undefined;
    if (condition?.kind === 'notExists' && existing) throw new ConditionFailedError();
    if (condition?.kind === 'versionEquals' && existing?.version !== condition.version) throw new ConditionFailedError();
    this.items.set(k, structuredClone(item));
  }

  async delete(pk: string, sk: string): Promise<void> {
    this.items.delete(this.key(pk, sk));
  }

  async query(input: QueryInput): Promise<QueryResult> {
    const pkAttr = input.index ? `${input.index}pk` : 'pk';
    const skAttr = input.index ? `${input.index}sk` : 'sk';
    const matches = [...this.items.values()]
      .filter((it) => !this.expired(it) && it[pkAttr] === input.pk && typeof it[skAttr] === 'string')
      .filter((it) => {
        const sk = it[skAttr] as string;
        const c = input.sk;
        if (!c) return true;
        if (c.beginsWith !== undefined && !sk.startsWith(c.beginsWith)) return false;
        if (c.between && (sk < c.between[0] || sk > c.between[1])) return false;
        if (c.lte !== undefined && sk > c.lte) return false;
        return true;
      })
      .sort((a, b) => {
        const x = `${a[skAttr] as string}\u0000${a.pk}\u0000${a.sk}`;
        const y = `${b[skAttr] as string}\u0000${b.pk}\u0000${b.sk}`;
        return x < y ? -1 : x > y ? 1 : 0;
      });
    if (input.forward === false) matches.reverse();

    let start = 0;
    if (input.cursor) {
      const c = decodeCursor(input.cursor);
      const idx = matches.findIndex((it) => it.pk === c.pk && it.sk === c.sk);
      start = idx >= 0 ? idx + 1 : matches.length;
    }
    const limit = input.limit ?? 1000;
    const page = matches.slice(start, start + limit);
    const last = page[page.length - 1];
    const more = start + limit < matches.length;
    return {
      items: page.map((it) => structuredClone(it)),
      ...(more && last ? { cursor: encodeCursor({ pk: last.pk, sk: last.sk }) } : {}),
    };
  }

  async batchPut(items: Item[]): Promise<void> {
    for (const it of items) this.items.set(this.key(it.pk, it.sk), structuredClone(it));
  }

  async batchDelete(keys: { pk: string; sk: string }[]): Promise<void> {
    for (const k of keys) this.items.delete(this.key(k.pk, k.sk));
  }

  async increment(pk: string, sk: string, attribute: string, by: number, ttl?: number): Promise<number> {
    const k = this.key(pk, sk);
    const raw = this.items.get(k);
    const existing = raw && !this.expired(raw) ? raw : { pk, sk, ...(ttl ? { ttl } : {}) };
    const next = (typeof existing[attribute] === 'number' ? (existing[attribute] as number) : 0) + by;
    this.items.set(k, { ...existing, [attribute]: next });
    return next;
  }

  /** Test helper. */
  size(): number {
    return this.items.size;
  }
}
