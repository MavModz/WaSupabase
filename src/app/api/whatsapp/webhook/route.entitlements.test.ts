// REQ-X11: no plan state can stop the webhook from storing a message. The
// route consults no plan state before storage; the only plan input is the
// inbound-media gate, which fails open. Engine gates are in
// lib/entitlements/engine-gates.test.ts.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const h = vi.hoisted(() => ({
  createClientOptions: [] as unknown[],
  upserts: [] as Record<string, unknown>[],
  uploads: [] as string[],
  contactInserts: [] as Record<string, unknown>[],
  afterCallbacks: [] as (() => Promise<void> | void)[],
  contactInsertError: null as unknown,
  rpcCalls: [] as { name: string; args: unknown }[],
  canMirror: vi.fn(),
  flows: vi.fn(),
  automations: vi.fn(),
  resume: vi.fn(),
  ai: vi.fn(),
  hooks: vi.fn(),
  existingContact: null as Record<string, unknown> | null,
}));

vi.mock('next/server', () => ({
  after: (cb: () => Promise<void> | void) => {
    h.afterCallbacks.push(cb);
  },
  NextResponse: {
    json: (body: unknown, init?: { status?: number }) => ({ body, init, status: init?.status ?? 200 }),
  },
}));

vi.mock('@supabase/supabase-js', () => ({
  createClient: (_url: string, _key: string, options: unknown) => {
    h.createClientOptions.push(options);
    return {
      from(table: string) {
        const chain: Record<string, unknown> = {};
        for (const m of ['select', 'eq', 'order', 'limit', 'is', 'in', 'update']) chain[m] = () => chain;
        chain.maybeSingle = async () => ({ data: null, error: null });
        chain.then = (resolve: (v: unknown) => void) => {
          if (table === 'whatsapp_config') {
            return resolve({
              data: [{ account_id: 'acc-1', user_id: 'u-1', access_token: 'enc', mirror_inbound_media: true }],
              error: null,
            });
          }
          if (table === 'conversations') {
            return resolve({ data: [{ id: 'conv-1', unread_count: 0, account_id: 'acc-1' }], error: null });
          }
          return resolve({ data: [], error: null });
        };
        if (table === 'contacts') {
          chain.insert = (row: Record<string, unknown>) => {
            h.contactInserts.push(row);
            return {
              select: () => ({
                single: async () =>
                  h.contactInsertError
                    ? { data: null, error: h.contactInsertError }
                    : { data: { id: 'contact-new', ...row }, error: null },
              }),
            };
          };
        }
        if (table === 'messages') {
          chain.upsert = (row: Record<string, unknown>) => {
            h.upserts.push(row);
            return { select: async () => ({ data: [{ id: 'msg-1' }], error: null }) };
          };
        }
        return chain;
      },
      rpc: async (name: string, args: unknown) => {
        h.rpcCalls.push({ name, args });
        return name === 'ent_create_inbound_contact'
          ? { data: { id: 'contact-rpc' }, error: null }
          : { data: null, error: null };
      },
      storage: {
        from: () => ({
          upload: async (path: string) => {
            h.uploads.push(path);
            return { error: null };
          },
          getPublicUrl: (path: string) => ({ data: { publicUrl: `https://cdn.test/${path}` } }),
        }),
      },
    };
  },
}));

vi.mock('@/lib/whatsapp/encryption', () => ({
  decrypt: () => 'tok',
  encrypt: (v: string) => v,
  isLegacyFormat: () => false,
}));
vi.mock('@/lib/whatsapp/meta-api', () => ({
  getMediaUrl: async () => ({ url: 'https://lookaside.test/a', mimeType: 'image/jpeg', fileSize: 10 }),
  downloadMedia: async () => ({ buffer: Buffer.alloc(10), contentType: 'image/jpeg' }),
}));
vi.mock('@/lib/contacts/dedupe', () => ({
  findExistingContact: async () => h.existingContact,
  isUniqueViolation: () => false,
}));
vi.mock('@/lib/whatsapp/webhook-signature', () => ({ verifyMetaWebhookSignature: () => true }));
vi.mock('@/lib/whatsapp/template-webhook', () => ({
  isTemplateWebhookField: () => false,
  handleTemplateWebhookChange: vi.fn(),
}));
vi.mock('@/lib/automations/engine', () => ({
  runAutomationsForTrigger: h.automations,
  resumeAwaitingReply: h.resume,
}));
vi.mock('@/lib/flows/engine', () => ({ dispatchInboundToFlows: h.flows }));
vi.mock('@/lib/ai/auto-reply', () => ({ dispatchInboundToAiReply: h.ai }));
vi.mock('@/lib/webhooks/deliver', () => ({ dispatchWebhookEvent: h.hooks }));
vi.mock('@/lib/whatsapp/message-status-sync', () => ({ applyMessageStatus: async () => [] }));
vi.mock('@/lib/entitlements/resolve', () => ({ canMirrorInboundMedia: h.canMirror }));

