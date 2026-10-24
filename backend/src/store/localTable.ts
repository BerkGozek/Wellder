import { CreateTableCommand, DescribeTableCommand, ResourceNotFoundException } from '@aws-sdk/client-dynamodb';
import type { DynamoTable } from './dynamoTable.ts';

/** Creates the table in DynamoDB Local with the same key schema as infrastructure/lib/stack.ts. */
export async function ensureLocalTable(t: DynamoTable): Promise<void> {
  try {
    await t.client.send(new DescribeTableCommand({ TableName: t.tableName }));
    return;
  } catch (err) {
    if (!(err instanceof ResourceNotFoundException)) throw err;
  }
  const s = (name: string) => ({ AttributeName: name, AttributeType: 'S' as const });
  await t.client.send(
    new CreateTableCommand({
      TableName: t.tableName,
      BillingMode: 'PAY_PER_REQUEST',
      AttributeDefinitions: [s('pk'), s('sk'), s('gsi1pk'), s('gsi1sk'), s('gsi2pk'), s('gsi2sk')],
      KeySchema: [
        { AttributeName: 'pk', KeyType: 'HASH' },
        { AttributeName: 'sk', KeyType: 'RANGE' },
      ],
      GlobalSecondaryIndexes: ['gsi1', 'gsi2'].map((g) => ({
        IndexName: g,
        KeySchema: [
          { AttributeName: `${g}pk`, KeyType: 'HASH' as const },
          { AttributeName: `${g}sk`, KeyType: 'RANGE' as const },
        ],
        Projection: { ProjectionType: 'ALL' as const },
      })),
    }),
  );
}
