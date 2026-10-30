// ============================================================
// What each plan state allows (requirements section 7). Pure, no I/O.
// `null` entitlements mean "switch off, or lookup failed": allowed.
// Every DB-backed limit has a trigger behind it, so failing open here
// never lets a count limit through (N-11).
// ============================================================

import { PlanLimitError } from './errors';
import type { Entitlements } from './types';

type Ent = Entitlements | null;

function isPaused(ent: Ent): boolean {
  return ent?.state === 'restricted' || ent?.state === 'locked';
}

/** Automations and flows execute; waits resume. */
export function canRunEngines(ent: Ent): boolean {
  return !isPaused(ent);
}

export function canAutoReply(ent: Ent): boolean {
  return !ent || (!isPaused(ent) && ent.limits.ai_auto_reply);
}

export function canDeliverWebhooks(ent: Ent): boolean {
  return ent?.state !== 'locked';
}

/** On a plan with 0 documents, retrieval skips them (R9, AC-T5). */
export function canUseKnowledgeBase(ent: Ent): boolean {
  return !ent || ent.limits.kb_documents_max > 0;
}

function stateError(state: 'restricted' | 'locked', resource: string): PlanLimitError {
  return new PlanLimitError({
    code: 'plan_feature_unavailable',
    resource,
    reason: state === 'restricted' ? 'account_restricted' : 'account_locked',
  });
}

/** 1:1 sends: allowed while restricted (customers mustn't be ignored). */
export function assertCanSendMessage(ent: Ent): void {
  if (ent?.state === 'locked') throw stateError('locked', 'messages');
}

export function assertCanBroadcast(ent: Ent): void {
  if (ent?.state === 'restricted' || ent?.state === 'locked') {
    throw stateError(ent.state, 'broadcast_recipients');
  }
}

/** Drafts: restricted allowed, locked blocked; and the plan flag. */
export function assertCanDraft(ent: Ent): void {
  if (ent?.state === 'locked') throw stateError('locked', 'ai_drafts');
  if (ent && !ent.limits.ai_drafts) {
    throw new PlanLimitError({
      code: 'plan_feature_unavailable',
      resource: 'ai_drafts',
      reason: 'not_on_plan',
    });
  }
}

const WRITE_SCOPES = new Set([
  'messages:send',
  'contacts:write',
  'broadcasts:send',
  'webhooks:manage',
]);

/**
 * Public API access for a request (R7). `scope` undefined means a
 * scope-free endpoint (`GET /api/v1/me`), the one call a locked account
 * keeps. Throws {@link PlanLimitError}.
 */
export function assertApiAccess(
  ent: Ent,
  scope: string | undefined,
  keySuspended: boolean
): void {
  if (!ent) return;
  if (ent.limits.api_keys_max === 0 || keySuspended) {
    throw new PlanLimitError({
      code: 'plan_feature_unavailable',
      resource: 'public_api',
      reason: keySuspended ? 'key_suspended' : 'not_on_plan',
    });
  }
  if (ent.state === 'locked' && scope !== undefined) {
    throw stateError('locked', 'public_api');
  }
  if (ent.state === 'restricted' && scope !== undefined && WRITE_SCOPES.has(scope)) {
    throw stateError('restricted', 'public_api');
  }
}
