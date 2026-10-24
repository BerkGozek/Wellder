import { ConditionalCheckFailedException, DynamoDBClient } from '@aws-sdk/client-dynamodb';
import {
  BatchWriteCommand,
  DeleteCommand,
  DynamoDBDocumentClient,
  GetCommand,
  PutCommand,
  QueryCommand,
  UpdateCommand,
  type QueryCommandInput,
} from '@aws-sdk/lib-dynamodb';
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

export interface DynamoTableOptions {
  tableName: string;
  endpoint?: string; // DynamoDB Local
  region?: string;
}

export class DynamoTable implements Table {
  private readonly doc: DynamoDBDocumentClient;
  readonly tableName: string;
  readonly client: DynamoDBClient;

  constructor(opts: DynamoTableOptions) {
    this.tableName = opts.tableName;
    this.client = new DynamoDBClient({
      ...(opts.region ? { region: opts.region } : {}),
      ...(opts.endpoint
        ? { endpoint: opts.endpoint, region: opts.region ?? 'local', credentials: { accessKeyId: 'local', secretAccessKey: 'local' } }
        : {}),
    });
    this.doc = DynamoDBDocumentClient.from(this.client, { marshallOptions: { removeUndefinedValues: true } });
  }

  async get(pk: string, sk: string): Promise<Item | undefined> {
    const res = await this.doc.send(new GetCommand({ TableName: this.tableName, Key: { pk, sk }, ConsistentRead: true }));
    const item = res.Item as Item | undefined;
    // DynamoDB deletes expired items lazily (up to days later); hide them like MemoryTable does.
    if (item?.ttl !== undefined && item.ttl * 1000 <= Date.now()) return undefined;
    return item;
  }

  async put(item: Item, condition?: PutCondition): Promise<void> {
    try {
      await this.doc.send(
        new PutCommand({
          TableName: this.tableName,
          Item: item,
          ...(condition?.kind === 'notExists'
            ? {
                // An expired-but-not-yet-deleted item counts as absent.
                ConditionExpression: 'attribute_not_exists(pk) OR (attribute_exists(#ttl) AND #ttl <= :now)',
                ExpressionAttributeNames: { '#ttl': 'ttl' },
                ExpressionAttributeValues: { ':now': Math.floor(Date.now() / 1000) },
              }
            : {}),
          ...(condition?.kind === 'versionEquals'
            ? {
                ConditionExpression: '#v = :v',
                ExpressionAttributeNames: { '#v': 'version' },
                ExpressionAttributeValues: { ':v': condition.version },
              }
            : {}),
        }),
      );
    } catch (err) {
      if (err instanceof ConditionalCheckFailedException) throw new ConditionFailedError();
      throw err;
    }
  }

  async delete(pk: string, sk: string): Promise<void> {
    await this.doc.send(new DeleteCommand({ TableName: this.tableName, Key: { pk, sk } }));
  }

  async query(input: QueryInput): Promise<QueryResult> {
    const pkAttr = input.index ? `${input.index}pk` : 'pk';
    const skAttr = input.index ? `${input.index}sk` : 'sk';
    const names: Record<string, string> = { '#pk': pkAttr };
    const values: Record<string, unknown> = { ':pk': input.pk };
    let keyExpr = '#pk = :pk';
    if (input.sk) {
      names['#sk'] = skAttr;
      if (input.sk.beginsWith !== undefined) {
        keyExpr += ' AND begins_with(#sk, :skp)';
        values[':skp'] = input.sk.beginsWith;
      } else if (input.sk.between) {
        keyExpr += ' AND #sk BETWEEN :a AND :b';
        values[':a'] = input.sk.between[0];
        values[':b'] = input.sk.between[1];
      } else if (input.sk.lte !== undefined) {
        keyExpr += ' AND #sk <= :lte';
        values[':lte'] = input.sk.lte;
      }
    }
    names['#ttl'] = 'ttl';
    values[':now'] = Math.floor(Date.now() / 1000);
    const params: QueryCommandInput = {
      TableName: this.tableName,
      KeyConditionExpression: keyExpr,
      FilterExpression: 'attribute_not_exists(#ttl) OR #ttl > :now',
      ExpressionAttributeNames: names,
      ExpressionAttributeValues: values,
      ScanIndexForward: input.forward !== false,
      ...(input.index ? { IndexName: input.index } : { ConsistentRead: true }),
      ...(input.cursor ? { ExclusiveStartKey: decodeCursor(input.cursor) } : {}),
    };
    // A FilterExpression is applied after Limit, so keep reading until the page is full.
    const want = input.limit ?? 1000;
    const items: Item[] = [];
    let lastKey: Record<string, unknown> | undefined;
    do {
      const res = await this.doc.send(new QueryCommand({ ...params, Limit: want - items.length, ...(lastKey ? { ExclusiveStartKey: lastKey } : {}) }));
      items.push(...((res.Items ?? []) as Item[]));
      lastKey = res.LastEvaluatedKey as Record<string, unknown> | undefined;
    } while (lastKey && items.length < want);
    return { items, ...(lastKey ? { cursor: encodeCursor(lastKey) } : {}) };
  }

  async batchPut(items: Item[]): Promise<void> {
    await this.batchWrite(items.map((Item) => ({ PutRequest: { Item } })));
  }

  async batchDelete(keys: { pk: string; sk: string }[]): Promise<void> {
    await this.batchWrite(keys.map((Key) => ({ DeleteRequest: { Key } })));
  }

  private async batchWrite(requests: Record<string, unknown>[]): Promise<void> {
    for (let i = 0; i < requests.length; i += 25) {
      let pending = requests.slice(i, i + 25);
      for (let attempt = 0; pending.length > 0; attempt++) {
        if (attempt > 6) throw new Error('BatchWrite: unprocessed items after retries');
        if (attempt > 0) await new Promise((r) => setTimeout(r, 50 * 2 ** attempt));
        const res = await this.doc.send(new BatchWriteCommand({ RequestItems: { [this.tableName]: pending as never } }));
        pending = (res.UnprocessedItems?.[this.tableName] ?? []) as Record<string, unknown>[];
      }
    }
  }

  async increment(pk: string, sk: string, attribute: string, by: number, ttl?: number): Promise<number> {
    const res = await this.doc.send(
      new UpdateCommand({
        TableName: this.tableName,
        Key: { pk, sk },
        UpdateExpression: ttl ? 'ADD #a :by SET #ttl = if_not_exists(#ttl, :ttl)' : 'ADD #a :by',
        ExpressionAttributeNames: { '#a': attribute, ...(ttl ? { '#ttl': 'ttl' } : {}) },
        ExpressionAttributeValues: { ':by': by, ...(ttl ? { ':ttl': ttl } : {}) },
        ReturnValues: 'UPDATED_NEW',
      }),
    );
    return Number(res.Attributes?.[attribute] ?? by);
  }
}
