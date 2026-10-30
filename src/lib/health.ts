// Health checks behind GET /api/health (see that route for the
// contract). Lives outside the route file because a route module may
// only export HTTP handlers and segment config.

import { supabaseAdmin } from '@/lib/automations/admin-client'
import { log } from '@/lib/log'

const CACHE_MS = 5_000
const DB_TIMEOUT_MS = 2_000

export type CheckState = 'ok' | 'error'

let cached: { db: CheckState; at: number } | null = null

/** Test-only: forget the cached DB result. */
export function __resetHealthCacheForTests() {
  cached = null
}

async function pingDb(): Promise<CheckState> {
  try {
    const { data, error } = await supabaseAdmin()
      .rpc('health_ping')
      .abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS))
    if (error || data !== true) {
      log.error('health.db_failed', { err: error ?? { message: 'unexpected health_ping result' } })
      return 'error'
    }
    return 'ok'
  } catch (err) {
    log.error('health.db_failed', { err })
    return 'error'
  }
}

/** DB reachability, cached for CACHE_MS per process. */
export async function checkDb(): Promise<CheckState> {
  const now = Date.now()
  if (!cached || now - cached.at >= CACHE_MS) {
    cached = { db: await pingDb(), at: now }
  }
  return cached.db
}
