// Trigger errors surface as 402s, not 500s, on the routes that write
// limited resources (REQ-X6). The triggers themselves are proved in
// supabase/tests/41_entitlements_enforcement.test.sql.
import { beforeEach, describe, expect, it, vi } from 'vitest';

const WA001 = {
  code: 'WA001',
  message: 'plan_limit_reached',
  details: JSON.stringify({ code: 'plan_limit_reached', resource: 'seats', usage: 5, limit: 5 }),
};
const WA002 = {
  code: 'WA002',
  message: 'plan_feature_unavailable',
  details: JSON.stringify({ code: 'plan_feature_unavailable', resource: 'api_keys', reason: 'not_on_plan' }),
};

const h = vi.hoisted(() => ({
  writeError: null as unknown,
  rpcError: null as unknown,
  getEntitlements: vi.fn(),
}));

function client() {
  const from = () => {
    // Reads find the row; a write gets the error under test.
    let writing = false;
    const chain: Record<string, unknown> = {};
    for (const m of ['select', 'eq', 'is', 'gt', 'order', 'limit']) chain[m] = () => chain;
    chain.insert = chain.update = () => {
      writing = true;
      return chain;
    };
    const result = async () =>
      writing
        ? { data: null, error: h.writeError }
        : { data: { id: 'row-1', account_id: 'acc-1' }, error: null };
    chain.single = result;
    chain.maybeSingle = result;
    chain.then = (resolve: (v: unknown) => void) => void result().then(resolve);
    return chain;
  };
  return {
    from,
    rpc: async () => ({ data: null, error: h.rpcError }),
    auth: { getUser: async () => ({ data: { user: { id: 'u-1' } } }) },
  };
}

vi.mock('@/lib/auth/account', async (original) => ({
  ...(await original<typeof import('@/lib/auth/account')>()),
  requireRole: async () => ({ supabase: client(), userId: 'u-1', accountId: 'acc-1', role: 'owner' }),
  getCurrentAccount: async () => ({ supabase: client(), userId: 'u-1', accountId: 'acc-1', role: 'owner' }),
}));
vi.mock('@/lib/supabase/server', () => ({ createClient: async () => client() }));
vi.mock('@/lib/flows/admin-client', () => ({ supabaseAdmin: () => client() }));
vi.mock('@/lib/automations/admin-client', () => ({ supabaseAdmin: () => client() }));
vi.mock('@/lib/entitlements/resolve', () => ({ getEntitlements: h.getEntitlements }));
vi.mock('@/lib/flows/validate', () => ({ validateFlowForActivation: () => [] }));

import { entitlements } from '@/lib/entitlements/ent.test-helper';
import { __resetRateLimitForTests } from '@/lib/rate-limit';
import { POST as createInvite } from './account/invitations/route';
import { POST as createKey } from './account/api-keys/route';
import { POST as redeem } from './invitations/[token]/redeem/route';
import { POST as createAutomation } from './automations/route';
import { POST as activateFlow } from './flows/[id]/activate/route';
import { POST as createFlow } from './flows/route';
import { POST as createDoc } from './ai/knowledge/route';
import { POST as draft } from './ai/draft/route';
import { POST as react } from './whatsapp/react/route';
import { POST as send } from './whatsapp/send/route';
import { POST as resume } from './whatsapp/broadcast/[id]/resume/route';

const req = (body: unknown = {}) =>
  new Request('https://app.test/x', { method: 'POST', body: JSON.stringify(body) });
const idParams = { params: Promise.resolve({ id: 'row-1' }) };

beforeEach(() => {
  __resetRateLimitForTests();
  h.writeError = null;
  h.rpcError = null;
  h.getEntitlements.mockReset();
  h.getEntitlements.mockResolvedValue(null);
  vi.spyOn(console, 'error').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
  vi.spyOn(console, 'log').mockImplementation(() => {});
});

describe('count limits from the DB trigger', () => {
  it.each([
    ['POST /api/account/invitations (AC-R1-1)', () => createInvite(req({ role: 'agent' })), WA001],
    ['POST /api/account/api-keys (AC-R7-1)', () => createKey(req({ name: 'k', scopes: [] })), WA002],
    ['POST /api/automations (AC-R4-4)', () => createAutomation(req({ name: 'a', trigger_type: 'keyword' })), WA001],
    ['POST /api/flows', () => createFlow(req({ name: 'f' })), WA001],
    ['POST /api/flows from a template', () => createFlow(req({ template_slug: 'welcome_menu' })), WA001],
    ['POST /api/flows/[id]/activate (AC-R5-1)', () => activateFlow(req({ status: 'active' }), idParams), WA001],
    ['POST /api/ai/knowledge (AC-R9-3)', () => createDoc(req({ title: 't', content: 'c' })), WA001],
  ])('%s is a 402', async (_name, call, error) => {
    h.writeError = error;
    const res = await call();
    expect(res.status).toBe(402);
    expect((await res.json()).code).toBe(JSON.parse(error.details).code);
  });

  it('an unrelated DB error stays a 500', async () => {
    h.writeError = { code: 'XX000', message: 'boom' };
    expect((await createInvite(req({ role: 'agent' }))).status).toBe(500);
  });
});

describe('redeem at the seat maximum (AC-R1-3)', () => {
  it('says the workspace is full', async () => {
    h.rpcError = WA001;
    const res = await redeem(req(), { params: Promise.resolve({ token: 'tok' }) });
    expect(res.status).toBe(402);
    const body = await res.json();
    expect(body.code).toBe('plan_limit_reached');
    expect(body.error).toContain('full');
  });
});

describe('state gates', () => {
  it('a locked account cannot send, react or draft (AC-T4)', async () => {
    h.getEntitlements.mockResolvedValue(entitlements('locked'));
    for (const res of [await send(req()), await react(req()), await draft(req())]) {
      expect(res.status).toBe(402);
      expect((await res.json()).reason).toBe('account_locked');
    }
  });

  it('a restricted account cannot resume a broadcast', async () => {
    h.getEntitlements.mockResolvedValue(entitlements('restricted'));
    const res = await resume(req(), idParams);
    expect(res.status).toBe(402);
    expect((await res.json()).reason).toBe('account_restricted');
  });

  it('a restricted account can still reply: the gate lets it through to validation', async () => {
    h.getEntitlements.mockResolvedValue(entitlements('restricted'));
    expect((await send(req())).status).toBe(400);
  });
});
