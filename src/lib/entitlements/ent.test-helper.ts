import type { Entitlements, PlanLimits, PlanState } from './types';

/** Growth's limits (migration 066), the plan with everything switched on. */
export const GROWTH_LIMITS: PlanLimits = {
  seats_included: 5,
  seats_max: 25,
  contacts_max: 25000,
  broadcast_recipients_per_period: 100000,
  automations_active_max: 25,
  automations_total_max: 250,
  flows_active_max: 15,
  flows_total_max: 150,
  whatsapp_numbers_max: 1,
  api_keys_max: 3,
  api_rate_per_minute: 120,
  webhook_endpoints_max: 3,
  ai_drafts: true,
  ai_auto_reply: true,
  kb_documents_max: 50,
  storage_bytes_max: 10737418240,
  pipelines_max: 10,
};

export const ALL_STATES: PlanState[] = ['trialing', 'active', 'past_due', 'restricted', 'locked'];

export function entitlements(
  state: PlanState = 'active',
  limits: Partial<PlanLimits> = {}
): Entitlements {
  return {
    enabled: true,
    account_id: 'acc-1',
    plan: 'growth',
    plan_name: 'Growth',
    state,
    state_reason: null,
    limits: { ...GROWTH_LIMITS, ...limits },
    period_start: '2026-11-01T00:00:00Z',
    period_end: '2026-12-01T00:00:00Z',
    trial_ends_at: null,
    scheduled_plan: null,
    scheduled_change_at: null,
    was_legacy_beta: false,
    legacy_ends_at: null,
  };
}
