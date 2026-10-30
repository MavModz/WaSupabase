// ============================================================
// POST /api/internal/entitlements — operator controls (REQ-O1).
//
// For the SaaS operator, not a customer role: there is no session here,
// and a customer owner can't reach the RPCs behind it (service role only,
// migration 067). Header `x-operator-secret` is compared in constant time
// with ENTITLEMENTS_OPERATOR_SECRET, and the route answers 503 when that
// is unset, the same shape as the cron routes.
//
// Body: { op, actor, account_id?, ...per-op fields }, see `run` below.
// Each changing op writes exactly one entitlement_audit_log row in the
// RPC's own transaction. Runbook: docs/entitlements.md.
//
// Off-switch note: this route works with the switch off, because
// `set_enabled` has to, and setting up plans before go-live is legitimate.
// ============================================================

import { timingSafeEqual } from 'node:crypto';
import { NextResponse } from 'next/server';

import { supabaseAdmin } from '@/lib/flows/admin-client';
import { isUuid } from '@/lib/api/v1/pagination';
import { isEntitlementsEnabled } from '@/lib/entitlements/config';
import { fromPostgrestError } from '@/lib/entitlements/errors';
import { log, requestIdOf, withLogContext } from '@/lib/log';
import {
  checkRateLimit,
  getClientIp,
  rateLimitResponse,
  RATE_LIMITS,
} from '@/lib/rate-limit';

type Body = Record<string, unknown>;
type RpcCall = { fn: string; args: Record<string, unknown> };

class BadRequest extends Error {}

function str(body: Body, key: string): string {
  const value = body[key];
  if (typeof value !== 'string' || !value.trim()) {
    throw new BadRequest(`'${key}' is required`);
  }
  return value.trim();
}

function optStr(body: Body, key: string): string | null {
  return typeof body[key] === 'string' && body[key] ? (body[key] as string) : null;
}

function isoDate(body: Body, key: string, required: boolean): string | null {
  const value = body[key];
  if (value === undefined || value === null) {
    if (required) throw new BadRequest(`'${key}' is required`);
    return null;
  }
  if (typeof value !== 'string' || Number.isNaN(Date.parse(value))) {
    throw new BadRequest(`'${key}' must be an ISO date`);
  }
  return new Date(value).toISOString();
}

function jsonObject(body: Body, key: string): Record<string, unknown> | null {
  const value = body[key];
  if (value === undefined || value === null) return null;
  if (typeof value !== 'object' || Array.isArray(value)) {
    throw new BadRequest(`'${key}' must be an object`);
  }
  return value as Record<string, unknown>;
}

function accountOf(body: Body): string {
  const id = str(body, 'account_id');
  if (!isUuid(id)) throw new BadRequest("'account_id' must be a uuid");
  return id;
}

