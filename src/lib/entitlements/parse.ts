// ============================================================
// Parse a WA00x database error into its detail. Client-safe (no
// `@/lib/log`, no `next/*`): the browser hits the same triggers through
// PostgREST, and Phase 2b's UI reads the same shape.
// ============================================================

import type { PlanErrorCode, PlanErrorDetail } from './types';

const CODE_BY_SQLSTATE: Record<string, PlanErrorCode> = {
  WA001: 'plan_limit_reached',
  WA002: 'plan_feature_unavailable',
  WA003: 'downgrade_blocked',
};

/**
 * Returns the detail when `err` is a Supabase/PostgREST error raised by
 * an entitlement trigger or RPC, otherwise null. Tolerates a malformed
 * DETAIL: the SQLSTATE alone is enough to classify the error.
 */
export function parsePlanError(err: unknown): PlanErrorDetail | null {
  if (!err || typeof err !== 'object') return null;
  const { code, details } = err as { code?: unknown; details?: unknown };
  if (typeof code !== 'string') return null;
  const planCode = CODE_BY_SQLSTATE[code];
  if (!planCode) return null;

  let parsed: Partial<PlanErrorDetail> = {};
  if (typeof details === 'string' && details) {
    try {
      const value: unknown = JSON.parse(details);
      if (value && typeof value === 'object') parsed = value as Partial<PlanErrorDetail>;
    } catch {
      // Keep the classification; the numbers are best-effort.
    }
  }
  return { ...parsed, code: planCode, resource: parsed.resource ?? 'unknown' };
}
