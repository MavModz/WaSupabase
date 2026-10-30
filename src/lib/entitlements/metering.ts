// ============================================================
// Broadcast metering (R3). Reserve allowance BEFORE the Meta call and
// refund whatever Meta didn't accept, so concurrent broadcasts can't
// overshoot (REQ-X5) and recipients that fail don't count (AC-R3-2).
// Metered here rather than from broadcast_recipients rows because the
// browser stamps those rows, so they can be falsified.
//
// Fails CLOSED (N-11): if the allowance can't be read, nothing is sent.
// ============================================================

import { supabaseAdmin } from '@/lib/flows/admin-client';
import { log } from '@/lib/log';
import { isEntitlementsEnabled } from './config';

const RESOURCE = 'broadcast_recipients';

export interface BroadcastMeter {
  /**
   * May the next recipient be sent? `remaining` counts recipients still
   * to go, this one included, and sizes the next reservation. Never
   * throws: an RPC failure answers false and sets `failed`.
   */
  take(remaining: number): Promise<boolean>;
  /** The recipient just taken was not accepted by Meta. */
  refund(): void;
  /** Return unused and refunded allowance. Call once, when done. */
  settle(): Promise<void>;
  /** True once a reservation was refused or could not be made. */
  readonly stopped: boolean;
  /** Why it stopped: plan limit or state, or null when `failed`. */
  readonly code: 'plan_limit_reached' | 'plan_feature_unavailable' | null;
  /** The allowance couldn't be read at all. */
  readonly failed: boolean;
}

/**
 * Returns null with the switch off, so callers skip all metering.
 * `chunkSize` bounds how much one reservation holds: a crash between
 * reserve and settle over-counts by at most this much (accepted).
 */
export function createBroadcastMeter(
  accountId: string,
  chunkSize: number
): BroadcastMeter | null {
  if (!isEntitlementsEnabled()) return null;

  let allowance = 0;
  let toRelease = 0;
  let periodStart: string | null = null;
  let stopped = false;
  let failed = false;
  let code: BroadcastMeter['code'] = null;

  const release = async () => {
    const count = toRelease;
    toRelease = 0;
    if (count <= 0 || !periodStart) return;
    try {
      const { error } = await supabaseAdmin().rpc('entitlement_release', {
        p_account: accountId,
        p_resource: RESOURCE,
        p_period_start: periodStart,
        p_count: count,
      });
      if (error) throw error;
    } catch (err) {
      // Over-counts the account slightly, in its disfavour. Never fatal.
      log.warn('entitlements.release_failed', { accountId, count, err });
    }
  };

  return {
    get stopped() {
      return stopped;
    },
    get failed() {
      return failed;
    },
    get code() {
      return code;
    },

    async take(remaining) {
      if (stopped) return false;
      if (allowance === 0) {
        // Settle refunds first: they belong to this reservation's period,
        // which may not be the next one's.
        await release();
        try {
          const { data, error } = await supabaseAdmin().rpc('entitlement_consume', {
            p_account: accountId,
            p_resource: RESOURCE,
            p_requested: Math.max(1, Math.min(chunkSize, remaining)),
          });
          if (error) throw error;
          const row = (Array.isArray(data) ? data[0] : data) as {
            granted: number;
            period_start: string | null;
            reason: string | null;
          } | null;
          if (!row) throw new Error('entitlement_consume returned no row');
          periodStart = row.period_start;
          allowance = row.granted;
          if (allowance <= 0) {
            stopped = true;
            code = row.reason?.startsWith('account_')
              ? 'plan_feature_unavailable'
              : 'plan_limit_reached';
            return false;
          }
        } catch (err) {
          log.error('entitlements.consume_failed', { accountId, err });
          stopped = true;
          failed = true;
          return false;
        }
      }
      allowance -= 1;
      return true;
    },

    refund() {
      toRelease += 1;
    },

    async settle() {
      toRelease += allowance;
      allowance = 0;
      await release();
    },
  };
}
