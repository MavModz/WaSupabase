// ============================================================
// Entitlements switch (app half). Off by default (D-15, REQ-H2).
//
// Pure and synchronous on purpose: every gate calls this first and
// returns before any I/O, so with the switch off call sequences are
// exactly what they were before Phase 2. The DB half is
// platform_settings.entitlements_enabled, which also enables the
// enforcement triggers (migration 068). `getEntitlements` treats the
// switch as on only when both agree. Runbook: docs/entitlements.md.
// ============================================================

export function isEntitlementsEnabled(): boolean {
  return process.env.ENTITLEMENTS_ENABLED === 'true';
}
