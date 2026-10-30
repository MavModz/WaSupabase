/**
 * Per-key rate limiter with a pluggable backend.
 *
 * Fixed-window counter (not token bucket): every identifier gets a
 * fresh N-request budget each window. `checkRateLimit` is async and
 * every call site awaits it; the result shape is the same for both
 * backends.
 *
 * Backends (env `RATE_LIMIT_BACKEND`):
 *   - `memory` (default): a Map in this Node process. Fine for a
 *     single-instance VPS/Docker deploy, which is how forkers of this
 *     template usually run. Horizontal scale (several containers,
 *     Vercel serverless fan-out) silently multiplies every budget.
 *   - `postgres`: one atomic upsert per check through the
 *     `rate_limit_hit` RPC (migration 065), shared by every instance.
 *     Set this for any multi-instance or serverless deploy.
 *
 * Failure mode (postgres): if the RPC errors or takes longer than
 * SHARED_TIMEOUT_MS, the check falls back to the in-memory counter for
 * that call and logs `rate_limit.backend_error` (at most once a
 * minute). Limits therefore degrade to per-instance instead of either
 * vanishing (fail-open) or locking every user out (fail-closed).
 *
 * Memory: entries are ~50 bytes each. With LIGHT_SWEEP below, expired
 * keys get cleared opportunistically on every ~1 000th call, so a
 * healthy instance stays in the low-MB range even with thousands of
 * distinct users. No background timer — works in serverless edge
 * runtimes that don't keep timers alive across requests. The postgres
 * table is swept by `rate_limit_sweep()` from the automations cron.
 */

import { NextResponse } from 'next/server';
import { supabaseAdmin } from '@/lib/automations/admin-client';
import { getT } from '@/lib/i18n/translate';
import { log } from '@/lib/log';

const t = getT('LibErrors');

export interface RateLimitOptions {
  /** Max requests allowed in `windowMs`. */
  limit: number;
  /** Window size, milliseconds. */
  windowMs: number;
}

export interface RateLimitResult {
  success: boolean;
  /** Requests still allowed in the current window. */
  remaining: number;
  /** Unix ms when the bucket refills. */
  reset: number;
  limit: number;
}

interface Entry {
  count: number;
  resetAt: number;
}

const buckets = new Map<string, Entry>();

// Opportunistic cleanup. Running a sweep on every call would be
// quadratic; running it 1-in-N lets the Map self-drain without a
// background timer.
const LIGHT_SWEEP_EVERY = 1000;
let callsSinceSweep = 0;

function sweepExpired(now: number) {
  for (const [k, v] of buckets) {
    if (v.resetAt <= now) buckets.delete(k);
  }
}

function checkMemory(
  key: string,
  { limit, windowMs }: RateLimitOptions,
): RateLimitResult {
  const now = Date.now();

  callsSinceSweep += 1;
  if (callsSinceSweep >= LIGHT_SWEEP_EVERY) {
    callsSinceSweep = 0;
    sweepExpired(now);
  }

  const entry = buckets.get(key);

  if (!entry || entry.resetAt <= now) {
    buckets.set(key, { count: 1, resetAt: now + windowMs });
    return { success: true, remaining: limit - 1, reset: now + windowMs, limit };
  }

  if (entry.count >= limit) {
    return { success: false, remaining: 0, reset: entry.resetAt, limit };
  }

  entry.count += 1;
  return {
    success: true,
    remaining: limit - entry.count,
    reset: entry.resetAt,
    limit,
  };
}

export type RateLimitBackend = 'memory' | 'postgres';

/** The configured backend; anything but `postgres` means memory. */
export function rateLimitBackend(): RateLimitBackend {
  return process.env.RATE_LIMIT_BACKEND?.trim().toLowerCase() === 'postgres'
    ? 'postgres'
    : 'memory';
}

/** Upper bound on one shared check before falling back to memory. */
const SHARED_TIMEOUT_MS = 300;
/** rate_limit_buckets.key is CHECKed to this length. */
const MAX_KEY_LENGTH = 256;
const BACKEND_ERROR_LOG_EVERY_MS = 60_000;
let lastBackendErrorLog = 0;

interface RateLimitHitRow {
  allowed: boolean;
  remaining: number;
  reset_at: string;
}

async function checkShared(
  key: string,
  opts: RateLimitOptions,
): Promise<RateLimitResult> {
  try {
    const { data, error } = await supabaseAdmin()
      .rpc('rate_limit_hit', {
        p_key: key.slice(0, MAX_KEY_LENGTH),
        p_limit: opts.limit,
        p_window_ms: opts.windowMs,
      })
      .abortSignal(AbortSignal.timeout(SHARED_TIMEOUT_MS));
    if (error) throw error;
    const row = (Array.isArray(data) ? data[0] : data) as RateLimitHitRow | null;
    const reset = row ? Date.parse(row.reset_at) : NaN;
    if (!row || typeof row.allowed !== 'boolean' || Number.isNaN(reset)) {
      throw new Error('rate_limit_hit returned an unexpected shape');
    }
    return {
      success: row.allowed,
      remaining: row.remaining,
      reset,
      limit: opts.limit,
    };
  } catch (err) {
    const now = Date.now();
    if (now - lastBackendErrorLog >= BACKEND_ERROR_LOG_EVERY_MS) {
      lastBackendErrorLog = now;
      log.error('rate_limit.backend_error', { backend: 'postgres', err });
    }
    return checkMemory(key, opts);
  }
}

/**
 * Count one request against `key` and say whether it is allowed.
 * Always resolves (never rejects): backend trouble degrades to the
 * in-memory counter, see the header.
 */
