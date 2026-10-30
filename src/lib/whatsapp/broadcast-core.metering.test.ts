// deliverBroadcast with entitlements on (v1 and resume). Unmetered when
// the plan carries no account, which is what entitlements off produces.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';

const h = vi.hoisted(() => ({ rpc: vi.fn(), send: vi.fn() }));

vi.mock('@/lib/flows/admin-client', () => ({ supabaseAdmin: () => ({ rpc: h.rpc }) }));
vi.mock('@/lib/whatsapp/meta-api', () => ({ sendTemplateMessage: h.send }));
vi.mock('@/lib/whatsapp/encryption', () => ({ decrypt: () => 'tok' }));
vi.mock('@/lib/api/v1/contacts', () => ({ findOrCreateContact: vi.fn(async () => ({ id: 'c1' })) }));

import {
  createBroadcast,
  deliverBroadcast,
  withBroadcastMetering,
  type BroadcastPlan,
} from './broadcast-core';
import { PlanLimitError } from '@/lib/entitlements/errors';

const plan = (n: number): BroadcastPlan => ({
  broadcastId: 'b-1',
  templateName: 't',
  templateLanguage: 'en_US',
  phoneNumberId: 'pn',
  accessToken: 'tok',
  templateRow: null,
  rejected: 0,
  planned: Array.from({ length: n }, (_, i) => ({
    recipientRowId: `r-${i}`,
    phone: `1415555${String(i).padStart(4, '0')}`,
    params: [],
  })),
});

/** Records updates per table; `pending` feeds finalizeBroadcastStatus. */
function fakeDb(pending: () => number) {
  const updates: { table: string; patch: Record<string, unknown>; id?: unknown }[] = [];
  const db = {
    from(table: string) {
      const chain: Record<string, unknown> = {};
      let patch: Record<string, unknown> | null = null;
      let status: unknown;
      chain.update = (p: Record<string, unknown>) => {
        patch = p;
        return chain;
      };
      chain.select = () => chain;
      chain.eq = (col: string, value: unknown) => {
        if (col === 'status') status = value;
        if (patch && col === 'id') updates.push({ table, patch, id: value });
        return chain;
      };
      chain.then = (resolve: (v: unknown) => void) =>
        resolve({ count: status === 'pending' ? pending() : 0, data: [], error: null });
      return chain;
    },
  } as unknown as SupabaseClient;
  return { db, updates };
}

const granted = (n: number, reason: string | null = null) => ({
  data: [{ granted: n, period_start: '2026-11-01T00:00:00Z', used: n, limit_value: 100, reason }],
  error: null,
});
const rpcCalls = (fn: string) => h.rpc.mock.calls.filter(([name]) => name === fn);

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
  vi.spyOn(console, 'log').mockImplementation(() => {});
  h.rpc.mockReset();
  h.send.mockImplementation(async () => ({ messageId: 'wamid.x' }));
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe('withBroadcastMetering', () => {
  it('returns the same plan with the switch off', () => {
    const p = plan(1);
    expect(withBroadcastMetering(p, 'acc-1')).toBe(p);
  });

  it('marks it with the switch on', () => {
    vi.stubEnv('ENTITLEMENTS_ENABLED', 'true');
    expect(withBroadcastMetering(plan(1), 'acc-1').meterAccountId).toBe('acc-1');
  });
});

