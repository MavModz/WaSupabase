import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const h = vi.hoisted(() => ({ rpc: vi.fn() }));

vi.mock('@/lib/flows/admin-client', () => ({
  supabaseAdmin: () => ({ rpc: h.rpc }),
}));

import { __resetRateLimitForTests } from '@/lib/rate-limit';
import { POST } from './route';

const ACCOUNT = '11111111-1111-4111-8111-111111111111';

function call(body: unknown, secret: string | null = 'op-secret') {
  return POST(
    new Request('https://app.test/api/internal/entitlements', {
      method: 'POST',
      headers: secret === null ? {} : { 'x-operator-secret': secret },
      body: typeof body === 'string' ? body : JSON.stringify(body),
    })
  );
}

beforeEach(() => {
  __resetRateLimitForTests();
  vi.stubEnv('ENTITLEMENTS_OPERATOR_SECRET', 'op-secret');
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
  h.rpc.mockReset();
  h.rpc.mockResolvedValue({ data: { ok: true }, error: null });
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe('POST /api/internal/entitlements', () => {
  it('is 503 until a secret is configured', async () => {
    vi.stubEnv('ENTITLEMENTS_OPERATOR_SECRET', '');
    expect((await call({ op: 'status' })).status).toBe(503);
    expect(h.rpc).not.toHaveBeenCalled();
  });

  it('refuses a wrong or missing secret, such as a customer owner (REQ-O1)', async () => {
    expect((await call({ op: 'status' }, 'nope')).status).toBe(401);
    expect((await call({ op: 'status' }, null)).status).toBe(401);
    expect(h.rpc).not.toHaveBeenCalled();
  });

  it('rate-limits secret guessing', async () => {
    let last = 0;
    for (let i = 0; i < 40; i++) last = (await call({ op: 'status' }, 'nope')).status;
    expect(last).toBe(429);
  });

  it.each([
    [{ op: 'set_plan', plan: 'growth' }, 'ent_set_plan', { p_plan: 'growth', p_keep: null }],
    [{ op: 'set_state', state: 'restricted' }, 'ent_set_state', { p_state: 'restricted' }],
    [{ op: 'set_trial_end', trial_ends_at: '2026-12-01T00:00:00Z' }, 'ent_set_trial_end', { p_trial_ends_at: '2026-12-01T00:00:00.000Z' }],
    [{ op: 'schedule_change', plan: 'starter', keep: { automations: [] } }, 'ent_schedule_change', { p_plan: 'starter', p_at: null, p_keep: { automations: [] } }],
    [{ op: 'cancel_change' }, 'ent_cancel_change', {}],
    [{ op: 'set_override', overrides: { seats_max: 120 } }, 'ent_set_override', { p_overrides: { seats_max: 120 } }],
  ])('%o calls its RPC with the actor', async (body, fn, args) => {
    const res = await call({ ...body, account_id: ACCOUNT, actor: 'ops@test', reason: 'why' });
    expect(res.status).toBe(200);
    expect(h.rpc).toHaveBeenCalledWith(fn, expect.objectContaining({ p_account: ACCOUNT, p_actor: 'ops@test', p_reason: 'why', ...args }));
  });

  it('read-only ops need an actor too, and pass the account', async () => {
    await call({ op: 'preview', plan: 'starter', account_id: ACCOUNT, actor: 'ops' });
    expect(h.rpc).toHaveBeenCalledWith('ent_downgrade_preview', { p_account: ACCOUNT, p_plan: 'starter' });
    await call({ op: 'status', account_id: ACCOUNT, actor: 'ops' });
    expect(h.rpc).toHaveBeenCalledWith('account_entitlements', { p_account: ACCOUNT });
    await call({ op: 'usage', account_id: ACCOUNT, actor: 'ops' });
    expect(h.rpc).toHaveBeenCalledWith('account_usage', { p_account: ACCOUNT });
  });

  it('set_enabled reports whether the env half agrees (N-2)', async () => {
    const res = await call({ op: 'set_enabled', enabled: true, actor: 'ops' });
    expect(h.rpc).toHaveBeenCalledWith('entitlements_set_enabled', { p_enabled: true, p_actor: 'ops', p_reason: null });
    expect(await res.json()).toMatchObject({ env_enabled: false });
    vi.stubEnv('ENTITLEMENTS_ENABLED', 'true');
    const res2 = await call({ op: 'set_enabled', enabled: true, actor: 'ops' });
    expect(await res2.json()).toMatchObject({ env_enabled: true });
  });

  it.each([
    ['not json', 'nope'],
    ['an array', '[]'],
    ['an unknown op', { op: 'drop_everything', actor: 'ops' }],
    ['a missing actor', { op: 'cancel_change', account_id: ACCOUNT }],
    ['a bad account id', { op: 'cancel_change', account_id: 'x', actor: 'ops' }],
    ['a bad date', { op: 'set_trial_end', account_id: ACCOUNT, actor: 'ops', trial_ends_at: 'soon' }],
    ['a non-boolean switch', { op: 'set_enabled', enabled: 'yes', actor: 'ops' }],
    ['overrides that are not an object', { op: 'set_override', account_id: ACCOUNT, actor: 'ops', overrides: [1] }],
  ])('400s on %s', async (_name, body) => {
    expect((await call(body)).status).toBe(400);
    expect(h.rpc).not.toHaveBeenCalled();
  });

  it('a seat-blocked downgrade is a 409 stating how many to free (AC-R1-4)', async () => {
    h.rpc.mockResolvedValue({
      data: null,
      error: {
        code: 'WA003',
        message: 'downgrade_blocked',
        details: JSON.stringify({ code: 'downgrade_blocked', resource: 'seats', usage: 30, limit: 25, to_free: 5 }),
      },
    });
    const res = await call({ op: 'schedule_change', plan: 'growth', account_id: ACCOUNT, actor: 'ops' });
    expect(res.status).toBe(409);
    expect((await res.json()).error).toMatchObject({ code: 'downgrade_blocked', to_free: 5 });
  });

  it('maps validation and missing-account errors, and hides the rest', async () => {
    h.rpc.mockResolvedValue({ data: null, error: { code: '22023', message: 'unknown plan x' } });
    expect((await call({ op: 'set_plan', plan: 'x', account_id: ACCOUNT, actor: 'ops' })).status).toBe(400);

    h.rpc.mockResolvedValue({ data: null, error: { code: 'P0002', message: 'account not found' } });
    expect((await call({ op: 'cancel_change', account_id: ACCOUNT, actor: 'ops' })).status).toBe(404);

    h.rpc.mockResolvedValue({ data: null, error: { code: 'XX000', message: 'secret internals' } });
    const res = await call({ op: 'cancel_change', account_id: ACCOUNT, actor: 'ops' });
    expect(res.status).toBe(500);
    expect(JSON.stringify(await res.json())).not.toContain('secret internals');
  });
});
