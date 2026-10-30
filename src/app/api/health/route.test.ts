import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const h = vi.hoisted(() => ({
  rpc: vi.fn(),
}))

vi.mock('@/lib/automations/admin-client', () => ({
  supabaseAdmin: () => ({
    rpc: (fn: string) => ({
      abortSignal: () => h.rpc(fn),
    }),
  }),
}))

import { __resetHealthCacheForTests } from '@/lib/health'
import { GET } from './route'

beforeEach(() => {
  __resetHealthCacheForTests()
  vi.spyOn(console, 'error').mockImplementation(() => {})
})

afterEach(() => {
  vi.restoreAllMocks()
  h.rpc.mockReset()
})

describe('GET /api/health', () => {
  it('returns 200 ok when health_ping answers true', async () => {
    h.rpc.mockResolvedValue({ data: true, error: null })
    const res = await GET()
    expect(res.status).toBe(200)
    expect(res.headers.get('cache-control')).toBe('no-store')
    expect(await res.json()).toEqual({ status: 'ok', checks: { db: 'ok' } })
    expect(h.rpc).toHaveBeenCalledWith('health_ping')
  })

  it('returns 503 degraded on an RPC error, without leaking its text', async () => {
    h.rpc.mockResolvedValue({ data: null, error: { message: 'connection to 10.0.0.3 refused', code: '08006' } })
    const res = await GET()
    expect(res.status).toBe(503)
    const body = await res.json()
    expect(body).toEqual({ status: 'degraded', checks: { db: 'error' } })
    expect(JSON.stringify(body)).not.toContain('10.0.0.3')
  })

  it('returns 503 when the RPC throws (timeout / network)', async () => {
    h.rpc.mockRejectedValue(new Error('aborted'))
    const res = await GET()
    expect(res.status).toBe(503)
  })

  it('caches the DB result briefly so polling costs one round trip', async () => {
    h.rpc.mockResolvedValue({ data: true, error: null })
    await GET()
    await GET()
    await GET()
    expect(h.rpc).toHaveBeenCalledTimes(1)
  })
})