describe('deliverBroadcast', () => {
  it('unmetered: no RPC, everyone is sent', async () => {
    const { db } = fakeDb(() => 0);
    await deliverBroadcast(db, plan(12));
    expect(h.rpc).not.toHaveBeenCalled();
    expect(h.send).toHaveBeenCalledTimes(12);
  });

  describe('metered', () => {
    beforeEach(() => vi.stubEnv('ENTITLEMENTS_ENABLED', 'true'));
    const metered = (n: number) => withBroadcastMetering(plan(n), 'acc-1');

    it('reserves in chunks of 10, bounding overshoot to one batch (REQ-X5)', async () => {
      h.rpc.mockResolvedValueOnce(granted(10)).mockResolvedValueOnce(granted(2));
      const { db, updates } = fakeDb(() => 0);
      await deliverBroadcast(db, metered(12));
      expect(rpcCalls('entitlement_consume').map(([, a]) => a.p_requested)).toEqual([10, 2]);
      expect(h.send).toHaveBeenCalledTimes(12);
      expect(updates.some((u) => 'paused_reason' in u.patch)).toBe(false);
    });

    it('refunds a failed recipient (AC-R3-2)', async () => {
      h.rpc.mockResolvedValueOnce(granted(2)).mockResolvedValue({ data: 1, error: null });
      h.send.mockImplementationOnce(async () => {
        throw new Error('rejected');
      });
      const { db } = fakeDb(() => 0);
      await deliverBroadcast(db, metered(2));
      expect(rpcCalls('entitlement_release')[0][1]).toMatchObject({ p_count: 1 });
    });

    it('out of allowance: leaves the rest pending and flags the pause (AC-R3-3)', async () => {
      h.rpc.mockResolvedValueOnce(granted(3, 'limit')).mockResolvedValueOnce(granted(0, 'limit'));
      const { db, updates } = fakeDb(() => 2);
      await deliverBroadcast(db, metered(5));
      expect(h.send).toHaveBeenCalledTimes(3);
      expect(updates.filter((u) => u.table === 'broadcast_recipients')).toHaveLength(3);
      expect(updates).toContainEqual({ table: 'broadcasts', patch: { paused_reason: 'plan_limit' }, id: 'b-1' });
      // Pending remain, so the terminal status is not written.
      expect(updates.some((u) => u.table === 'broadcasts' && 'status' in u.patch)).toBe(false);
    });

    it('the plan state changing mid-send pauses at the next batch', async () => {
      h.rpc.mockResolvedValueOnce(granted(10)).mockResolvedValueOnce(granted(0, 'account_locked'));
      const { db, updates } = fakeDb(() => 2);
      await deliverBroadcast(db, metered(12));
      expect(h.send).toHaveBeenCalledTimes(10);
      expect(updates.some((u) => 'paused_reason' in u.patch)).toBe(true);
    });

    it('fails closed: nothing is sent or marked failed when the allowance is unreadable', async () => {
      h.rpc.mockResolvedValue({ data: null, error: { message: 'boom' } });
      const { db, updates } = fakeDb(() => 3);
      await deliverBroadcast(db, metered(3));
      expect(h.send).not.toHaveBeenCalled();
      expect(updates.filter((u) => u.table === 'broadcast_recipients')).toHaveLength(0);
    });
  });
});

describe('createBroadcast pre-flight', () => {
  it('surfaces the trigger as a plan error, not an internal one (AC-R3-4)', async () => {
    const chain: Record<string, unknown> = {};
    chain.select = () => chain;
    chain.eq = () => chain;
    chain.single = async () => ({ data: { phone_number_id: 'pn', access_token: 'enc' }, error: null });
    chain.maybeSingle = async () => ({ data: null, error: null });
    chain.order = () => chain;
    chain.limit = () => chain;
    chain.then = (resolve: (v: unknown) => void) => resolve({ data: [], error: null });
    const db = {
      from: () => chain,
      rpc: async () => ({
        data: null,
        error: {
          code: 'WA001',
          message: 'plan_limit_reached',
          details: JSON.stringify({
            code: 'plan_limit_reached',
            resource: 'broadcast_recipients',
            usage: 9990,
            limit: 10000,
            requested: 20,
            remaining: 10,
          }),
        },
      }),
    } as unknown as SupabaseClient;

    const err = await createBroadcast(db, 'acc-1', 'u-1', {
      templateName: 't',
      recipients: [{ to: '+14155550101' }],
    }).then(() => null, (e: unknown) => e);

    expect(err).toBeInstanceOf(PlanLimitError);
    expect((err as PlanLimitError).detail.resource).toBe('broadcast_recipients');
  });
});
