import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { describe, it } from 'node:test';
import { DynamoTable } from '../src/store/dynamoTable.ts';
import { ensureLocalTable } from '../src/store/localTable.ts';
import { MemoryTable } from '../src/store/memoryTable.ts';
import { ConditionFailedError, type Table } from '../src/store/table.ts';

// One contract, two implementations. DynamoDB Local runs only when DYNAMO_TEST_ENDPOINT is set
// (npm run ddb:up && npm run test:dynamo).

const targets: { name: string; make: () => Promise<Table> }[] = [{ name: 'MemoryTable', make: async () => new MemoryTable() }];
if (process.env.DYNAMO_TEST_ENDPOINT) {
  targets.push({
    name: 'DynamoTable (DynamoDB Local)',
    make: async () => {
      const t = new DynamoTable({ tableName: 'Wellder-test', endpoint: process.env.DYNAMO_TEST_ENDPOINT! });
      await ensureLocalTable(t);
      return t;
    },
  });
}

for (const target of targets) {
  describe(`table contract: ${target.name}`, () => {
    it('put/get/delete with conditions', async () => {
      const t = await target.make();
      const pk = `P#${randomUUID()}`;
      await t.put({ pk, sk: 'A', version: 1, v: 'x' }, { kind: 'notExists' });
      await assert.rejects(t.put({ pk, sk: 'A', version: 1 }, { kind: 'notExists' }), ConditionFailedError);
      await t.put({ pk, sk: 'A', version: 2, v: 'y' }, { kind: 'versionEquals', version: 1 });
      await assert.rejects(t.put({ pk, sk: 'A', version: 3 }, { kind: 'versionEquals', version: 1 }), ConditionFailedError);
      assert.equal((await t.get(pk, 'A'))?.v, 'y');
      await t.delete(pk, 'A');
      assert.equal(await t.get(pk, 'A'), undefined);
    });

    it('queries by sort-key range with ordering and pagination', async () => {
      const t = await target.make();
      const pk = `P#${randomUUID()}`;
      await t.batchPut(Array.from({ length: 30 }, (_, i) => ({ pk, sk: `2026-01-01T00:${String(i).padStart(2, '0')}:00Z#x`, n: i })));
      const range = await t.query({ pk, sk: { between: ['2026-01-01T00:05', '2026-01-01T00:09￿'] } });
      assert.deepEqual(range.items.map((i) => i.n), [5, 6, 7, 8, 9]);
      const newest = await t.query({ pk, forward: false, limit: 3 });
      assert.deepEqual(newest.items.map((i) => i.n), [29, 28, 27]);
      const page1 = await t.query({ pk, limit: 20 });
      assert.ok(page1.cursor);
      const page2 = await t.query({ pk, limit: 20, cursor: page1.cursor! });
      assert.equal(page1.items.length + page2.items.length, 30);
      assert.equal(page2.cursor, undefined);
      assert.equal((await t.query({ pk, sk: { lte: '2026-01-01T00:02￿' } })).items.length, 3);
    });

    it('queries secondary indexes and prefixes', async () => {
      const t = await target.make();
      const g = `G#${randomUUID()}`;
      await t.put({ pk: 'X1', sk: 'REL#1', gsi1pk: g, gsi1sk: 'REL#a' });
      await t.put({ pk: 'X2', sk: 'REL#2', gsi1pk: g, gsi1sk: 'REL#b' });
      await t.put({ pk: 'X3', sk: 'INV', gsi1pk: g, gsi1sk: 'INV#c' });
      const rels = await t.query({ index: 'gsi1', pk: g, sk: { beginsWith: 'REL#' } });
      assert.deepEqual(rels.items.map((i) => i.pk).sort(), ['X1', 'X2']);
    });

    it('hides expired items and counts atomically', async () => {
      const t = await target.make();
      const pk = `P#${randomUUID()}`;
      await t.put({ pk, sk: 'old', ttl: Math.floor(Date.now() / 1000) - 10 });
      await t.put({ pk, sk: 'new', ttl: Math.floor(Date.now() / 1000) + 3600 });
      assert.equal(await t.get(pk, 'old'), undefined);
      assert.deepEqual((await t.query({ pk })).items.map((i) => i.sk), ['new']);
      await t.put({ pk, sk: 'old', ttl: Math.floor(Date.now() / 1000) + 60 }, { kind: 'notExists' }); // expired = absent
      assert.equal(await t.increment(pk, 'c', 'count', 1, Math.floor(Date.now() / 1000) + 60), 1);
      assert.equal(await t.increment(pk, 'c', 'count', 1), 2);
    });
  });
}
