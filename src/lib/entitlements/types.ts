// Shapes returned by the SQL functions in migration 067. Client-safe:
// no runtime imports.

export type PlanKey = 'trial' | 'starter' | 'growth' | 'pro' | 'legacy_beta';

export type PlanState = 'trialing' | 'active' | 'past_due' | 'restricted' | 'locked';

/** One typed value per limit; mirrors the columns of `plans` (066). */
export interface PlanLimits {
  seats_included: number;
  seats_max: number;
  contacts_max: number;
  broadcast_recipients_per_period: number;
  automations_active_max: number;
  automations_total_max: number;
  flows_active_max: number;
  flows_total_max: number;
  whatsapp_numbers_max: number;
  api_keys_max: number;
  api_rate_per_minute: number;
  webhook_endpoints_max: number;
  ai_drafts: boolean;
  ai_auto_reply: boolean;
  kb_documents_max: number;
  storage_bytes_max: number;
  pipelines_max: number;
}

/** `account_entitlements(account)`. State and plan are already lazily resolved. */
export interface Entitlements {
  enabled: boolean;
  account_id: string;
  plan: PlanKey;
  plan_name: string;
  state: PlanState;
  state_reason: string | null;
  limits: PlanLimits;
  period_start: string;
  period_end: string;
  trial_ends_at: string | null;
  scheduled_plan: PlanKey | null;
  scheduled_change_at: string | null;
  was_legacy_beta: boolean;
  legacy_ends_at: string | null;
}

export type PlanErrorCode =
  | 'plan_limit_reached'
  | 'plan_feature_unavailable'
  | 'downgrade_blocked';

/** The JSON a WA00x error carries in DETAIL (migration 067 `_ent_raise`). */
export interface PlanErrorDetail {
  code: PlanErrorCode;
  resource: string;
  usage?: number;
  limit?: number;
  reason?: string;
  requested?: number;
  remaining?: number;
  resets_at?: string;
  to_free?: number;
  plan?: string;
}
