import { describe, expect, it, vi } from 'vitest';

import { ApiError, toApiErrorResponse } from './respond';

describe('toApiErrorResponse', () => {
  it('keeps an ApiError as-is, with no error_id', async () => {
    const res = toApiErrorResponse(new ApiError('forbidden', 'missing scope', 403));
    expect(res.status).toBe(403);
    expect(await res.json()).toEqual({ error: { code: 'forbidden', message: 'missing scope' } });
  });

  it('maps anything else to a generic 500 whose error_id matches the log line', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {});
    const res = toApiErrorResponse(new Error('db exploded at row 7'));
    expect(res.status).toBe(500);
    const body = await res.json();
    expect(body.error.code).toBe('internal');
    expect(body.error.message).toBe('Internal server error');
    expect(body.error.error_id).toMatch(/^[0-9a-f-]{36}$/);
    expect(JSON.stringify(body)).not.toContain('db exploded');
    expect(String(spy.mock.calls[0][0])).toContain(body.error.error_id);
    spy.mockRestore();
  });
});
