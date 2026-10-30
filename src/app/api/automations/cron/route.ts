import { timingSafeEqual } from 'node:crypto'
import { NextResponse } from 'next/server'
import { supabaseAdmin } from '@/lib/automations/admin-client'
import {
  claimPendingExecution,
  expireAwaitingReplies,
  requeueStalledExecutions,
  resumePendingExecution,
} from '@/lib/automations/engine'
import type { AutomationContext } from '@/lib/automations/engine'
import { log, requestIdOf, withLogContext } from '@/lib/log'
import { rateLimitBackend } from '@/lib/rate-limit'
import { isEntitlementsEnabled } from '@/lib/entitlements/config'
import { canRunEngines } from '@/lib/entitlements/gates'
import { getEntitlements } from '@/lib/entitlements/resolve'

/**
 * How long a due wait of a restricted or locked account is pushed back
 * (R4: waits don't resume). Moving it off the scan keeps a paused account
 * from filling the 50-row page and starving everyone else, and it resumes
 * within this long of the state being restored.
 */
const PAUSED_WAIT_RETRY_MS = 60 * 60 * 1000

/**
 * Drain due `automation_pending_executions` rows. Meant to be hit
 * on a schedule (Vercel Cron / external pinger) — requires a shared
 * secret via the `x-cron-secret` header to match
 * `AUTOMATION_CRON_SECRET`.
 *
 * The claim step (status = 'running') serves as a simple lock so
 * overlapping invocations don't double-process rows. Best-effort
 * only; expensive SELECT ... FOR UPDATE is avoided in favor of a
 * two-step UPDATE-by-id.
 */
export async function GET(request: Request) {
  const expected = process.env.AUTOMATION_CRON_SECRET
  if (!expected) {
    return NextResponse.json({ error: 'cron not configured' }, { status: 503 })
  }
  const supplied = request.headers.get('x-cron-secret') ?? ''
  const suppliedBuf = Buffer.from(supplied)
  const expectedBuf = Buffer.from(expected)
  if (
    suppliedBuf.length !== expectedBuf.length ||
    !timingSafeEqual(suppliedBuf, expectedBuf)
  ) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
  }

  return withLogContext({ requestId: requestIdOf(request), route: 'automations.cron' }, runCron)
}

/**
 * Drop long-expired shared rate-limit windows (migration 065). Only
 * the postgres backend writes that table. Best-effort: a failure is
 * logged and never affects the cron's own work or response.
 */
async function sweepRateLimits() {
  if (rateLimitBackend() !== 'postgres') return
  try {
    const { data, error } = await supabaseAdmin().rpc('rate_limit_sweep')
    if (error) throw error
    if (typeof data === 'number' && data > 0) log.info('rate_limit.swept', { deleted: data })
  } catch (err) {
    log.warn('rate_limit.sweep_failed', { err })
  }
}

/**
 * Materialise lazy plan transitions and apply due downgrades (067). Best
 * effort: enforcement reads the lazy state, so a failed sweep delays the
 * audit rows and deactivations, and never affects the cron's own work.
 */
async function sweepEntitlements() {
  if (!isEntitlementsEnabled()) return
  try {
    const { data, error } = await supabaseAdmin().rpc('entitlements_run_due')
    if (error) throw error
    log.info('entitlements.swept', { result: data })
  } catch (err) {
    log.error('entitlements.sweep_failed', { err })
  }
}

async function runCron() {
  await sweepRateLimits()
  await sweepEntitlements()

  // Close out wait_for_reply runs whose 24h reply window lapsed. The
  // webhook already refuses to resume them; this just settles their
  // status and explains the outcome on the log.
  const expired = await expireAwaitingReplies()
  const requeued = await requeueStalledExecutions()

  const admin = supabaseAdmin()
  const { data: due, error } = await admin
    .from('automation_pending_executions')
    .select('*')
    .eq('status', 'pending')
    .lte('run_at', new Date().toISOString())
    .order('run_at', { ascending: true })
    .limit(50)

  if (error) {
    log.error('automations.cron.scan_failed', { err: error })
    return NextResponse.json({ error: error.message }, { status: 500 })
  }
  if (!due || due.length === 0) return NextResponse.json({ processed: 0, expired, requeued })

  let processed = 0
  // One lookup per account per run. Empty, and unused, with the switch off.
  const pausedByAccount = new Map<string, boolean>()
  for (const row of due) {
    if (isEntitlementsEnabled()) {
      const accountId = row.account_id as string
      let paused = pausedByAccount.get(accountId)
      if (paused === undefined) {
        paused = !canRunEngines(await getEntitlements(accountId))
        pausedByAccount.set(accountId, paused)
      }
      if (paused) {
        await admin
          .from('automation_pending_executions')
          .update({ run_at: new Date(Date.now() + PAUSED_WAIT_RETRY_MS).toISOString() })
          .eq('id', row.id as string)
          .eq('account_id', accountId)
          .eq('status', 'pending')
        continue
      }
    }

    if (!(await claimPendingExecution(row.id as string))) continue

    await resumePendingExecution({
      id: row.id as string,
      automation_id: row.automation_id as string,
      // account_id is NOT NULL on automation_pending_executions
      // post-017; the engine uses it for tenant-scoped lookups.
      account_id: row.account_id as string,
      user_id: row.user_id as string,
      contact_id: (row.contact_id as string | null) ?? null,
      log_id: (row.log_id as string | null) ?? null,
      parent_step_id: (row.parent_step_id as string | null) ?? null,
      branch: (row.branch as 'yes' | 'no' | null) ?? null,
      next_step_position: row.next_step_position as number,
      parked_step_id: (row.parked_step_id as string | null) ?? null,
      context: (row.context as AutomationContext) ?? {},
    })
    processed++
  }

  log.info('automations.cron.done', { processed, expired, requeued })
  return NextResponse.json({ processed, expired, requeued })
}