import { POST } from './route';

function inbound(message: Record<string, unknown>) {
  return new Request('http://localhost/api/whatsapp/webhook', {
    method: 'POST',
    headers: { 'x-hub-signature-256': 'sha256=stub' },
    body: JSON.stringify({
      entry: [
        {
          changes: [
            {
              field: 'messages',
              value: {
                metadata: { phone_number_id: 'pn-1' },
                contacts: [{ wa_id: '15551230000', profile: { name: 'Ada' } }],
                messages: [{ id: 'wamid.1', from: '15551230000', timestamp: '1700000000', ...message }],
              },
            },
          ],
        },
      ],
    }),
  });
}

async function run(message: Record<string, unknown>) {
  await POST(inbound(message));
  for (const cb of h.afterCallbacks) await cb();
}

const TEXT = { type: 'text', text: { body: 'hello' } };
const IMAGE = { type: 'image', image: { id: 'media-1', mime_type: 'image/jpeg' } };

beforeEach(() => {
  h.upserts.length = 0;
  h.uploads.length = 0;
  h.contactInserts.length = 0;
  h.afterCallbacks.length = 0;
  h.rpcCalls.length = 0;
  h.contactInsertError = null;
  h.existingContact = { id: 'contact-1', name: 'Ada', phone: '15551230000' };
  vi.clearAllMocks();
  h.canMirror.mockResolvedValue(true);
  h.flows.mockResolvedValue({ consumed: false });
  h.resume.mockResolvedValue(false);
  h.automations.mockResolvedValue(undefined);
  h.ai.mockResolvedValue(undefined);
  h.hooks.mockResolvedValue(undefined);
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

afterEach(() => vi.restoreAllMocks());

describe('webhook and entitlements', () => {
  it('its client carries the inbound exemption header (D-13)', async () => {
    await run(TEXT);
    expect(h.createClientOptions[0]).toEqual({ global: { headers: { 'x-wacrm-inbound': '1' } } });
  });

  it('a text message makes no plan lookup and is stored (REQ-X11)', async () => {
    await run(TEXT);
    expect(h.canMirror).not.toHaveBeenCalled();
    expect(h.upserts).toHaveLength(1);
  });

  it('an unknown number still creates the contact and stores the message (AC-R2-2)', async () => {
    h.existingContact = null;
    await run(TEXT);
    expect(h.contactInserts).toHaveLength(1);
    expect(h.upserts).toHaveLength(1);
  });

  it('if a gateway strips the header, the RPC fallback still stores the message (REQ-X11)', async () => {
    h.existingContact = null;
    h.contactInsertError = { code: 'WA001', message: 'plan_limit_reached', details: '{}' };
    await run(TEXT);
    const fallback = h.rpcCalls.find((c) => c.name === 'ent_create_inbound_contact');
    expect(fallback?.args).toMatchObject({ p_row: { account_id: 'acc-1' } });
    expect(h.upserts).toHaveLength(1);
  });

  it('within the storage gate, media is mirrored', async () => {
    await run(IMAGE);
    expect(h.canMirror).toHaveBeenCalledWith('acc-1');
    expect(h.uploads).toHaveLength(1);
    expect(String(h.upserts[0].media_url)).toContain('cdn.test');
  });

  it('above 110%, the message is stored on the Meta proxy and nothing is mirrored (AC-R10-2, D-17)', async () => {
    h.canMirror.mockResolvedValue(false);
    await run(IMAGE);
    expect(h.uploads).toHaveLength(0);
    expect(h.upserts).toHaveLength(1);
    expect(h.upserts[0].media_url).toBe('/api/whatsapp/media/media-1');
  });

  it('still dispatches to the engines, which own their state checks', async () => {
    await run(TEXT);
    expect(h.flows).toHaveBeenCalled();
    expect(h.hooks).toHaveBeenCalled();
  });
});
