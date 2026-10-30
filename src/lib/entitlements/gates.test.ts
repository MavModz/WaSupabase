import { describe, expect, it } from 'vitest';

import { entitlements } from './ent.test-helper';
import { PlanLimitError } from './errors';
import {
  assertApiAccess,
  assertCanBroadcast,
  assertCanDraft,
  assertCanSendMessage,
  canAutoReply,
  canDeliverWebhooks,
  canRunEngines,
  canUseKnowledgeBase,
} from './gates';
import type { PlanState } from './types';

const passes = (fn: () => void) => {
  try {
    fn();
    return true;
  } catch (err) {
    expect(err).toBeInstanceOf(PlanLimitError);
    return false;
  }
};

// AC-S1: one row per capability in section 7 of the requirements.
const TABLE: [string, (s: PlanState) => boolean, boolean[]][] = [
  ['1:1 replies', (s) => passes(() => assertCanSendMessage(entitlements(s))), [true, true, true, true, false]],
  ['broadcast start or resume', (s) => passes(() => assertCanBroadcast(entitlements(s))), [true, true, true, false, false]],
  ['automations and flows execute', (s) => canRunEngines(entitlements(s)), [true, true, true, false, false]],
  ['AI auto-reply bot', (s) => canAutoReply(entitlements(s)), [true, true, true, false, false]],
  ['AI drafts', (s) => passes(() => assertCanDraft(entitlements(s))), [true, true, true, true, false]],
  ['outbound webhooks deliver', (s) => canDeliverWebhooks(entitlements(s)), [true, true, true, true, false]],
  ['public API read scope', (s) => passes(() => assertApiAccess(entitlements(s), 'contacts:read', false)), [true, true, true, true, false]],
  ['public API write scope', (s) => passes(() => assertApiAccess(entitlements(s), 'messages:send', false)), [true, true, true, false, false]],
  ['GET /api/v1/me', (s) => passes(() => assertApiAccess(entitlements(s), undefined, false)), [true, true, true, true, true]],
];
const STATES: PlanState[] = ['trialing', 'active', 'past_due', 'restricted', 'locked'];

describe('capabilities per plan state (AC-S1)', () => {
  for (const [name, check, expected] of TABLE) {
    it(name, () => {
      expect(STATES.map(check)).toEqual(expected);
    });
  }
});

describe('switch off (null entitlements)', () => {
  it('allows everything', () => {
    expect(canRunEngines(null)).toBe(true);
    expect(canAutoReply(null)).toBe(true);
    expect(canDeliverWebhooks(null)).toBe(true);
    expect(canUseKnowledgeBase(null)).toBe(true);
    expect(() => assertCanSendMessage(null)).not.toThrow();
    expect(() => assertCanBroadcast(null)).not.toThrow();
    expect(() => assertCanDraft(null)).not.toThrow();
    expect(() => assertApiAccess(null, 'messages:send', true)).not.toThrow();
  });
});

describe('plan flags', () => {
  it('a plan without the bot cannot auto-reply', () => {
    expect(canAutoReply(entitlements('active', { ai_auto_reply: false }))).toBe(false);
  });

  it('a plan with no documents does not retrieve them (AC-T5)', () => {
    expect(canUseKnowledgeBase(entitlements('active', { kb_documents_max: 0 }))).toBe(false);
    expect(canUseKnowledgeBase(entitlements('active', { kb_documents_max: 1 }))).toBe(true);
  });

  it('a plan with no API refuses every call, /me included (AC-R7-2)', () => {
    const ent = entitlements('active', { api_keys_max: 0 });
    expect(() => assertApiAccess(ent, 'contacts:read', false)).toThrow(PlanLimitError);
    expect(() => assertApiAccess(ent, undefined, false)).toThrow(PlanLimitError);
  });

  it('a suspended key is refused with its own reason', () => {
    try {
      assertApiAccess(entitlements(), 'contacts:read', true);
      expect.unreachable();
    } catch (err) {
      expect((err as PlanLimitError).code).toBe('plan_feature_unavailable');
      expect((err as PlanLimitError).detail.reason).toBe('key_suspended');
    }
  });

  it('every write scope is refused while restricted', () => {
    const ent = entitlements('restricted');
    for (const scope of ['messages:send', 'contacts:write', 'broadcasts:send', 'webhooks:manage']) {
      expect(() => assertApiAccess(ent, scope, false)).toThrow(PlanLimitError);
    }
    for (const scope of ['messages:read', 'contacts:read', 'conversations:read']) {
      expect(() => assertApiAccess(ent, scope, false)).not.toThrow();
    }
  });
});
