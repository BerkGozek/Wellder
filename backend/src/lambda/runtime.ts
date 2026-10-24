import { AdminDeleteUserCommand, CognitoIdentityProviderClient, UserNotFoundException } from '@aws-sdk/client-cognito-identity-provider';
import { providersFromEnv } from '../config.ts';
import { consoleLogger } from '../log.ts';
import type { Deps } from '../services/deps.ts';
import { DynamoTable } from '../store/dynamoTable.ts';
import { Repository } from '../store/repository.ts';

let cached: Promise<Deps> | undefined;

/** Lazily builds dependencies once per Lambda execution environment. */
export function lambdaDeps(): Promise<Deps> {
  cached ??= (async () => {
    const tableName = process.env.TABLE_NAME;
    if (!tableName) throw new Error('TABLE_NAME is not set');
    const userPoolId = process.env.COGNITO_USER_POOL_ID;
    const cognito = userPoolId ? new CognitoIdentityProviderClient({}) : undefined;
    return {
      repo: new Repository(new DynamoTable({ tableName })),
      providers: await providersFromEnv(process.env),
      log: consoleLogger,
      now: () => new Date(),
      // Email-alias pools use the `sub` as the username.
      ...(cognito && userPoolId
        ? {
            deleteIdentity: async ({ userId }: { userId: string }) => {
              try {
                await cognito.send(new AdminDeleteUserCommand({ UserPoolId: userPoolId, Username: userId }));
              } catch (err) {
                if (!(err instanceof UserNotFoundException)) throw err;
              }
            },
          }
        : {}),
    };
  })();
  return cached;
}
