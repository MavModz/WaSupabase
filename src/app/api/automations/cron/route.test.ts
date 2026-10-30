import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const h = vi.hoisted(() => ({
  rpc: vi.fn(),
  due: [] as unknown[],
}))

vi.mock('@/lib/automations/admin-client', () => ({
  supabaseAdmin: () => ({
    rpc: (fn: string) => h.rpc(fn),
    from: () => {
      const builder: Record<string, unknown> = {}
      for (const m of ['select', 'eq', 'lte', 'order']) builder[m] = () => builder
      builder.limit = async () => ({ data: h.due, error: null })
      return builder
    },
  }),
}))

vi.mock('@/lib/automations/engine', () => ({
  expireAwaitingReplies: async () => 0,
  requeueStalledExecutions: async () => 0,
  claimPendingExecution: async () => true,
  resumePendingExecution: async () => {},
}))

import { GET } from './route'

const call = (secret = 'cron-secret') =>
  GET(new Request('https://app.test/api/automations/cron', { headers: { 'x-cron-secret': secret } }))

beforeEach(() => {
  vi.stubEnv('AUTOMATION_CRON_SECRET', 'cron-secret')
  vi.stubEnv('RATE_LIMIT_BACKEND', '')
  vi.spyOn(console, 'log').mockImplementation(() => {})
  vi.spyOn(console, 'warn').mockImplementation(() => {})
  h.rpc.mockReset()
  h.due = []
})

afterEach(() => {
  vi.unstubAllEnvs()
  vi.restoreAllMocks()
})

describe('GET /api/automations/cron', () => {
  it('returns 503 when the secret is not configured', async () => {
    vi.stubEnv('AUTOMATION_CRON_SECRET', '')
    expect((await call()).status).toBe(503)
  })

  it('returns 401 on a wrong secret', async () => {
    expect((await call('nope-nope-no')).status).toBe(401)
    expect(h.rpc).not.toHaveBeenCalled()
  })

  it('does not sweep rate limits on the memory backend', async () => {
    const res = await call()
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ processed: 0, expired: 0, requeued: 0 })
    expect(h.rpc).not.toHaveBeenCalled()
  })

  it('sweeps rate limits on the postgres backend', async () => {
    vi.stubEnv('RATE_LIMIT_BACKEND', 'postgres')
    h.rpc.mockResolvedValue({ data: 3, error: null })
    const res = await call()
    expect(res.status).toBe(200)
    expect(h.rpc).toHaveBeenCalledWith('rate_limit_sweep')
  })

  it('a failed sweep never fails the cron', async () => {
    vi.stubEnv('RATE_LIMIT_BACKEND', 'postgres')
    h.rpc.mockRejectedValue(new Error('db down'))
    const res = await call()
    expect(res.status).toBe(200)
    expect(String((console.warn as unknown as ReturnType<typeof vi.fn>).mock.calls[0][0])).toContain(
      'rate_limit.sweep_failed',
    )
  })
})
