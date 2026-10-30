import { beforeEach, describe, expect, it, vi } from 'vitest'

const h = vi.hoisted(() => ({
  user: { id: 'user-1' } as { id: string } | null,
  rpcCalls: [] as string[],
  rpcResult: {} as Record<string, { data: unknown; error: unknown }>,
}))

vi.mock('@/lib/supabase/server', () => ({
  createClient: async () => ({
    auth: { getUser: async () => ({ data: { user: h.user } }) },
    rpc: async (fn: string) => {
      h.rpcCalls.push(fn)
      return h.rpcResult[fn] ?? { data: null, error: null }
    },
  }),
}))

import { __resetRateLimitForTests } from '@/lib/rate-limit'
import { POST } from './route'

const call = () =>
  POST(new Request('https://app.test/api/invitations/tok/redeem', { method: 'POST' }), {
    params: Promise.resolve({ token: 'tok' }),
  })

beforeEach(() => {
  __resetRateLimitForTests()
  h.user = { id: 'user-1' }
  h.rpcCalls = []
  h.rpcResult = {}
})

describe('POST /api/invitations/[token]/redeem', () => {
  it('heals a profile-less caller (ensure_my_account) before redeeming', async () => {
    h.rpcResult.redeem_invitation = { data: 'acct-team', error: null }
    const res = await call()
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ ok: true, accountId: 'acct-team' })
    expect(h.rpcCalls).toEqual(['ensure_my_account', 'redeem_invitation'])
  })

  it('still attempts the redeem when the heal fails, and maps its refusal', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})
    h.rpcResult.ensure_my_account = { data: null, error: { message: 'x', code: 'XX000' } }
    h.rpcResult.redeem_invitation = {
      data: null,
      error: { message: 'Caller has no profile', code: '42501' },
    }
    const res = await call()
    expect(res.status).toBe(401)
    expect(h.rpcCalls).toEqual(['ensure_my_account', 'redeem_invitation'])
  })

  it('returns 401 without touching the RPCs when signed out', async () => {
    h.user = null
    const res = await call()
    expect(res.status).toBe(401)
    expect(h.rpcCalls).toEqual([])
  })
})
