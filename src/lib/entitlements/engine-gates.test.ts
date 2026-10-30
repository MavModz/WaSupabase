// Restricted and locked accounts stop at the door of each engine (R4, R5,
// R8, R9), and with the switch off nothing changes (REQ-H2). Each engine
// owns the check, so callers other than the webhook are covered too.
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';

const h = vi.hoisted(() => ({
  getEntitlements: vi.fn(),
  autoFrom: vi.fn(),
  flowFrom: vi.fn(),
  aiFrom: vi.fn(),
}));

vi.mock('./resolve', () => ({ getEntitlements: h.getEntitlements }));

// A chain that ends in "no rows", enough to pass each engine's gate and
// stop at its first lookup. What matters is whether it was reached.
function emptyChain(spy: (table: string) => void) {
  return (table: string) => {
    spy(table);
    const chain: Record<string, unknown> = {};
    for (const m of ['select', 'eq', 'in', 'gt', 'gte', 'lte', 'order', 'limit', 'contains', 'is']) {
      chain[m] = () => chain;
    }
    chain.maybeSingle = async () => ({ data: null, error: null });
    chain.single = async () => ({ data: null, error: null });
    chain.then = (resolve: (v: unknown) => void) => resolve({ data: [], error: null });
    return chain;
  };
}

vi.mock('@/lib/automations/admin-client', () => ({
  supabaseAdmin: () => ({ from: emptyChain(h.autoFrom), rpc: async () => ({ data: null, error: null }) }),
}));
vi.mock('@/lib/flows/admin-client', () => ({
  supabaseAdmin: () => ({ from: emptyChain(h.flowFrom), rpc: async () => ({ data: null, error: null }) }),
}));
vi.mock('@/lib/ai/admin-client', () => ({
  supabaseAdmin: () => ({ from: emptyChain(h.flowFrom) }),
}));
vi.mock('@/lib/ai/config', async (original) => ({
  ...(await original<object>()),
  loadAiConfig: async () => {
    h.aiFrom();
    return null;
  },
}));

import { resumeAwaitingReply, runAutomationsForTrigger } from '@/lib/automations/engine';
import { dispatchInboundToFlows } from '@/lib/flows/engine';
import { dispatchInboundToAiReply } from '@/lib/ai/auto-reply';
import { retrieveKnowledge } from '@/lib/ai/knowledge';
import { dispatchWebhookEvent } from '@/lib/webhooks/deliver';
import { entitlements } from './ent.test-helper';
import type { PlanState } from './types';

const automationInput = {
  accountId: 'acc-1',
  triggerType: 'keyword_match',
  context: {},
} as unknown as Parameters<typeof runAutomationsForTrigger>[0];

const awaitingInput = {
  accountId: 'acc-1',
  contactId: 'c-1',
} as unknown as Parameters<typeof resumeAwaitingReply>[0];

const flowInput = {
  accountId: 'acc-1',
  contactId: 'c-1',
  conversationId: 'conv-1',
  isFirstInboundMessage: false,
  message: { meta_message_id: 'm-1', type: 'text', text: 'hi' },
} as unknown as Parameters<typeof dispatchInboundToFlows>[0];

const aiInput = {
  accountId: 'acc-1',
  conversationId: 'conv-1',
  contactId: 'c-1',
  configOwnerUserId: 'u-1',
} as unknown as Parameters<typeof dispatchInboundToAiReply>[0];

const setState = (state: PlanState | null) =>
  h.getEntitlements.mockResolvedValue(state ? entitlements(state) : null);

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

describe.each(['restricted', 'locked'] as const)('%s account', (state) => {
  beforeEach(() => setState(state));

  it('runs no automation (AC-R4-3)', async () => {
    await runAutomationsForTrigger(automationInput);
    expect(h.autoFrom).not.toHaveBeenCalled();
  });

  it('resumes no wait', async () => {
    expect(await resumeAwaitingReply(awaitingInput)).toBe(false);
    expect(h.autoFrom).not.toHaveBeenCalled();
  });

  it('starts or advances no flow run (R5)', async () => {
    expect(await dispatchInboundToFlows(flowInput)).toEqual({ consumed: false });
    expect(h.flowFrom).not.toHaveBeenCalled();
  });

  it('sends no auto-reply (R9)', async () => {
    await dispatchInboundToAiReply(aiInput);
    expect(h.aiFrom).not.toHaveBeenCalled();
  });
});

describe.each(['trialing', 'active', 'past_due'] as const)('%s account', (state) => {
  beforeEach(() => setState(state));

  it('reaches the automation engine', async () => {
    await runAutomationsForTrigger(automationInput);
    expect(h.autoFrom).toHaveBeenCalled();
  });

  it('reaches the flow engine', async () => {
    await dispatchInboundToFlows(flowInput);
    expect(h.flowFrom).toHaveBeenCalled();
  });

  it('reaches the AI config', async () => {
    await dispatchInboundToAiReply(aiInput);
    expect(h.aiFrom).toHaveBeenCalled();
  });
});

describe('after restored (AC-S2, REQ-S2)', () => {
  it('the next trigger runs with no user action', async () => {
    setState('restricted');
    await runAutomationsForTrigger(automationInput);
    expect(h.autoFrom).not.toHaveBeenCalled();
    setState('active');
    await runAutomationsForTrigger(automationInput);
    expect(h.autoFrom).toHaveBeenCalled();
  });
});

describe('switch off', () => {
  it('every engine carries on', async () => {
    setState(null);
    await runAutomationsForTrigger(automationInput);
    await dispatchInboundToFlows(flowInput);
    await dispatchInboundToAiReply(aiInput);
    expect(h.autoFrom).toHaveBeenCalled();
    expect(h.flowFrom).toHaveBeenCalled();
    expect(h.aiFrom).toHaveBeenCalled();
  });
});

describe('plan without the auto-reply bot', () => {
  it('sends no auto-reply even when active', async () => {
    h.getEntitlements.mockResolvedValue(entitlements('active', { ai_auto_reply: false }));
    await dispatchInboundToAiReply(aiInput);
    expect(h.aiFrom).not.toHaveBeenCalled();
  });
});

describe('dispatchWebhookEvent (R8)', () => {
  const from = vi.fn();
  const db = { from: emptyChain(from) } as unknown as SupabaseClient;

  it('stops delivering when locked', async () => {
    from.mockClear();
    setState('locked');
    await dispatchWebhookEvent(db, 'acc-1', 'message.received', {});
    expect(from).not.toHaveBeenCalled();
  });

  it('keeps delivering while restricted', async () => {
    from.mockClear();
    setState('restricted');
    await dispatchWebhookEvent(db, 'acc-1', 'message.received', {});
    expect(from).toHaveBeenCalledWith('webhook_endpoints');
  });
});

describe('retrieveKnowledge (AC-T5)', () => {
  const from = vi.fn();
  const db = { from: emptyChain(from), rpc: async () => ({ data: [], error: null }) } as unknown as SupabaseClient;
  const config = { embeddingsApiKey: null };

  it('skips documents on a plan with none', async () => {
    from.mockClear();
    h.getEntitlements.mockResolvedValue(entitlements('active', { kb_documents_max: 0 }));
    expect(await retrieveKnowledge(db, 'acc-1', config, 'hello')).toEqual([]);
    expect(from).not.toHaveBeenCalled();
  });

  it('looks them up on a plan that has them', async () => {
    from.mockClear();
    h.getEntitlements.mockResolvedValue(entitlements('active'));
    await retrieveKnowledge(db, 'acc-1', config, 'hello');
    expect(from).toHaveBeenCalled();
  });
});
