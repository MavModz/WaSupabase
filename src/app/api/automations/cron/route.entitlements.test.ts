// The cron with entitlements on: the lifecycle sweep runs, and a paused
// account's due waits don't resume (R4).
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { entitlements } from '@/lib/entitlements/ent.test-helper';

const h = vi.hoisted(() => ({
  rpc: vi.fn(),
  due: [] as Record<string, unknown>[],
  updates: [] as { patch: Record<string, unknown>; filters: Record<string, unknown> }[],
  getEntitlements: vi.fn(),
  claim: vi.fn(),
  resume: vi.fn(),
}));

vi.mock('@/lib/automations/admin-client', () => ({
  supabaseAdmin: () => ({
    rpc: (fn: string) => h.rpc(fn),
    from: () => {
      const builder: Record<string, unknown> = {};
      for (const m of ['select', 'lte', 'order']) builder[m] = () => builder;
      let pending: { patch: Record<string, unknown>; filters: Record<string, unknown> } | null = null;
      builder.update = (patch: Record<string, unknown>) => {
        pending = { patch, filters: {} };
        h.updates.push(pending);
        return builder;
      };
      builder.eq = (col: string, value: unknown) => {
        if (pending) pending.filters[col] = value;
        return builder;
      };
      builder.limit = async () => ({ data: h.due, error: null });
      builder.then = (resolve: (v: unknown) => void) => resolve({ data: null, error: null });
      return builder;
    },
  }),
}));
vi.mock('@/lib/automations/engine', () => ({
  expireAwaitingReplies: async () => 0,
  requeueStalledExecutions: async () => 0,
  claimPendingExecution: h.claim,
  resumePendingExecution: h.resume,
}));
vi.mock('@/lib/entitlements/resolve', () => ({ getEntitlements: h.getEntitlements }));

import { GET } from './route';

const call = () =>
  GET(new Request('https://app.test/api/automations/cron', { headers: { 'x-cron-secret': 'cron-secret' } }));

const row = (id: string, account: string) => ({
  id,
  automation_id: 'auto-1',
  account_id: account,
  user_id: 'u-1',
  next_step_position: 1,
});

beforeEach(() => {
  vi.stubEnv('AUTOMATION_CRON_SECRET', 'cron-secret');
  vi.stubEnv('RATE_LIMIT_BACKEND', '');
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
  vi.clearAllMocks();
  h.due = [];
  h.updates.length = 0;
  h.rpc.mockResolvedValue({ data: { changes_applied: 0 }, error: null });
  h.claim.mockResolvedValue(true);
  h.resume.mockResolvedValue(undefined);
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe('switch off', () => {
  it('no sweep, no lookups, and waits resume as before', async () => {
    h.due = [row('e-1', 'acc-1')];
    expect(await (await call()).json()).toEqual({ processed: 1, expired: 0, requeued: 0 });
    expect(h.rpc).not.toHaveBeenCalled();
    expect(h.getEntitlements).not.toHaveBeenCalled();
    expect(h.updates).toHaveLength(0);
  });
});

describe('switch on', () => {
  beforeEach(() => vi.stubEnv('ENTITLEMENTS_ENABLED', 'true'));

  it('runs the lifecycle sweep', async () => {
    await call();
    expect(h.rpc).toHaveBeenCalledWith('entitlements_run_due');
  });

  it('a failed sweep does not fail the cron', async () => {
    h.rpc.mockResolvedValue({ data: null, error: { message: 'boom' } });
    h.due = [row('e-1', 'acc-1')];
    h.getEntitlements.mockResolvedValue(entitlements('active'));
    const res = await call();
    expect(res.status).toBe(200);
    expect(h.resume).toHaveBeenCalledTimes(1);
  });

  it('a paused account\'s wait is pushed back, not claimed; others resume (AC-R4-3)', async () => {
    h.due = [row('e-1', 'paused'), row('e-2', 'ok'), row('e-3', 'paused')];
    h.getEntitlements.mockImplementation(async (id: string) =>
      entitlements(id === 'paused' ? 'restricted' : 'active')
    );
    const body = await (await call()).json();

    expect(body.processed).toBe(1);
    expect(h.claim).toHaveBeenCalledTimes(1);
    expect(h.claim).toHaveBeenCalledWith('e-2');
    expect(h.updates.map((u) => u.filters.id)).toEqual(['e-1', 'e-3']);
    expect(h.updates[0].filters).toMatchObject({ account_id: 'paused', status: 'pending' });
    expect(new Date(h.updates[0].patch.run_at as string).getTime()).toBeGreaterThan(Date.now());
    // One lookup per account per run.
    expect(h.getEntitlements).toHaveBeenCalledTimes(2);
  });
});
