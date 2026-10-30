import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const h = vi.hoisted(() => ({ rpc: vi.fn(), from: vi.fn() }));

vi.mock('@/lib/flows/admin-client', () => ({
  supabaseAdmin: () => ({ rpc: h.rpc, from: h.from }),
}));

import { createBroadcastMeter } from './metering';
import {
  canMirrorInboundMedia,
  getEntitlements,
  isApiKeySuspended,
} from './resolve';
import { entitlements } from './ent.test-helper';

const consumeResult = (granted: number, reason: string | null = null) => ({
  data: [{ granted, period_start: '2026-11-01T00:00:00Z', used: granted, limit_value: 100, reason }],
  error: null,
});
const released = () => h.rpc.mock.calls.filter(([fn]) => fn === 'entitlement_release');

beforeEach(() => {
  h.rpc.mockReset();
  h.from.mockReset();
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe('switch off: no I/O at all (REQ-H2)', () => {
  it('every entry point returns before touching the database', async () => {
    expect(createBroadcastMeter('acc-1', 10)).toBeNull();
    expect(await getEntitlements('acc-1')).toBeNull();
    expect(await isApiKeySuspended('key-1')).toBe(false);
    expect(await canMirrorInboundMedia('acc-1')).toBe(true);
    expect(h.rpc).not.toHaveBeenCalled();
    expect(h.from).not.toHaveBeenCalled();
  });

  it('only the exact value "true" turns it on', async () => {
    vi.stubEnv('ENTITLEMENTS_ENABLED', '1');
    expect(createBroadcastMeter('acc-1', 10)).toBeNull();
    vi.stubEnv('ENTITLEMENTS_ENABLED', 'TRUE');
    expect(createBroadcastMeter('acc-1', 10)).toBeNull();
  });
});

describe('getEntitlements', () => {
  beforeEach(() => vi.stubEnv('ENTITLEMENTS_ENABLED', 'true'));

  it('returns the resolved row', async () => {
    h.rpc.mockResolvedValue({ data: entitlements('past_due'), error: null });
    expect((await getEntitlements('acc-1'))?.state).toBe('past_due');
    expect(h.rpc).toHaveBeenCalledWith('account_entitlements', { p_account: 'acc-1' });
  });

  it('never caches: a state change is seen on the next call (REQ-S1)', async () => {
    h.rpc.mockResolvedValueOnce({ data: entitlements('active'), error: null });
    h.rpc.mockResolvedValueOnce({ data: entitlements('locked'), error: null });
    expect((await getEntitlements('acc-1'))?.state).toBe('active');
    expect((await getEntitlements('acc-1'))?.state).toBe('locked');
  });

  it('fails open on an RPC error, without throwing (N-11)', async () => {
    h.rpc.mockResolvedValue({ data: null, error: { message: 'boom' } });
    await expect(getEntitlements('acc-1')).resolves.toBeNull();
  });

  it('fails open when the RPC rejects', async () => {
    h.rpc.mockRejectedValue(new Error('network'));
    await expect(getEntitlements('acc-1')).resolves.toBeNull();
  });

  it('treats a DB switch that disagrees as off (N-2)', async () => {
    h.rpc.mockResolvedValue({ data: { ...entitlements(), enabled: false }, error: null });
    await expect(getEntitlements('acc-1')).resolves.toBeNull();
  });
});

describe('canMirrorInboundMedia (D-17)', () => {
  beforeEach(() => vi.stubEnv('ENTITLEMENTS_ENABLED', 'true'));

  it('follows the gate', async () => {
    h.rpc.mockResolvedValue({ data: false, error: null });
    expect(await canMirrorInboundMedia('acc-1')).toBe(false);
    h.rpc.mockResolvedValue({ data: true, error: null });
    expect(await canMirrorInboundMedia('acc-1')).toBe(true);
  });

  it('fails open, so an attachment is not lost to a lookup error', async () => {
    h.rpc.mockRejectedValue(new Error('network'));
    expect(await canMirrorInboundMedia('acc-1')).toBe(true);
  });
});

describe('createBroadcastMeter', () => {
  beforeEach(() => vi.stubEnv('ENTITLEMENTS_ENABLED', 'true'));

  it('reserves one chunk and refunds what Meta rejected (AC-R3-2)', async () => {
    h.rpc.mockResolvedValueOnce(consumeResult(10)).mockResolvedValue({ data: 0, error: null });
    const meter = createBroadcastMeter('acc-1', 10)!;
    for (let i = 0; i < 10; i++) expect(await meter.take(10 - i)).toBe(true);
    expect(h.rpc).toHaveBeenCalledTimes(1);
    meter.refund();
    meter.refund();
    await meter.settle();
    expect(released()).toHaveLength(1);
    expect(released()[0][1]).toMatchObject({ p_count: 2, p_period_start: '2026-11-01T00:00:00Z' });
  });

  it('never reserves more than remain', async () => {
    h.rpc.mockResolvedValue(consumeResult(3));
    const meter = createBroadcastMeter('acc-1', 10)!;
    await meter.take(3);
    expect(h.rpc.mock.calls[0][1]).toMatchObject({ p_requested: 3 });
  });

  it('returns an unused reservation on settle', async () => {
    h.rpc.mockResolvedValueOnce(consumeResult(10)).mockResolvedValue({ data: 0, error: null });
    const meter = createBroadcastMeter('acc-1', 10)!;
    await meter.take(10);
    await meter.settle();
    expect(released()[0][1]).toMatchObject({ p_count: 9 });
  });

  it('stops on a partial grant once it is used up (AC-R3-3)', async () => {
    h.rpc.mockResolvedValueOnce(consumeResult(2, 'limit')).mockResolvedValueOnce(consumeResult(0, 'limit'));
    const meter = createBroadcastMeter('acc-1', 10)!;
    expect(await meter.take(4)).toBe(true);
    expect(await meter.take(3)).toBe(true);
    expect(await meter.take(2)).toBe(false);
    expect(await meter.take(1)).toBe(false);
    expect(meter.stopped).toBe(true);
    expect(meter.code).toBe('plan_limit_reached');
    expect(h.rpc).toHaveBeenCalledTimes(2);
  });

  it('reports a paused plan state differently from a used-up allowance', async () => {
    h.rpc.mockResolvedValue(consumeResult(0, 'account_restricted'));
    const meter = createBroadcastMeter('acc-1', 10)!;
    expect(await meter.take(1)).toBe(false);
    expect(meter.code).toBe('plan_feature_unavailable');
  });

  it('fails closed when the allowance cannot be read (N-11)', async () => {
    h.rpc.mockResolvedValue({ data: null, error: { message: 'boom' } });
    const meter = createBroadcastMeter('acc-1', 10)!;
    expect(await meter.take(1)).toBe(false);
    expect(meter.failed).toBe(true);
    expect(meter.stopped).toBe(true);
  });

  it('a failed refund is logged and never throws', async () => {
    h.rpc.mockResolvedValueOnce(consumeResult(1)).mockResolvedValue({ data: null, error: { message: 'boom' } });
    const meter = createBroadcastMeter('acc-1', 10)!;
    await meter.take(1);
    meter.refund();
    await expect(meter.settle()).resolves.toBeUndefined();
  });
});

describe('isApiKeySuspended', () => {
  beforeEach(() => vi.stubEnv('ENTITLEMENTS_ENABLED', 'true'));

  const stubKey = (result: unknown) => {
    h.from.mockReturnValue({
      select: () => ({ eq: () => ({ maybeSingle: async () => result }) }),
    });
  };

  it('reads the column', async () => {
    stubKey({ data: { plan_suspended_at: '2026-11-01T00:00:00Z' }, error: null });
    expect(await isApiKeySuspended('key-1')).toBe(true);
    stubKey({ data: { plan_suspended_at: null }, error: null });
    expect(await isApiKeySuspended('key-1')).toBe(false);
  });

  it('fails open on an error', async () => {
    stubKey({ data: null, error: { message: 'boom' } });
    expect(await isApiKeySuspended('key-1')).toBe(false);
  });
});
