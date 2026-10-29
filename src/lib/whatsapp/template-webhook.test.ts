import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  handleTemplateWebhookChange,
  isTemplateWebhookField,
} from './template-webhook';

// Tiny mock that records the .update payload and the .eq / .in filters
// for inspection. Mirrors the surface this module actually uses on the
// Supabase client — anything beyond throws, so unintended calls fail
// loudly:
//   message_templates: .update().eq().in().select() → selectResult (then
//                      retrySelectResult for the 2nd call, if given)
//                      .insert()               → { error: insertError }
//   whatsapp_config:   .select().eq()           → { data: configRows }
//                      (defaults to one config on WABA-1)
type SelectResult = {
  data: { id: string }[] | null;
  error: { message: string; code?: string } | null;
};

const WABA = 'WABA-1';
const CONFIG = { account_id: 'acc-1', user_id: 'admin-1' };

/** Only the message_templates calls (the whatsapp_config lookup comes first). */
function templateCalls<T extends { table: string }>(calls: T[]): T[] {
  return calls.filter((c) => c.table === 'message_templates');
}

function makeSupabaseStub(
  selectResult: SelectResult = { data: [{ id: 'row-1' }], error: null },
  opts: {
    configRows?: { account_id: string; user_id: string }[];
    insertError?: { message: string; code?: string } | null;
    retrySelectResult?: SelectResult;
  } = {},
) {
  const calls: {
    table: string;
    update?: Record<string, unknown>;
    filter?: { column: string; value: unknown };
    scope?: { column: string; values: unknown[] };
    insert?: Record<string, unknown>;
    select?: string;
  }[] = [];
  let updateCount = 0;

  const stub = {
    from(table: string) {
      const entry: (typeof calls)[number] = { table };
      calls.push(entry);
      if (table === 'whatsapp_config') {
        return {
          select(columns: string) {
            entry.select = columns;
            return {
              eq(column: string, value: unknown) {
                entry.filter = { column, value };
                return Promise.resolve({
                  data: opts.configRows ?? [CONFIG],
                  error: null,
                });
              },
            };
          },
        };
      }
      return {
        insert(row: Record<string, unknown>) {
          entry.insert = row;
          return Promise.resolve({ error: opts.insertError ?? null });
        },
        update(payload: Record<string, unknown>) {
          entry.update = payload;
          updateCount++;
          const result =
            updateCount > 1 && opts.retrySelectResult
              ? opts.retrySelectResult
              : selectResult;
          return {
            eq(column: string, value: unknown) {
              entry.filter = { column, value };
              return {
                in(scopeColumn: string, values: unknown[]) {
                  entry.scope = { column: scopeColumn, values };
                  return {
                    select() {
                      return Promise.resolve(result);
                    },
                  };
                },
              };
            },
          };
        },
      };
    },
  };

  return { stub: stub as unknown as SupabaseClient, calls };
}

describe('isTemplateWebhookField', () => {
  it('recognises the three template fields', () => {
    expect(isTemplateWebhookField('message_template_status_update')).toBe(true);
    expect(isTemplateWebhookField('message_template_quality_update')).toBe(true);
    expect(isTemplateWebhookField('message_template_components_update')).toBe(
      true,
    );
  });
  it('rejects messaging fields', () => {
    expect(isTemplateWebhookField('messages')).toBe(false);
    expect(isTemplateWebhookField('message_status')).toBe(false);
  });
});

