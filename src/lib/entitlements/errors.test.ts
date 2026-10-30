import { describe, expect, it } from 'vitest';

import { toApiErrorResponse } from '@/lib/api/v1/respond';
import { toErrorResponse } from '@/lib/auth/account';
import { PlanLimitError, fromPostgrestError, planErrorResponse } from './errors';
import { parsePlanError } from './parse';

const pg = (code: string, detail: Record<string, unknown>) => ({
  code,
  message: String(detail.code),
  details: JSON.stringify(detail),
  hint: null,
});

const LIMIT = pg('WA001', { code: 'plan_limit_reached', resource: 'contacts', usage: 5000, limit: 5000 });
const FLAG = pg('WA002', { code: 'plan_feature_unavailable', resource: 'ai_auto_reply', reason: 'not_on_plan' });
const PERIOD = pg('WA001', {
  code: 'plan_limit_reached',
  resource: 'broadcast_recipients',
  usage: 9990,
  limit: 10000,
  requested: 20,
  remaining: 10,
  resets_at: '2026-12-01T00:00:00+00:00',
});

describe('parsePlanError', () => {
  it('ignores anything that is not a WA00x error', () => {
    expect(parsePlanError(null)).toBeNull();
    expect(parsePlanError(new Error('x'))).toBeNull();
    expect(parsePlanError({ code: '23505', details: '{}' })).toBeNull();
    expect(fromPostgrestError({ code: 'PGRST116' })).toBeNull();
    expect(planErrorResponse(undefined)).toBeNull();
  });

  it('survives a malformed DETAIL', () => {
    expect(parsePlanError({ code: 'WA002', details: 'not json' })).toEqual({
      code: 'plan_feature_unavailable',
      resource: 'unknown',
    });
  });
});

describe('dashboard body (REQ-X6)', () => {
  it('a count limit has code, resource, usage and limit', async () => {
    const res = planErrorResponse(LIMIT)!;
    expect(res.status).toBe(402);
    const body = await res.json();
    expect(body).toMatchObject({ code: 'plan_limit_reached', resource: 'contacts', usage: 5000, limit: 5000 });
    expect(body.error).toContain('5000');
  });

  it('a period limit says what remains and when it resets (R3)', async () => {
    const body = await planErrorResponse(PERIOD)!.json();
    expect(body).toMatchObject({ code: 'plan_limit_reached', resource: 'broadcast_recipients', usage: 9990, limit: 10000 });
    expect(body.error).toContain('20');
    expect(body.error).toContain('10');
    expect(body.error).toContain('2026-12-01');
  });

  it('a flag has no limit', async () => {
    const res = planErrorResponse(FLAG)!;
    expect(res.status).toBe(402);
    const body = await res.json();
    expect(body.code).toBe('plan_feature_unavailable');
    expect(body.limit).toBeUndefined();
  });

  it('toErrorResponse maps a thrown PlanLimitError', async () => {
    const res = toErrorResponse(fromPostgrestError(LIMIT));
    expect(res.status).toBe(402);
    expect((await res.json()).code).toBe('plan_limit_reached');
  });

  it('a seat-blocked downgrade is a 409 stating how many to free (AC-R1-4)', async () => {
    const res = planErrorResponse(
      pg('WA003', { code: 'downgrade_blocked', resource: 'seats', usage: 30, limit: 25, to_free: 5 })
    )!;
    expect(res.status).toBe(409);
    expect((await res.json()).error).toContain('5');
  });

  it('every resource the triggers raise has a label in the catalogue', async () => {
    for (const resource of [
      'seats', 'contacts', 'broadcast_recipients', 'automations_active', 'automations_total',
      'flows_active', 'flows_total', 'api_keys', 'public_api', 'webhook_endpoints',
      'ai_auto_reply', 'ai_drafts', 'kb_documents', 'pipelines', 'messages',
    ]) {
      const body = new PlanLimitError({ code: 'plan_limit_reached', resource, usage: 1, limit: 1 }).dashboardBody();
      expect(body.error).not.toContain('plan.resources');
      expect(body.error).not.toContain(resource.includes('_') ? resource : '\u0000');
    }
  });
});

describe('public API envelope (REQ-X7)', () => {
  it('nests the same fields, and the message names the resource and limit', async () => {
    const res = toApiErrorResponse(fromPostgrestError(LIMIT));
    expect(res.status).toBe(402);
    const { error } = await res.json();
    expect(error).toMatchObject({ code: 'plan_limit_reached', resource: 'contacts', usage: 5000, limit: 5000 });
    // This is what the MCP server shows the model (tools/shared.ts).
    expect(error.message).toContain('contacts');
    expect(error.message).toContain('5000');
  });

  it('states are reported with a reason', async () => {
    const res = toApiErrorResponse(
      new PlanLimitError({ code: 'plan_feature_unavailable', resource: 'public_api', reason: 'account_locked' })
    );
    const { error } = await res.json();
    expect(error.reason).toBe('account_locked');
    expect(error.message).toContain('locked');
  });
});
