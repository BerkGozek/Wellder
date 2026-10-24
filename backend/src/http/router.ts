import type { DevAuth, Principal } from '../auth/auth.ts';
import { ApiError, notFound } from '../domain/errors.ts';
import * as account from '../services/account.ts';
import type { Deps } from '../services/deps.ts';
import * as queries from '../services/queries.ts';
import * as rel from '../services/relationships.ts';
import * as settings from '../services/settings.ts';
import { ingestTelemetry } from '../services/telemetry.ts';

// Transport-agnostic router shared by the Lambda handler and the local dev server.

export interface ApiRequest {
  method: string;
  path: string;
  query: Record<string, string | undefined>;
  body: unknown;
  principal?: Principal; // set by the transport after authentication
  authorization?: string; // raw header, for dev auth
}

export interface ApiResponse {
  status: number;
  body: unknown;
}

type Handler = (ctx: { deps: Deps; principal: Principal; params: Record<string, string>; req: ApiRequest }) => Promise<unknown>;

interface Route {
  method: string;
  pattern: RegExp;
  keys: string[];
  handler: Handler;
  status?: number;
}

const routes: Route[] = [];
function route(method: string, path: string, handler: Handler, status = 200) {
  const keys: string[] = [];
  const pattern = new RegExp(
    '^' +
      path.replace(/:([a-zA-Z]+)/g, (_, k: string) => {
        keys.push(k);
        return '([^/]+)';
      }) +
      '$',
  );
  routes.push({ method, pattern, keys, handler, status });
}

// Account & devices
route('GET', '/v1/me', ({ deps, principal }) => account.getMe(deps, principal));
route('PUT', '/v1/me', ({ deps, principal, req }) => account.putMe(deps, principal, req.body));
route('DELETE', '/v1/me', ({ deps, principal }) => account.deleteMe(deps, principal));
route('PUT', '/v1/devices/:deviceId', ({ deps, principal, params, req }) => account.putDevice(deps, principal, params.deviceId!, req.body));

// Pairing
route('POST', '/v1/invitations', ({ deps, principal, req }) => rel.createInvitation(deps, principal, req.body), 201);
route('GET', '/v1/invitations', ({ deps, principal }) => rel.listInvitations(deps, principal));
route('DELETE', '/v1/invitations/:invitationId', ({ deps, principal, params }) => rel.cancelInvitation(deps, principal, params.invitationId!));
route('POST', '/v1/invitations/redeem', ({ deps, principal, req }) => rel.redeemInvitation(deps, principal, req.body));
route('GET', '/v1/relationships', ({ deps, principal }) => rel.listRelationships(deps, principal));
route('POST', '/v1/relationships/:id/approve', ({ deps, principal, params, req }) => rel.approveRelationship(deps, principal, params.id!, req.body));
route('POST', '/v1/relationships/:id/reject', ({ deps, principal, params }) => rel.rejectRelationship(deps, principal, params.id!));
route('POST', '/v1/relationships/:id/revoke', ({ deps, principal, params }) => rel.revokeRelationship(deps, principal, params.id!));
route('PUT', '/v1/relationships/:id/permissions', ({ deps, principal, params, req }) => rel.updatePermissions(deps, principal, params.id!, req.body));

// Telemetry (Alpha devices)
route('POST', '/v1/telemetry', ({ deps, principal, req }) => ingestTelemetry(deps, principal, req.body));

