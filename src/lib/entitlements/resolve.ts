// ============================================================
// Server-side entitlement lookup. Never cached across requests: a state
// change takes effect on the next request (REQ-S1).
// ============================================================

import { supabaseAdmin } from '@/lib/flows/admin-client';
import { log } from '@/lib/log';
import { isEntitlementsEnabled } from './config';
import type { Entitlements } from './types';

/**
 * The account's resolved plan and state, or null when nothing should be
 * enforced: switch off (no I/O at all), the DB half of the switch off
 * (logged, the two should be flipped together), or a failed lookup
 * (logged, fails open; the DB triggers still hold every count limit,
 * N-11). Never throws, so it is safe inside the webhook's `after()`.
 */
export async function getEntitlements(accountId: string): Promise<Entitlements | null> {
  if (!isEntitlementsEnabled()) return null;
  try {
    const { data, error } = await supabaseAdmin().rpc('account_entitlements', {
      p_account: accountId,
    });
    if (error) throw error;
    const ent = data as Entitlements | null;
    if (!ent?.enabled) {
      log.warn('entitlements.switch_mismatch', { accountId });
      return null;
    }
    return ent;
  } catch (err) {
    log.warn('entitlements.lookup_failed', { accountId, err });
    return null;
  }
}

/**
 * Is this API key suspended by a downgrade (R7)? Read separately from
 * the auth lookup and only with the switch on, so the auth path doesn't
 * depend on migration 068 when entitlements are off. Fails open.
 */
export async function isApiKeySuspended(keyId: string): Promise<boolean> {
  if (!isEntitlementsEnabled()) return false;
  try {
    const { data, error } = await supabaseAdmin()
      .from('api_keys')
      .select('plan_suspended_at')
      .eq('id', keyId)
      .maybeSingle();
    if (error) throw error;
    return !!data?.plan_suspended_at;
  } catch (err) {
    log.warn('entitlements.key_lookup_failed', { keyId, err });
    return false;
  }
}

/**
 * May inbound media still be mirrored into storage (D-17, 110% of the
 * limit)? Fails open: over-storing beats losing an attachment. Above the
 * gate the caller falls back to the Meta media proxy, as it does when
 * mirroring is off.
 */
export async function canMirrorInboundMedia(accountId: string): Promise<boolean> {
  if (!isEntitlementsEnabled()) return true;
  try {
    const { data, error } = await supabaseAdmin().rpc('entitlement_can_mirror_media', {
      p_account: accountId,
    });
    if (error) throw error;
    return data !== false;
  } catch (err) {
    log.warn('entitlements.mirror_gate_failed', { accountId, err });
    return true;
  }
}
