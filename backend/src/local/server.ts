import { createServer } from 'node:http';
import { DevAuth } from '../auth/auth.ts';
import { providersFromEnv } from '../config.ts';
import { handle } from '../http/router.ts';
import { consoleLogger, type Logger } from '../log.ts';
import type { Deps } from '../services/deps.ts';
import { sweep } from '../services/sweeper.ts';
import { DynamoTable } from '../store/dynamoTable.ts';
import { ensureLocalTable } from '../store/localTable.ts';
import { MemoryTable } from '../store/memoryTable.ts';
import { Repository } from '../store/repository.ts';
import type { Table } from '../store/table.ts';

// Local development server: the same router and services as AWS, with an in-memory or
// DynamoDB Local store, local HMAC auth and recording (non-sending) notification providers.

export interface LocalServerOptions {
  port: number;
  host?: string; // default 127.0.0.1; use 0.0.0.0 to reach it from a physical iPhone on your LAN
  table: Table;
  log?: Logger;
  sweepIntervalSeconds?: number; // 0 disables the background sweeper
  now?: () => Date;
  devJwtSecret?: string;
}

export async function startLocalServer(opts: LocalServerOptions) {
  const env = { ...process.env };
  if (env.SMS_PROVIDER === 'twilio' || env.VOICE_PROVIDER === 'twilio') {
    throw new Error('Refusing to use paid Twilio providers from the local server. Use "log" or "disabled".');
  }
  const deps: Deps = {
    repo: new Repository(opts.table),
    providers: await providersFromEnv({ PUSH_PROVIDER: env.PUSH_PROVIDER ?? 'log', SMS_PROVIDER: env.SMS_PROVIDER ?? 'log', VOICE_PROVIDER: env.VOICE_PROVIDER ?? 'log', ...(env.APNS_SECRET_ARN ? { APNS_SECRET_ARN: env.APNS_SECRET_ARN } : {}) }),
    log: opts.log ?? consoleLogger,
    now: opts.now ?? (() => new Date()),
  };
  const devAuth = new DevAuth(opts.table, opts.devJwtSecret);
  deps.deleteIdentity = ({ email }) => devAuth.deleteCredentials(email);

  const server = createServer(async (req, res) => {
    const chunks: Buffer[] = [];
    let size = 0;
    for await (const c of req) {
      size += (c as Buffer).length;
      if (size > 512 * 1024) {
        res.writeHead(413).end();
        return;
      }
      chunks.push(c as Buffer);
    }
    const url = new URL(req.url ?? '/', 'http://localhost');
    let body: unknown;
    try {
      body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : undefined;
    } catch {
      res.writeHead(400, { 'content-type': 'application/json' }).end(JSON.stringify({ error: { code: 'bad_request', message: 'Body must be JSON' } }));
      return;
    }
    const result = await handle(
      {
        method: req.method ?? 'GET',
        path: url.pathname,
        query: Object.fromEntries(url.searchParams),
        body,
        ...(req.headers.authorization ? { authorization: req.headers.authorization } : {}),
      },
      { deps, devAuth },
    );
    res.writeHead(result.status, { 'content-type': 'application/json', 'cache-control': 'no-store' }).end(JSON.stringify(result.body));
  });

  await new Promise<void>((resolve) => server.listen(opts.port, opts.host ?? '127.0.0.1', resolve));
  const address = server.address();
  const port = typeof address === 'object' && address ? address.port : opts.port;

  let timer: NodeJS.Timeout | undefined;
  if (opts.sweepIntervalSeconds) {
    timer = setInterval(() => void sweep(deps).catch((e: Error) => deps.log.error('sweep.failed', { error: e.name })), opts.sweepIntervalSeconds * 1000);
  }
  return {
    port,
    deps,
    devAuth,
    close: async () => {
      if (timer) clearInterval(timer);
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}

if (import.meta.main) {
  const port = Number(process.env.PORT ?? 8787);
  const store = process.env.STORE ?? 'memory';
  let table: Table;
  if (store === 'dynamo') {
    const endpoint = process.env.DYNAMO_ENDPOINT ?? 'http://localhost:8000';
    const tableName = process.env.TABLE_NAME ?? 'Wellder-local';
    const dt = new DynamoTable({ tableName, endpoint });
    await ensureLocalTable(dt);
    table = dt;
  } else {
    table = new MemoryTable();
  }
  const s = await startLocalServer({
    port,
    host: process.env.HOST ?? '127.0.0.1',
    table,
    sweepIntervalSeconds: Number(process.env.SWEEP_INTERVAL_SECONDS ?? 15),
    ...(process.env.DEV_JWT_SECRET ? { devJwtSecret: process.env.DEV_JWT_SECRET } : {}),
  });
  console.log(`Wellder local backend on http://${process.env.HOST ?? '127.0.0.1'}:${s.port} (store=${store}, auth=dev, push/sms/voice=recorded only)`);
}