// Monitoring reads
route('GET', '/v1/dashboard', ({ deps, principal }) => queries.dashboard(deps, principal));
route('GET', '/v1/alphas/:alphaId/summary', ({ deps, principal, params }) => queries.alphaSummary(deps, principal, params.alphaId!));
route('GET', '/v1/alphas/:alphaId/locations', ({ deps, principal, params, req }) => queries.locationHistory(deps, principal, params.alphaId!, req.query));
route('GET', '/v1/alphas/:alphaId/heart-rate', ({ deps, principal, params, req }) => queries.heartRateHistory(deps, principal, params.alphaId!, req.query));
route('GET', '/v1/alphas/:alphaId/activity', ({ deps, principal, params, req }) => queries.activityHistory(deps, principal, params.alphaId!, req.query));
route('GET', '/v1/alphas/:alphaId/alerts', ({ deps, principal, params, req }) => queries.listAlerts(deps, principal, params.alphaId!, req.query));
route('GET', '/v1/alphas/:alphaId/alerts/:alertId', ({ deps, principal, params }) => queries.alertDetail(deps, principal, params.alphaId!, params.alertId!));
route('POST', '/v1/alphas/:alphaId/alerts/:alertId/respond', ({ deps, principal, params, req }) => queries.respondToAlert(deps, principal, params.alphaId!, params.alertId!, req.body));
route('POST', '/v1/alphas/:alphaId/alerts/:alertId/acknowledge', ({ deps, principal, params }) => queries.acknowledgeAlert(deps, principal, params.alphaId!, params.alertId!));
route('POST', '/v1/alphas/:alphaId/alerts/:alertId/resolve', ({ deps, principal, params, req }) => queries.resolveAlert(deps, principal, params.alphaId!, params.alertId!, req.body));

// Settings & consent
route('GET', '/v1/alphas/:alphaId/settings', ({ deps, principal, params }) => settings.getSettings(deps, principal, params.alphaId!));
route('PUT', '/v1/me/settings', ({ deps, principal, req }) => settings.updateOwnSettings(deps, principal, req.body));
route('POST', '/v1/alphas/:alphaId/settings-requests', ({ deps, principal, params, req }) => settings.requestSettingsChange(deps, principal, params.alphaId!, req.body), 201);
route('GET', '/v1/alphas/:alphaId/settings-requests', ({ deps, principal, params }) => settings.listSettingsRequests(deps, principal, params.alphaId!));
route('POST', '/v1/me/settings-requests/:requestId/approve', ({ deps, principal, params }) => settings.decideSettingsRequest(deps, principal, params.requestId!, true));
route('POST', '/v1/me/settings-requests/:requestId/reject', ({ deps, principal, params }) => settings.decideSettingsRequest(deps, principal, params.requestId!, false));
route('GET', '/v1/me/audit', ({ deps, principal }) => settings.getAuditLog(deps, principal));

export interface RouterOptions {
  deps: Deps;
  devAuth?: DevAuth; // only in local development
}

export async function handle(req: ApiRequest, opts: RouterOptions): Promise<ApiResponse> {
  try {
    if (req.method === 'GET' && req.path === '/health') return { status: 200, body: { ok: true } };

    if (opts.devAuth && req.path.startsWith('/dev/auth/') && req.method === 'POST') {
      if (req.path === '/dev/auth/register') return { status: 201, body: await opts.devAuth.register(req.body) };
      if (req.path === '/dev/auth/login') return { status: 200, body: await opts.devAuth.login(req.body) };
    }

    const match = routes.find((r) => r.method === req.method && r.pattern.test(req.path));
    if (!match) throw notFound('No such endpoint');
    const principal = req.principal ?? opts.devAuth?.verify(req.authorization);
    if (!principal) throw new ApiError(401, 'unauthorized', 'Authentication required');
    const m = match.pattern.exec(req.path)!;
    const params = Object.fromEntries(match.keys.map((k, i) => [k, decodeURIComponent(m[i + 1]!)]));
    const body = await match.handler({ deps: opts.deps, principal, params, req });
    return { status: match.status ?? 200, body };
  } catch (err) {
    if (err instanceof ApiError) {
      // Route and code only: messages can name fields, never values, but keep logs minimal anyway.
      if (err.status !== 401) opts.deps.log.info('request.rejected', { method: req.method, route: req.path.split('/').slice(0, 3).join('/'), status: err.status, code: err.code });
      return { status: err.status, body: { error: { code: err.code, message: err.message } } };
    }
    opts.deps.log.error('request.failed', { method: req.method, route: req.path.split('/').slice(0, 3).join('/'), error: (err as Error).name });
    return { status: 500, body: { error: { code: 'internal', message: 'Internal error' } } };
  }
}
