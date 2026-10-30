// Metering in the dashboard's batch send (R3): reserve before the Meta
// call, refund what failed, and leave what doesn't fit for Resume.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const h = vi.hoisted(() => ({
  rpc: vi.fn(),
  send: vi.fn(),
}));

vi.mock('@/lib/auth/account', () => ({
  requireRole: async () => ({
    accountId: 'acc-1',
    userId: 'u-1',
    supabase: {
      from: () => {
        const chain: Record<string, unknown> = {};
        chain.select = () => chain;
        chain.eq = () => chain;
        chain.single = async () => ({
          data: { phone_number_id: 'pn', access_token: 'enc' },
          error: null,
        });
        return chain;
      },
    },
  }),
  toErrorResponse: () => new Response('err', { status: 500 }),
}));
vi.mock('@/lib/flows/admin-client', () => ({ supabaseAdmin: () => ({ rpc: h.rpc }) }));
vi.mock('@/lib/whatsapp/encryption', () => ({ decrypt: () => 'tok' }));
vi.mock('@/lib/whatsapp/template-body', () => ({
  resolveTemplateRow: async () => ({ row: null, language: 'en_US', malformed: false }),
}));
vi.mock('@/lib/whatsapp/meta-api', () => ({ sendTemplateMessage: h.send }));

import { __resetRateLimitForTests } from '@/lib/rate-limit';
import { POST } from './route';

const PHONES = ['+14155550101', '+14155550102', '+14155550103', '+14155550104'];

const post = (phones: string[] = PHONES) =>
  POST(
    new Request('https://app.test/api/whatsapp/broadcast', {
      method: 'POST',
      body: JSON.stringify({
        recipients: phones.map((phone) => ({ phone })),
        template_name: 't',
        template_language: 'en_US',
      }),
    })
  );

const granted = (n: number, reason: string | null = null) => ({
  data: [{ granted: n, period_start: '2026-11-01T00:00:00Z', used: n, limit_value: 100, reason }],
  error: null,
});
const rpcCalls = (fn: string) => h.rpc.mock.calls.filter(([name]) => name === fn);

beforeEach(() => {
  __resetRateLimitForTests();
  vi.clearAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
  vi.spyOn(console, 'log').mockImplementation(() => {});
  h.send.mockImplementation(async ({ to }: { to: string }) => ({ messageId: `wamid.${to}` }));
  h.rpc.mockReset();
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe('switch off', () => {
  it('sends everything, meters nothing, and keeps the response shape', async () => {
    const res = await post();
    expect(h.rpc).not.toHaveBeenCalled();
    expect(h.send).toHaveBeenCalledTimes(4);
    const body = await res.json();
    expect(body).toMatchObject({ success: true, total: 4, sent: 4, failed: 0 });
    expect(body).not.toHaveProperty('skipped');
  });
});

describe('switch on', () => {
  beforeEach(() => vi.stubEnv('ENTITLEMENTS_ENABLED', 'true'));

  it('reserves before sending and keeps what Meta accepted', async () => {
    h.rpc.mockResolvedValueOnce(granted(4));
    const body = await (await post()).json();
    expect(rpcCalls('entitlement_consume')[0][1]).toMatchObject({ p_account: 'acc-1', p_requested: 4 });
    expect(body).toMatchObject({ sent: 4, failed: 0, skipped: 0 });
    expect(rpcCalls('entitlement_release')).toHaveLength(0);
  });

  it('refunds recipients Meta rejected (AC-R3-2)', async () => {
    h.rpc.mockResolvedValueOnce(granted(4)).mockResolvedValue({ data: 1, error: null });
    h.send.mockImplementationOnce(async () => {
      throw new Error('rejected');
    });
    const body = await (await post()).json();
    expect(body).toMatchObject({ sent: 3, failed: 1, skipped: 0 });
    expect(rpcCalls('entitlement_release')[0][1]).toMatchObject({ p_count: 1 });
  });

  it('does not reserve for an invalid phone', async () => {
    h.rpc.mockResolvedValueOnce(granted(1));
    const body = await (await post(['not-a-phone', PHONES[0]])).json();
    expect(rpcCalls('entitlement_consume')[0][1]).toMatchObject({ p_requested: 1 });
    expect(body).toMatchObject({ sent: 1, failed: 1, skipped: 0 });
  });

  it('sends what fits and skips the rest, unsent (AC-R3-3)', async () => {
    h.rpc.mockResolvedValueOnce(granted(2, 'limit')).mockResolvedValueOnce(granted(0, 'limit'));
    const body = await (await post()).json();
    expect(h.send).toHaveBeenCalledTimes(2);
    expect(body).toMatchObject({ sent: 2, failed: 0, skipped: 2 });
    const skipped = body.results.filter((r: { status: string }) => r.status === 'skipped');
    expect(skipped).toHaveLength(2);
    expect(skipped[0].code).toBe('plan_limit_reached');
  });

  it('a paused plan state sends nothing, with its own code', async () => {
    h.rpc.mockResolvedValueOnce(granted(0, 'account_restricted'));
    const body = await (await post()).json();
    expect(h.send).not.toHaveBeenCalled();
    expect(body.results[0].code).toBe('plan_feature_unavailable');
  });

  it('fails closed with a 503 when the allowance cannot be read (N-11)', async () => {
    h.rpc.mockResolvedValue({ data: null, error: { message: 'boom' } });
    const res = await post();
    expect(res.status).toBe(503);
    expect(h.send).not.toHaveBeenCalled();
  });
});