describe('handleTemplateWebhookChange — status update', () => {
  let supabaseCalls: ReturnType<typeof makeSupabaseStub>['calls'];

  beforeEach(() => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    vi.spyOn(console, 'info').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
  });

  it('flips status to APPROVED and clears any rejection_reason', async () => {
    const { stub, calls } = makeSupabaseStub();
    supabaseCalls = calls;
    await handleTemplateWebhookChange(
      {
        field: 'message_template_status_update',
        value: {
          event: 'APPROVED',
          message_template_id: 12345,
          message_template_name: 'order_confirmation',
          message_template_language: 'en_US',
        },
        wabaId: WABA,
      },
      stub,
    );
    expect(supabaseCalls.map((c) => c.table)).toEqual([
      'whatsapp_config',
      'message_templates',
    ]);
    expect(supabaseCalls[0].filter).toEqual({ column: 'waba_id', value: WABA });
    expect(supabaseCalls[1].filter).toEqual({
      column: 'meta_template_id',
      value: '12345', // coerced to string so the .eq matches the TEXT column
    });
    expect(supabaseCalls[1].scope).toEqual({
      column: 'account_id',
      values: ['acc-1'],
    });
    expect(supabaseCalls[1].update).toEqual({
      status: 'APPROVED',
      rejection_reason: null,
      submission_error: null,
    });
  });

  it('persists the reason field on REJECTED', async () => {
    const { stub, calls } = makeSupabaseStub();
    await handleTemplateWebhookChange(
      {
        field: 'message_template_status_update',
        value: {
          event: 'REJECTED',
          message_template_id: 'TMPL_99',
          reason: 'Template uses non-compliant language.',
        },
        wabaId: WABA,
      },
      stub,
    );
    expect(templateCalls(calls)[0].update?.status).toBe('REJECTED');
    expect(templateCalls(calls)[0].update?.rejection_reason).toBe(
      'Template uses non-compliant language.',
    );
  });

  it('falls back to a generic reason when REJECTED has no `reason`', async () => {
    const { stub, calls } = makeSupabaseStub();
    await handleTemplateWebhookChange(
      {
        field: 'message_template_status_update',
        value: { event: 'REJECTED', message_template_id: '7' },
        wabaId: WABA,
      },
      stub,
    );
    expect(templateCalls(calls)[0].update?.rejection_reason).toBe(
      'Rejected by Meta',
    );
  });

  it('maps REINSTATED to APPROVED and clears the old rejection', async () => {
    const { stub, calls } = makeSupabaseStub();
    await handleTemplateWebhookChange(
      {
        field: 'message_template_status_update',
        value: { event: 'REINSTATED', message_template_id: '1' },
        wabaId: WABA,
      },
      stub,
    );
    expect(templateCalls(calls)[0].update).toEqual({
      status: 'APPROVED',
      rejection_reason: null,
      submission_error: null,
    });
  });

  it.each(['FLAGGED', 'LIMIT_EXCEEDED', 'LOCKED', 'ARCHIVED', 'SOMETHING_NEW'])(
    'leaves the row untouched on %s, which is not a status we track',
    async (event) => {
      const { stub, calls } = makeSupabaseStub();
      await handleTemplateWebhookChange(
        {
          field: 'message_template_status_update',
          value: { event, message_template_id: '1' },
        },
        stub,
      );
      expect(calls).toHaveLength(0);
    },
  );

  it('keeps the rejection reason when a template is paused or disabled', async () => {
    for (const event of ['PAUSED', 'DISABLED', 'IN_APPEAL']) {
      const { stub, calls } = makeSupabaseStub();
      await handleTemplateWebhookChange(
        {
          field: 'message_template_status_update',
          value: { event, message_template_id: '1' },
          wabaId: WABA,
        },
        stub,
      );
      expect(templateCalls(calls)[0].update).toEqual({ status: event });
    }
  });

  it('maps DELETED to PENDING_DELETION', async () => {
    const { stub, calls } = makeSupabaseStub();
    await handleTemplateWebhookChange(
      {
        field: 'message_template_status_update',
        value: { event: 'DELETED', message_template_id: '1' },
        wabaId: WABA,
      },
      stub,
    );
    expect(templateCalls(calls)[0].update).toEqual({
      status: 'PENDING_DELETION',
    });
  });

  it('normalises PENDING_REVIEW → PENDING', async () => {
    const { stub, calls } = makeSupabaseStub();
    await handleTemplateWebhookChange(
      {
        field: 'message_template_status_update',
        value: { event: 'PENDING_REVIEW', message_template_id: '1' },
        wabaId: WABA,
      },
      stub,
    );
    expect(templateCalls(calls)[0].update?.status).toBe('PENDING');
  });

  it('logs and exits when meta_template_id is missing (no UPDATE issued)', async () => {
    const { stub, calls } = makeSupabaseStub();
    await handleTemplateWebhookChange(
      {
        field: 'message_template_status_update',
        value: { event: 'APPROVED' },
      },
      stub,
    );
    expect(calls).toHaveLength(0);
  });

  it('writes nothing and warns when no WABA id was passed', async () => {
    const warn = vi.spyOn(console, 'warn');
    const { stub, calls } = makeSupabaseStub();
    await handleTemplateWebhookChange(
      {
        field: 'message_template_status_update',
        value: {
          event: 'APPROVED',
          message_template_id: 'NEVER_SEEN',
          message_template_name: 'mystery',
        },
      },
      stub,
    );
    expect(warn).toHaveBeenCalled();
    expect(String(warn.mock.calls[0][0])).toContain('no WABA id');
    // Without a WABA id there is nothing to scope the write to — no
    // config lookup, no unscoped UPDATE, no insert.
    expect(calls).toHaveLength(0);
  });
});

