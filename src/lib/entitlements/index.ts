// Server entry point. Client code imports `./parse` and `./types`
// directly (this barrel reaches `@/lib/log`, which is server-only).
export { isEntitlementsEnabled } from './config';
export { PlanLimitError, fromPostgrestError, planErrorResponse } from './errors';
export { parsePlanError } from './parse';
export {
  assertApiAccess,
  assertCanBroadcast,
  assertCanDraft,
  assertCanSendMessage,
  canAutoReply,
  canDeliverWebhooks,
  canRunEngines,
  canUseKnowledgeBase,
} from './gates';
export { canMirrorInboundMedia, getEntitlements, isApiKeySuspended } from './resolve';
export { createBroadcastMeter, type BroadcastMeter } from './metering';
export type {
  Entitlements,
  PlanErrorCode,
  PlanErrorDetail,
  PlanKey,
  PlanLimits,
  PlanState,
} from './types';
