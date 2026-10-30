// requireApiKey with entitlements on (R7). The switch-off path is what
// api-context.test.ts already covers, unchanged.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { generateApiKey } from '@/lib/api-keys/keys';
import { entitlements } from '@/lib/entitlements/ent.test-helper';
import { PlanLimitError } from '@/lib/entitlements/errors';
import { __resetRateLimitForTests } from '@/lib/rate-limit';
import type { PlanLimits, PlanState } from '@/lib/entitlements/types';

const h = vi.hoisted(() => ({
  findActiveKeyByHash: vi.fn(),
  touchLastUsed: vi.fn(),
  getEntitlements: vi.fn(),
  isApiKeySuspended: vi.fn(),
}));

vi.mock('@/lib/flows/admin-client', () => ({ supabaseAdmin: () => ({}) }));
vi.mock('@/lib/api-keys/store', () => ({
  findActiveKeyByHash: h.findActiveKeyByHash,
  touchLastUsed: h.touchLastUsed,
}));
vi.mock('@/lib/entitlements/resolve', () => ({
  getEntitlements: h.getEntitlements,
  isApiKeySuspended: h.isApiKeySuspended,
}));

const { requireApiKey } = await import('./api-context');

const KEY = generateApiKey().plaintext;
const request = () =>
  new Request('https://crm.test/api/v1/contacts', { headers: { authorization: `Bearer ${KEY}` } });

const useEnt = (state: PlanState, limits: Partial<PlanLimits> = {}) =>
  h.getEntitlements.mockResolvedValue(entitlements(state, limits));

beforeEach(() => {
  __resetRateLimitForTests();
  vi.clearAllMocks();
  h.findActiveKeyByHash.mockResolvedValue({
    id: 'key-1',
    account_id: 'acc-1',
    created_by: 'u-1',
    name: 'k',
    scopes: ['contacts:read', 'messages:send'],
    expires_at: null,
    revoked_at: null,
  });
  h.isApiKeySuspended.mockResolvedValue(false);
});

afterEach(() => __resetRateLimitForTests());

const planCode = async (p: Promise<unknown>) => {
  const err = await p.then(() => null, (e: unknown) => e);
  expect(err).toBeInstanceOf(PlanLimitError);
  return (err as PlanLimitError).code;
};

describe('requireApiKey with entitlements on', () => {
  it('lets an active Growth key through', async () => {
    useEnt('active');
    const ctx = await requireApiKey(request(), 'contacts:read');
    expect(ctx.accountId).toBe('acc-1');
    expect(h.touchLastUsed).toHaveBeenCalledWith('key-1');
  });

  it('refuses every call on a plan with no API, and does not count it as use (AC-R7-2)', async () => {
    useEnt('active', { api_keys_max: 0, api_rate_per_minute: 0 });
    expect(await planCode(requireApiKey(request(), 'contacts:read'))).toBe('plan_feature_unavailable');
    expect(h.touchLastUsed).not.toHaveBeenCalled();
  });

  it('refuses a key suspended by a downgrade', async () => {
    useEnt('active');
    h.isApiKeySuspended.mockResolvedValue(true);
    expect(await planCode(requireApiKey(request(), 'contacts:read'))).toBe('plan_feature_unavailable');
    expect(h.touchLastUsed).not.toHaveBeenCalled();
  });

  it('restricted: reads work, sends do not (AC-R7-3)', async () => {
    useEnt('restricted');
    await expect(requireApiKey(request(), 'contacts:read')).resolves.toBeTruthy();
    expect(await planCode(requireApiKey(request(), 'messages:send'))).toBe('plan_feature_unavailable');
  });

  it('locked: only the scope-free /me works', async () => {
    useEnt('locked');
    expect(await planCode(requireApiKey(request(), 'contacts:read'))).toBe('plan_feature_unavailable');
    await expect(requireApiKey(request())).resolves.toBeTruthy();
  });

  it('the plan sets the per-key rate: the 61st call on a trial key is limited (AC-R7-4)', async () => {
    useEnt('trialing', { api_rate_per_minute: 60 });
    for (let i = 0; i < 60; i++) await requireApiKey(request(), 'contacts:read');
    const err = await requireApiKey(request(), 'contacts:read').then(() => null, (e) => e);
    expect(err).toMatchObject({ code: 'rate_limited', status: 429 });
  });

  it('a refused plan still has a rate limit, so it cannot be hammered', async () => {
    useEnt('active', { api_keys_max: 0, api_rate_per_minute: 0 });
    for (let i = 0; i < 120; i++) {
      await requireApiKey(request(), 'contacts:read').catch(() => {});
    }
    const err = await requireApiKey(request(), 'contacts:read').then(() => null, (e) => e);
    expect(err).toMatchObject({ code: 'rate_limited' });
  });

  it('a failed lookup keeps today\'s behaviour (N-11)', async () => {
    h.getEntitlements.mockResolvedValue(null);
    await expect(requireApiKey(request(), 'messages:send')).resolves.toBeTruthy();
    expect(h.isApiKeySuspended).not.toHaveBeenCalled();
  });
});