describe('handleTemplateWebhookChange — unknown template stub (#534)', () => {
  beforeEach(() => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    vi.spyOn(console, 'info').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
  });

  it('inserts a stub row for a 0-row status update when exactly one config matches the WABA', async () => {
    const { stub, calls } = makeSupabaseStub(
      { data: [], error: null },
      { configRows: [CONFIG] },
    );
    await handleTemplateWebhookChange(
      {
        field: 'message_template_status_update',
        value: {
          event: 'APPROVED',
          message_template_id: 555,
          message_template_name: 'created_in_meta',
          message_template_language: 'de',
        },
        wabaId: 'WABA-1',
      },
      stub,
    );

    expect(calls.map((c) => c.table)).toEqual([
      'whatsapp_config', // resolve the tenant(s) on the WABA
      'message_templates', // the scoped UPDATE (0 rows)
      'message_templates', // the stub INSERT
    ]);
    expect(calls[0].select).toBe('account_id, user_id');
    expect(calls[0].filter).toEqual({ column: 'waba_id', value: 'WABA-1' });
    expect(calls[2].insert).toEqual({
      account_id: 'acc-1',
      user_id: 'admin-1',
      meta_template_id: '555',
      name: 'created_in_meta',
      language: 'de',
      body_text: '',
      status: 'APPROVED',
      rejection_reason: null,
      submission_error: null,
    });
  });

  it('carries the rejection reason into the stub on REJECTED and defaults language to en_US', async () => {
    const { stub, calls } = makeSupabaseStub(
      { data: [], error: null },
      { configRows: [CONFIG] },
    );
    await handleTemplateWebhookChange(
      {
        field: 'message_template_status_update',
        value: {
          event: 'REJECTED',
          message_template_id: '556',
          message_template_name: 'spammy',
          reason: 'INVALID_FORMAT',
        },
        wabaId: 'WABA-1',
      },
      stub,
    );
    expect(calls[2].insert).toMatchObject({
      status: 'REJECTED',
      rejection_reason: 'INVALID_FORMAT',
      language: 'en_US',
    });
  });

  it('warns with the WABA id and inserts nothing when no config matches', async () => {
    const warn = vi.spyOn(console, 'warn');
    const { stub, calls } = makeSupabaseStub(
      { data: [], error: null },
      { configRows: [] },
    );
    await handleTemplateWebhookChange(
      {
        field: 'message_template_status_update',
        value: {
          event: 'APPROVED',
          message_template_id: '557',
          message_template_name: 'orphan',
        },
        wabaId: 'WABA-NOBODY',
      },
      stub,
    );
    expect(calls).toHaveLength(1); // config lookup only: no update, no insert
    expect(calls.some((c) => c.insert)).toBe(false);
    expect(warn).toHaveBeenCalledTimes(1);
    const message = String(warn.mock.calls[0][0]);
    expect(message).toContain('WABA WABA-NOBODY');
    expect(message).toContain('557');
    expect(message).toContain('no whatsapp_config rows');
  });

  it('refuses to guess the tenant when several configs share the WABA id', async () => {
    const warn = vi.spyOn(console, 'warn');
    const { stub, calls } = makeSupabaseStub(
      { data: [], error: null },
      {
        configRows: [CONFIG, { account_id: 'acc-2', user_id: 'admin-2' }],
      },
    );
    await handleTemplateWebhookChange(
      {
        field: 'message_template_status_update',
        value: {
          event: 'APPROVED',
          message_template_id: '558',
          message_template_name: 'shared',
        },
        wabaId: 'WABA-1',
      },
      stub,
    );
    expect(calls.some((c) => c.insert)).toBe(false);
    expect(String(warn.mock.calls[0][0])).toContain('2 whatsapp_config rows');
  });

  it('inserts a stub with quality_score (and no status) for a 0-row quality update', async () => {
    const warn = vi.spyOn(console, 'warn');
    const { stub, calls } = makeSupabaseStub(
      { data: [], error: null },
      { configRows: [CONFIG] },
    );
    await handleTemplateWebhookChange(
      {
        field: 'message_template_quality_update',
        value: {
          message_template_id: '559',
          message_template_name: 'created_in_meta',
          message_template_language: 'en_US',
          previous_quality_score: 'UNKNOWN',
          new_quality_score: 'RED',
        },
        wabaId: 'WABA-1',
      },
      stub,
    );
    expect(calls[1].update).toEqual({ quality_score: 'RED' });
    expect(calls[2].insert).toEqual({
      account_id: 'acc-1',
      user_id: 'admin-1',
      meta_template_id: '559',
      name: 'created_in_meta',
      language: 'en_US',
      body_text: '',
      quality_score: 'RED',
    });
    // `status` is deliberately absent — the column default applies.
    expect(calls[2].insert).not.toHaveProperty('status');
    expect(warn).not.toHaveBeenCalled();
  });

  it('warns (with the WABA id) on a 0-row quality update when the tenant cannot be resolved', async () => {
    const warn = vi.spyOn(console, 'warn');
    const { stub, calls } = makeSupabaseStub(
      { data: [], error: null },
      { configRows: [] },
    );
    await handleTemplateWebhookChange(
      {
        field: 'message_template_quality_update',
        value: {
          message_template_id: '560',
          message_template_name: 'orphan',
          new_quality_score: 'GREEN',
        },
        wabaId: 'WABA-NOBODY',
      },
      stub,
    );
    expect(calls.some((c) => c.insert)).toBe(false);
    expect(String(warn.mock.calls[0][0])).toContain('quality update');
    expect(String(warn.mock.calls[0][0])).toContain('WABA WABA-NOBODY');
  });

  it('retries the update once when the stub insert hits a unique violation', async () => {
    const warn = vi.spyOn(console, 'warn');
    const { stub, calls } = makeSupabaseStub(
      { data: [], error: null },
      {
        configRows: [CONFIG],
        insertError: { message: 'duplicate key', code: '23505' },
        retrySelectResult: { data: [{ id: 'row-raced' }], error: null },
      },
    );
    await handleTemplateWebhookChange(
      {
        field: 'message_template_status_update',
        value: {
          event: 'PAUSED',
          message_template_id: '561',
          message_template_name: 'raced',
        },
        wabaId: 'WABA-1',
      },
      stub,
    );
    const updates = calls.filter((c) => c.update);
    expect(updates).toHaveLength(2);
    expect(updates[1].update).toEqual(updates[0].update);
    expect(updates[1].filter).toEqual({
      column: 'meta_template_id',
      value: '561',
    });
    expect(updates[1].scope).toEqual({ column: 'account_id', values: ['acc-1'] });
    expect(warn).not.toHaveBeenCalled();
  });

  it('does not create a stub when the event has no template name', async () => {
    const warn = vi.spyOn(console, 'warn');
    const { stub, calls } = makeSupabaseStub(
      { data: [], error: null },
      { configRows: [CONFIG] },
    );
    await handleTemplateWebhookChange(
      {
        field: 'message_template_status_update',
        value: { event: 'APPROVED', message_template_id: '562' },
        wabaId: 'WABA-1',
      },
      stub,
    );
    expect(calls).toHaveLength(2); // config lookup + 0-row update, no insert
    expect(String(warn.mock.calls[0][0])).toContain('no message_template_name');
  });
});

