import { principalFromCognitoClaims } from '../auth/auth.ts';
import { handle } from '../http/router.ts';
import { lambdaDeps } from './runtime.ts';

// API Gateway HTTP API (payload v2) → router. The JWT authorizer has already verified the
// Cognito ID token; we read the verified claims from the request context.

interface HttpApiEvent {
  rawPath: string;
  requestContext: { http: { method: string }; authorizer?: { jwt?: { claims?: Record<string, unknown> } } };
  queryStringParameters?: Record<string, string>;
  body?: string;
  isBase64Encoded?: boolean;
}

const MAX_BODY_BYTES = 512 * 1024;

export async function handler(event: HttpApiEvent) {
  const deps = await lambdaDeps();
  const raw = event.body ? (event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString('utf8') : event.body) : undefined;
  if (raw && Buffer.byteLength(raw) > MAX_BODY_BYTES) return json(413, { error: { code: 'too_large', message: 'Request body too large' } });
  let body: unknown;
  try {
    body = raw ? JSON.parse(raw) : undefined;
  } catch {
    return json(400, { error: { code: 'bad_request', message: 'Body must be JSON' } });
  }
  let principal;
  try {
    principal = principalFromCognitoClaims(event.requestContext.authorizer?.jwt?.claims);
  } catch {
    principal = undefined; // /health is the only unauthenticated route; the router rejects the rest
  }
  const res = await handle(
    { method: event.requestContext.http.method, path: event.rawPath, query: event.queryStringParameters ?? {}, body, ...(principal ? { principal } : {}) },
    { deps },
  );
  return json(res.status, res.body);
}

function json(statusCode: number, body: unknown) {
  return {
    statusCode,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
    body: JSON.stringify(body),
  };
}
