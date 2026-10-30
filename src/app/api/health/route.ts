// ============================================================
// GET /api/health — liveness plus a cheap database check.
//
// Public on purpose (uptime monitors, load balancers, the Docker
// healthcheck), so the body says only whether each check passed:
// no versions, no hostnames, no error text, no secrets. The reason a
// check failed goes to the server log (`health.db_failed`).
//
//   200 { status: 'ok',       checks: { db: 'ok' } }
//   503 { status: 'degraded', checks: { db: 'error' } }
//
// The DB check calls `health_ping()` (migration 063), a constant
// function, rather than reading a table. Its result is cached in this
// process for a few seconds so a monitor polling every second (or a
// burst of anonymous hits) costs at most one round trip per window.
// ============================================================

import { NextResponse } from 'next/server'

import { checkDb } from '@/lib/health'

export const dynamic = 'force-dynamic'

export async function GET() {
  const db = await checkDb()
  const healthy = db === 'ok'
  return NextResponse.json(
    { status: healthy ? 'ok' : 'degraded', checks: { db } },
    { status: healthy ? 200 : 503, headers: { 'Cache-Control': 'no-store' } },
  )
}