describe('handleTemplateWebhookChange — quality update', () => {
  it('sets quality_score from new_quality_score', async () => {
    const { stub, calls } = makeSupabaseStub();
    await handleTemplateWebhookChange(
      {
        field: 'message_template_quality_update',
        value: {
          message_template_id: '99',
          previous_quality_score: 'GREEN',
          new_quality_score: 'YELLOW',
        },
        wabaId: WABA,
      },
      stub,
    );
    expect(calls[1].update).toEqual({ quality_score: 'YELLOW' });
    expect(calls[1].scope).toEqual({ column: 'account_id', values: ['acc-1'] });
    expect(calls[1].filter).toEqual({
      column: 'meta_template_id',
      value: '99',
    });
  });

  it('stores null for unrecognised quality scores', async () => {
    const { stub, calls } = makeSupabaseStub();
    await handleTemplateWebhookChange(
      {
        field: 'message_template_quality_update',
        value: {
          message_template_id: '99',
          new_quality_score: 'PURPLE', // not a real Meta value
        },
        wabaId: WABA,
      },
      stub,
    );
    expect(calls[1].update).toEqual({ quality_score: null });
  });
});

// In-memory message_templates + whatsapp_config, applying the real
// .eq / .in filters, so these cases prove which rows a write touches
// rather than which filter arguments were passed.
function makeRowStore(
  templates: { id: string; account_id: string; meta_template_id: string }[],
  configs: { account_id: string; user_id: string; waba_id: string }[],
) {
  const rows = templates.map((r) => ({ ...r }) as Record<string, unknown>);
  const stub = {
    from(table: string) {
      if (table === 'whatsapp_config') {
        return {
          select() {
            return {
              eq(_column: 'waba_id', value: unknown) {
                return Promise.resolve({
                  data: configs
                    .filter((c) => c.waba_id === value)
                    .map(({ account_id, user_id }) => ({ account_id, user_id })),
                  error: null,
                });
              },
            };
          },
        };
      }
      return {
        insert() {
          return Promise.resolve({ error: null });
        },
        update(payload: Record<string, unknown>) {
          return {
            eq(column: string, value: unknown) {
              return {
                in(scopeColumn: string, values: unknown[]) {
                  return {
                    select() {
                      const hit = rows.filter(
                        (r) =>
                          r[column] === value &&
                          values.includes(r[scopeColumn]),
                      );
                      hit.forEach((r) => Object.assign(r, payload));
                      return Promise.resolve({
                        data: hit.map((r) => ({ id: r.id as string })),
                        error: null,
                      });
                    },
                  };
                },
              };
            },
          };
        },
      };
    },
  };
  return { stub: stub as unknown as SupabaseClient, rows };
}