/** Map an op to its RPC. Throws {@link BadRequest} on a malformed body. */
function buildCall(op: string, body: Body): RpcCall {
  const actor = str(body, 'actor');
  const reason = optStr(body, 'reason');
  switch (op) {
    case 'set_plan':
      return {
        fn: 'ent_set_plan',
        args: {
          p_account: accountOf(body),
          p_plan: str(body, 'plan'),
          p_actor: actor,
          p_reason: reason,
          p_keep: jsonObject(body, 'keep'),
        },
      };
    case 'set_state':
      return {
        fn: 'ent_set_state',
        args: {
          p_account: accountOf(body),
          p_state: str(body, 'state'),
          p_actor: actor,
          p_reason: reason,
        },
      };
    case 'set_trial_end':
      return {
        fn: 'ent_set_trial_end',
        args: {
          p_account: accountOf(body),
          p_trial_ends_at: isoDate(body, 'trial_ends_at', true),
          p_actor: actor,
          p_reason: reason,
        },
      };
    case 'schedule_change':
      return {
        fn: 'ent_schedule_change',
        args: {
          p_account: accountOf(body),
          p_plan: str(body, 'plan'),
          p_actor: actor,
          p_at: isoDate(body, 'at', false),
          p_keep: jsonObject(body, 'keep') ?? {},
          p_reason: reason,
        },
      };
    case 'cancel_change':
      return {
        fn: 'ent_cancel_change',
        args: { p_account: accountOf(body), p_actor: actor, p_reason: reason },
      };
    case 'set_override': {
      const overrides = jsonObject(body, 'overrides');
      if (!overrides) throw new BadRequest("'overrides' is required");
      return {
        fn: 'ent_set_override',
        args: {
          p_account: accountOf(body),
          p_overrides: overrides,
          p_actor: actor,
          p_reason: reason,
        },
      };
    }
    case 'preview':
      return {
        fn: 'ent_downgrade_preview',
        args: { p_account: accountOf(body), p_plan: str(body, 'plan') },
      };
    case 'status':
      return { fn: 'account_entitlements', args: { p_account: accountOf(body) } };
    case 'usage':
      return { fn: 'account_usage', args: { p_account: accountOf(body) } };
    case 'set_enabled':
      if (typeof body.enabled !== 'boolean') {
        throw new BadRequest("'enabled' must be a boolean");
      }
      return {
        fn: 'entitlements_set_enabled',
        args: { p_enabled: body.enabled, p_actor: actor, p_reason: reason },
      };
    default:
      throw new BadRequest(`Unknown op '${op}'`);
  }
}

const READ_ONLY_OPS = new Set(['preview', 'status', 'usage']);

function secretMatches(supplied: string, expected: string): boolean {
  const a = Buffer.from(supplied);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

async function run(request: Request): Promise<NextResponse> {
  const body = (await request.json().catch(() => null)) as Body | null;
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return NextResponse.json({ error: 'Request body must be a JSON object' }, { status: 400 });
  }

  const op = typeof body.op === 'string' ? body.op : '';
  let call: RpcCall;
  try {
    call = buildCall(op, body);
  } catch (err) {
    if (err instanceof BadRequest) {
      return NextResponse.json({ error: err.message }, { status: 400 });
    }
    throw err;
  }

  const { data, error } = await supabaseAdmin().rpc(call.fn, call.args);

  if (error) {
    const planErr = fromPostgrestError(error);
    if (planErr) {
      return NextResponse.json(planErr.apiBody(), { status: planErr.status });
    }
    if (error.code === '22023') {
      return NextResponse.json({ error: error.message }, { status: 400 });
    }
    if (error.code === 'P0002') {
      return NextResponse.json({ error: 'Account not found' }, { status: 404 });
    }
    log.error('entitlements.operator_failed', { op, err: error });
    return NextResponse.json({ error: 'Operator call failed' }, { status: 500 });
  }

  if (!READ_ONLY_OPS.has(op)) {
    // The old and new values are on the audit row written by the RPC.
    log.info('entitlements.operator_change', {
      op,
      actor: body.actor,
      accountId: typeof body.account_id === 'string' ? body.account_id : null,
    });
  }

  return NextResponse.json({
    result: data,
    // A mismatch means the two halves of the switch disagree, which
    // leaves enforcement off. Surfaced so the operator notices right away.
    env_enabled: isEntitlementsEnabled(),
  });
}

export async function POST(request: Request) {
  const expected = process.env.ENTITLEMENTS_OPERATOR_SECRET;
  if (!expected) {
    return NextResponse.json({ error: 'operator endpoint not configured' }, { status: 503 });
  }

  // Before the secret check, so guessing it is throttled too.
  const limit = await checkRateLimit(
    `entitlements-operator:${getClientIp(request)}`,
    RATE_LIMITS.adminAction
  );
  if (!limit.success) return rateLimitResponse(limit);

  if (!secretMatches(request.headers.get('x-operator-secret') ?? '', expected)) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  return withLogContext(
    { requestId: requestIdOf(request), route: 'entitlements.operator' },
    () => run(request)
  );
}