export async function checkRateLimit(
  key: string,
  opts: RateLimitOptions,
): Promise<RateLimitResult> {
  if (rateLimitBackend() === 'postgres') return checkShared(key, opts);
  return checkMemory(key, opts);
}

/**
 * Standard 429 response with the headers clients expect (RFC 6585 +
 * draft-ietf-httpapi-ratelimit-headers). Callers just `return` this.
 */
export function getClientIp(request: Request): string {
  const realIp = request.headers.get('x-real-ip')?.trim();
  if (realIp) return realIp;
  const forwardedFor = request.headers.get('x-forwarded-for');
  if (forwardedFor) {
    const hops = forwardedFor
      .split(',')
      .map((hop) => hop.trim())
      .filter(Boolean);
    const proxyAppended = hops[hops.length - 1];
    if (proxyAppended) return proxyAppended;
  }
  return 'unknown';
}

export function rateLimitResponse(result: RateLimitResult): NextResponse {
  const retryAfterSec = Math.max(1, Math.ceil((result.reset - Date.now()) / 1000));
  return NextResponse.json(
    {
      error: t('rateLimitExceeded'),
      retry_after_seconds: retryAfterSec,
    },
    {
      status: 429,
      headers: {
        'Retry-After': String(retryAfterSec),
        'X-RateLimit-Limit': String(result.limit),
        'X-RateLimit-Remaining': String(result.remaining),
        'X-RateLimit-Reset': String(Math.ceil(result.reset / 1000)),
      },
    },
  );
}

/** Preconfigured budgets, tweak here not at call sites. */
export const RATE_LIMITS = {
  /** Individual message send. 60/min per user = one per second
   *  sustained, comfortable for a live human typing. */
  send: { limit: 60, windowMs: 60_000 },
  /** Broadcast dispatch. NOT one call per campaign: the wizard fans a
   *  campaign out over `/api/whatsapp/broadcast` in batches of 10
   *  recipients, roughly one call every 1–2 s, so a 1 000-recipient
   *  send is ~100 calls over several minutes. This bucket was 5/min on
   *  the assumption of one call per campaign, which meant everything
   *  past the first ~50 recipients came back 429 and was recorded as a
   *  failed recipient (issue #472). 60/min per user carries the wizard's
   *  pacing with headroom while still bounding a script in a loop;
   *  Meta's own per-number limits remain the real throughput ceiling. */
  broadcast: { limit: 60, windowMs: 60_000 },
  /** Reaction add/swap/remove. More permissive than send — users
   *  fidget with reactions and a single "swap" is actually two calls
   *  (remove + add) under the hood. */
  react: { limit: 120, windowMs: 60_000 },
  /** Invitation peek (public, per-IP). 30/min lets a forwarded link
   *  retry a handful of times under flaky connectivity without
   *  enabling brute-force token enumeration. With 256-bit tokens the
   *  enumeration risk is theoretical; this is belt-and-braces. */
  invitationPeek: { limit: 30, windowMs: 60_000 },
  /** Invitation redeem (authed, per-IP+user). Tighter than peek —
   *  successful redemption mutates two profiles and an invite row, so
   *  the abuse surface is "spam join attempts." */
  invitationRedeem: { limit: 10, windowMs: 60_000 },
  /** Admin-only account / member-management actions: create/revoke
   *  invitation, rename account, change member role, remove member,
   *  transfer ownership. 30/min per user is comfortably above any
   *  realistic legitimate use (the Members tab is a clicks-only UI)
   *  while still bounding accidental abuse from a script run in a
   *  loop or a compromised admin session spamming role flips. */
  adminAction: { limit: 30, windowMs: 60_000 },
  /** Public REST API (`/api/v1/*`), keyed per API key. 120/min ≈ 2
   *  req/s sustained — comfortable for a polling integration or an
   *  automation firing on inbound events, while bounding a runaway
   *  script. Like every bucket here it's per-process unless
   *  RATE_LIMIT_BACKEND=postgres (see the top of this file), which a
   *  multi-instance deploy needs. */
  publicApi: { limit: 120, windowMs: 60_000 },
  /** AI draft-reply generation, per user. 20/min is generous for an
   *  agent clicking "Draft with AI" while working a thread, and bounds
   *  spend on the account's own LLM key against an accidental
   *  hold-down / script. */
  aiDraft: { limit: 20, windowMs: 60_000 },
  /** AI draft-reply generation, per account. Caps the WHOLE team's
   *  draws on the one shared BYO provider key — without this, N agents
   *  each under their per-user limit could still stampede the account's
   *  key past the provider's own rate limit. 60/min ≈ three busy agents
   *  drafting flat-out. */
  aiDraftAccount: { limit: 60, windowMs: 60_000 },
  /** AI auto-reply generation, per account. The per-conversation cap
   *  (`auto_reply_max_per_conversation`) bounds one thread; this bounds
   *  the whole account across threads, so a burst of inbound from many
   *  customers at once can't run the BYO key past the provider's limit
   *  or the owner's budget. 30/min is generous for organic inbound while
   *  capping a stampede; excess inbounds simply don't get an auto-reply
   *  (they still land in the inbox for a human). */
  aiAutoReplyAccount: { limit: 30, windowMs: 60_000 },
  whatsappAdmin: { limit: 30, windowMs: 60_000 },
  whatsappHealth: { limit: 30, windowMs: 60_000 },
  whatsappMedia: { limit: 240, windowMs: 60_000 },
  automationTrigger: { limit: 30, windowMs: 60_000 },
} as const;

/** Test-only helper. Clears the in-memory state so unit tests don't
 *  leak buckets across files. Not wired up in production code. */
export function __resetRateLimitForTests() {
  buckets.clear();
  callsSinceSweep = 0;
  lastBackendErrorLog = 0;
}