describe('handleTemplateWebhookChange — tenant scoping (WABA → accounts)', () => {
  beforeEach(() => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    vi.spyOn(console, 'info').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
  });

  const rejected = {
    field: 'message_template_status_update',
    value: {
      event: 'REJECTED',
      message_template_id: 'T-1',
      message_template_name: 'promo',
      reason: 'secret reason',
    },
  };

  it("leaves an unrelated account's row with the same meta_template_id untouched", async () => {
    const { stub, rows } = makeRowStore(
      [
        { id: 'own', account_id: 'acc-1', meta_template_id: 'T-1' },
        { id: 'spoof', account_id: 'acc-evil', meta_template_id: 'T-1' },
      ],
      [{ account_id: 'acc-1', user_id: 'u1', waba_id: 'WABA-1' }],
    );
    await handleTemplateWebhookChange({ ...rejected, wabaId: 'WABA-1' }, stub);
    expect(rows.find((r) => r.id === 'own')).toMatchObject({
      status: 'REJECTED',
      rejection_reason: 'secret reason',
    });
    expect(rows.find((r) => r.id === 'spoof')).not.toHaveProperty('status');
    expect(rows.find((r) => r.id === 'spoof')).not.toHaveProperty(
      'rejection_reason',
    );
  });

  it('still updates every account that shares the WABA', async () => {
    const { stub, rows } = makeRowStore(
      [
        { id: 'a', account_id: 'acc-1', meta_template_id: 'T-1' },
        { id: 'b', account_id: 'acc-2', meta_template_id: 'T-1' },
        { id: 'x', account_id: 'acc-other', meta_template_id: 'T-1' },
      ],
      [
        { account_id: 'acc-1', user_id: 'u1', waba_id: 'WABA-1' },
        { account_id: 'acc-2', user_id: 'u2', waba_id: 'WABA-1' },
        { account_id: 'acc-other', user_id: 'u3', waba_id: 'WABA-9' },
      ],
    );
    await handleTemplateWebhookChange(
      {
        field: 'message_template_quality_update',
        value: { message_template_id: 'T-1', new_quality_score: 'RED' },
        wabaId: 'WABA-1',
      },
      stub,
    );
    expect(rows.find((r) => r.id === 'a')?.quality_score).toBe('RED');
    expect(rows.find((r) => r.id === 'b')?.quality_score).toBe('RED');
    expect(rows.find((r) => r.id === 'x')).not.toHaveProperty('quality_score');
  });

  it('writes nothing at all when the WABA id is missing', async () => {
    const { stub, rows } = makeRowStore(
      [
        { id: 'a', account_id: 'acc-1', meta_template_id: 'T-1' },
        { id: 'b', account_id: 'acc-2', meta_template_id: 'T-1' },
      ],
      [{ account_id: 'acc-1', user_id: 'u1', waba_id: 'WABA-1' }],
    );
    await handleTemplateWebhookChange(rejected, stub);
    await handleTemplateWebhookChange(
      {
        field: 'message_template_quality_update',
        value: { message_template_id: 'T-1', new_quality_score: 'RED' },
      },
      stub,
    );
    for (const r of rows) {
      expect(r).not.toHaveProperty('status');
      expect(r).not.toHaveProperty('quality_score');
    }
  });
});

describe('handleTemplateWebhookChange — components update', () => {
  it('is an info-log no-op (does not write to DB)', async () => {
    const info = vi.spyOn(console, 'info').mockImplementation(() => {});
    const { stub, calls } = makeSupabaseStub();
    await handleTemplateWebhookChange(
      {
        field: 'message_template_components_update',
        value: {
          message_template_id: '5',
          message_template_name: 'x',
        },
      },
      stub,
    );
    expect(calls).toHaveLength(0);
    expect(info).toHaveBeenCalled();
  });
});

describe('handleTemplateWebhookChange — unknown field', () => {
  it('is a defensive no-op', async () => {
    const { stub, calls } = makeSupabaseStub();
    await handleTemplateWebhookChange(
      // Pretend Meta added a new template_* field we don't know about.
      // The route handler pre-filters via isTemplateWebhookField, but
      // the dispatch should still be safe if the filter is bypassed.
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      { field: 'message_template_future_field' as any, value: {} },
      stub,
    );
    expect(calls).toHaveLength(0);
  });
});
