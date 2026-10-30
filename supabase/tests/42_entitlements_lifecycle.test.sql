-- ============================================================
-- Entitlements lifecycle (migrations 067/068) — `supabase test db`
-- ============================================================
-- Grandfathering, the trial, one trial per number, operator RPCs and
-- their audit rows, downgrade application, grace, the sweep, the switch
-- keeping its data, and metering arithmetic. Rolled back at the end.
-- ============================================================
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(62);

-- Before go-live: A is grandfathered.
INSERT INTO auth.users (instance_id, id, aud, role, email, raw_user_meta_data, created_at, updated_at) VALUES
  ('00000000-0000-0000-0000-000000000000', '42000000-0000-4000-8000-00000000000a', 'authenticated', 'authenticated', 'life-a@example.test', '{"full_name":"A"}', now(), now());
SELECT set_config('fx.a', (SELECT account_id::text FROM public.profiles WHERE user_id = '42000000-0000-4000-8000-00000000000a'), true);

SELECT is((SELECT plan_key || '/' || state || '/' || was_legacy_beta FROM public.account_subscriptions WHERE account_id = current_setting('fx.a')::uuid),
  'legacy_beta/active/true', 'an account before go-live is legacy_beta (REQ-G1, REQ-G4)');
SELECT is((public.account_entitlements(current_setting('fx.a')::uuid)->'limits'->>'contacts_max'), '100000', 'legacy_beta has Pro limits');
SELECT is((public.account_entitlements(current_setting('fx.a')::uuid)->>'enabled'), 'false', 'the switch starts off');
SELECT is((SELECT granted FROM public.entitlement_consume(current_setting('fx.a')::uuid, 'broadcast_recipients', 1000000)), 1000000, 'consume is a no-op grant while off');
SELECT is((SELECT count(*)::int FROM public.account_usage_counters WHERE account_id = current_setting('fx.a')::uuid), 0, 'nothing is metered while off');

INSERT INTO public.whatsapp_config (user_id, account_id, phone_number_id, access_token) VALUES
  ('42000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, 'PN-0', 'x');

-- Go-live.
SELECT is((public.entitlements_set_enabled(true, 'op@test', 'go live')->>'enabled'), 'true', 'the operator switch turns on');
SELECT is((SELECT first_account_id::text FROM public.trial_number_claims WHERE phone_number_id = 'PN-0'), current_setting('fx.a'), 'numbers connected before go-live are claimed (N-8)');
DELETE FROM public.whatsapp_config WHERE phone_number_id = 'PN-0';
SELECT isnt_empty($$SELECT 1 FROM public.platform_settings WHERE entitlements_first_enabled_at IS NOT NULL$$, 'first go-live is stamped (REQ-H4)');
SELECT set_config('fx.go_live', (SELECT entitlements_first_enabled_at::text FROM public.platform_settings), true);

-- After go-live: B and C start on a trial (AC-G2).
INSERT INTO auth.users (instance_id, id, aud, role, email, raw_user_meta_data, created_at, updated_at) VALUES
  ('00000000-0000-0000-0000-000000000000', '42000000-0000-4000-8000-00000000000b', 'authenticated', 'authenticated', 'life-b@example.test', '{"full_name":"B"}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '42000000-0000-4000-8000-00000000000c', 'authenticated', 'authenticated', 'life-c@example.test', '{"full_name":"C"}', now(), now());
SELECT set_config('fx.b', (SELECT account_id::text FROM public.profiles WHERE user_id = '42000000-0000-4000-8000-00000000000b'), true);
SELECT set_config('fx.c', (SELECT account_id::text FROM public.profiles WHERE user_id = '42000000-0000-4000-8000-00000000000c'), true);

SELECT is((SELECT plan_key || '/' || state FROM public.account_subscriptions WHERE account_id = current_setting('fx.b')::uuid),
  'trial/trialing', 'an account after go-live starts on trial (AC-G2)');
SELECT is((SELECT trial_ends_at = now() + interval '14 days' FROM public.account_subscriptions WHERE account_id = current_setting('fx.b')::uuid),
  true, 'the trial is 14 days (AC-T1)');
SELECT is((SELECT plan_key FROM public.account_subscriptions WHERE account_id = current_setting('fx.a')::uuid),
  'legacy_beta', 'going live does not touch existing accounts');

-- ── Lazy trial expiry and operator extension. ──────────────────────
UPDATE public.account_subscriptions SET trial_ends_at = now() - interval '1 second' WHERE account_id = current_setting('fx.b')::uuid;
SELECT is((public.account_entitlements(current_setting('fx.b')::uuid)->>'state'), 'locked', 'an expired trial reads as locked with no cron (AC-T1)');
SELECT is((public.account_entitlements(current_setting('fx.b')::uuid)->>'state_reason'), 'trial_ended', 'the reason says why');
DELETE FROM public.entitlement_audit_log;
SELECT is((public.ent_set_trial_end(current_setting('fx.b')::uuid, now() + interval '7 days', 'op@test', 'extend')->>'state'), 'trialing', 'extending re-opens the trial on the next request (REQ-O1)');
SELECT is((SELECT count(*)::int FROM public.entitlement_audit_log), 1, 'the extension writes one audit row');
SELECT is((SELECT count(*)::int FROM public.entitlement_audit_log
           WHERE actor = 'op@test' AND account_id = current_setting('fx.b')::uuid
             AND old_value IS NOT NULL AND new_value IS NOT NULL AND created_at IS NOT NULL), 1,
  'the row holds operator, account, old value, new value and time');

-- ── One trial per WhatsApp number (REQ-T2). ────────────────────────
INSERT INTO public.whatsapp_config (user_id, account_id, phone_number_id, access_token) VALUES
  ('42000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, 'PN-1', 'x');
SELECT is((SELECT first_account_id::text FROM public.trial_number_claims WHERE phone_number_id = 'PN-1'), current_setting('fx.a'), 'every connected number is claimed, not only trials (N-8)');
DELETE FROM public.whatsapp_config WHERE phone_number_id = 'PN-1';
INSERT INTO public.whatsapp_config (user_id, account_id, phone_number_id, access_token) VALUES
  ('42000000-0000-4000-8000-00000000000b', current_setting('fx.b')::uuid, 'PN-1', 'x');
SELECT is((public.account_entitlements(current_setting('fx.b')::uuid)->>'state_reason'), 'trial_number_reused', 'a number used by another account ends the trial (AC-T2)');
SELECT is((public.account_entitlements(current_setting('fx.b')::uuid)->>'state'), 'locked', 'that account is locked');
DELETE FROM public.whatsapp_config WHERE phone_number_id = 'PN-1';
INSERT INTO public.whatsapp_config (user_id, account_id, phone_number_id, access_token) VALUES
  ('42000000-0000-4000-8000-00000000000c', current_setting('fx.c')::uuid, 'PN-2', 'x');
SELECT is((public.account_entitlements(current_setting('fx.c')::uuid)->>'state'), 'trialing', 'a fresh number keeps the trial');

-- ── Operator RPCs: refused for a customer owner (REQ-O1). ──────────
SELECT set_config('request.jwt.claims', '{"sub":"42000000-0000-4000-8000-00000000000c","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.ent_set_plan(current_setting('fx.c')::uuid, 'pro', 'me')$$, '42501', NULL, 'an owner cannot set their plan');
SELECT throws_ok($$SELECT public.ent_set_state(current_setting('fx.c')::uuid, 'active', 'me')$$, '42501', NULL, 'an owner cannot set their state');
SELECT throws_ok($$SELECT public.ent_set_trial_end(current_setting('fx.c')::uuid, now(), 'me')$$, '42501', NULL, 'an owner cannot extend their trial');
SELECT throws_ok($$SELECT public.ent_schedule_change(current_setting('fx.c')::uuid, 'pro', 'me')$$, '42501', NULL, 'an owner cannot schedule a change');
SELECT throws_ok($$SELECT public.ent_cancel_change(current_setting('fx.c')::uuid, 'me')$$, '42501', NULL, 'an owner cannot cancel a change');
SELECT throws_ok($$SELECT public.entitlements_set_enabled(false, 'me')$$, '42501', NULL, 'an owner cannot flip the switch');
SELECT throws_ok($$SELECT public.entitlement_consume(current_setting('fx.c')::uuid, 'broadcast_recipients', 1)$$, '42501', NULL, 'a client cannot consume');
SELECT throws_ok($$SELECT public.account_entitlements(current_setting('fx.c')::uuid)$$, '42501', NULL, 'a client cannot call account_entitlements directly');
RESET ROLE;
SELECT set_config('request.jwt.claims', '', true);

-- ── Audit: one row per operation. ──────────────────────────────────
DELETE FROM public.entitlement_audit_log;
SELECT public.ent_set_plan(current_setting('fx.c')::uuid, 'pro', 'op@test');
SELECT public.ent_set_state(current_setting('fx.c')::uuid, 'active', 'op@test');
SELECT public.ent_schedule_change(current_setting('fx.c')::uuid, 'growth', 'op@test');
SELECT public.ent_cancel_change(current_setting('fx.c')::uuid, 'op@test');
SELECT is(ARRAY(SELECT action FROM public.entitlement_audit_log ORDER BY id),
  ARRAY['set_plan', 'set_state', 'schedule_change', 'cancel_change'], 'each operator call wrote exactly one audit row');
SELECT is((public.account_entitlements(current_setting('fx.c')::uuid)->>'plan'), 'pro', 'a cancelled downgrade leaves the plan alone (AC-D2)');
SELECT throws_ok($$SELECT public.ent_set_plan(current_setting('fx.c')::uuid, 'pro', '')$$, '22023', NULL, 'an operator call needs an actor');

-- ── Downgrade: refused on seats (AC-R1-4). ─────────────────────────
INSERT INTO public.account_invitations (account_id, token_hash, role, expires_at)
SELECT current_setting('fx.c')::uuid, 'life-' || g, 'agent', now() + interval '1 day' FROM generate_series(1, 5) g;
SELECT throws_ok($$SELECT public.ent_schedule_change(current_setting('fx.c')::uuid, 'starter', 'op@test')$$, 'WA003', NULL, 'a downgrade with too many seats cannot be scheduled');
CREATE FUNCTION pg_temp.err(q text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE d text;
BEGIN
  EXECUTE q; RETURN '{}'::jsonb;
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS d = PG_EXCEPTION_DETAIL; RETURN d::jsonb;
END $$;
SELECT is(pg_temp.err($$SELECT public.ent_schedule_change(current_setting('fx.c')::uuid, 'starter', 'op@test')$$)->>'to_free', '1', 'the refusal says how many seats to free');
DELETE FROM public.account_invitations WHERE account_id = current_setting('fx.c')::uuid;

-- ── Scheduled downgrade: Growth → Starter (AC-D1, R4, R5, R7, R8, R9). ─
SELECT public.ent_set_plan(current_setting('fx.c')::uuid, 'growth', 'op@test');
-- a12 is the most recently updated, so the ids alone would pick wrongly.
INSERT INTO public.automations (id, user_id, account_id, name, trigger_type, is_active, updated_at)
SELECT ('42a00000-0000-4000-8000-0000000000' || lpad(g::text, 2, '0'))::uuid, '42000000-0000-4000-8000-00000000000c',
       current_setting('fx.c')::uuid, 'a' || g, 'keyword', true, now() - make_interval(hours => 13 - g)
FROM generate_series(1, 12) g;
INSERT INTO public.flows (id, user_id, account_id, name, trigger_type, status)
SELECT ('42f00000-0000-4000-8000-0000000000' || lpad(g::text, 2, '0'))::uuid, '42000000-0000-4000-8000-00000000000c',
       current_setting('fx.c')::uuid, 'f' || g, 'manual', 'active'
FROM generate_series(1, 4) g;
INSERT INTO public.flow_runs (flow_id, account_id, user_id, status)
SELECT '42f00000-0000-4000-8000-000000000004', current_setting('fx.c')::uuid, '42000000-0000-4000-8000-00000000000c', 'active';
INSERT INTO public.api_keys (account_id, name, key_prefix, key_hash) VALUES
  (current_setting('fx.c')::uuid, 'k1', 'p', 'life-h1'), (current_setting('fx.c')::uuid, 'k2', 'p', 'life-h2');
INSERT INTO public.webhook_endpoints (account_id, url, secret) VALUES
  (current_setting('fx.c')::uuid, 'https://x.test/1', 's'), (current_setting('fx.c')::uuid, 'https://x.test/2', 's');
INSERT INTO public.ai_configs (account_id, provider, model, api_key, auto_reply_enabled)
VALUES (current_setting('fx.c')::uuid, 'openai', 'm', 'k', true);
INSERT INTO public.contacts (id, user_id, account_id, phone, name) VALUES
  ('42c00000-0000-4000-8000-000000000001', '42000000-0000-4000-8000-00000000000c', current_setting('fx.c')::uuid, '15552000001', 'c');
INSERT INTO public.conversations (id, user_id, account_id, contact_id, ai_reply_count) VALUES
  ('42d00000-0000-4000-8000-000000000001', '42000000-0000-4000-8000-00000000000c', current_setting('fx.c')::uuid, '42c00000-0000-4000-8000-000000000001', 2);

SELECT is((public.ent_schedule_change(current_setting('fx.c')::uuid, 'starter', 'op@test')->>'applied'), 'scheduled', 'a downgrade is scheduled, not applied (REQ-D1)');
SELECT is((public.account_entitlements(current_setting('fx.c')::uuid)->>'plan'), 'growth', 'limits stay on the old plan until the date (AC-D1)');
SELECT is((SELECT count(*)::int FROM public.automations WHERE account_id = current_setting('fx.c')::uuid AND is_active), 12, 'nothing is deactivated yet');

UPDATE public.account_subscriptions SET scheduled_change_at = now() - interval '1 second' WHERE account_id = current_setting('fx.c')::uuid;
SELECT is((public.account_entitlements(current_setting('fx.c')::uuid)->>'plan'), 'starter', 'a due change takes effect lazily, before the sweep runs (REQ-S1)');

SELECT is((public.entitlements_run_due()->>'changes_applied'), '1', 'the sweep applies the due change');
SELECT is((SELECT plan_key FROM public.account_subscriptions WHERE account_id = current_setting('fx.c')::uuid), 'starter', 'the plan is materialised');
SELECT is(ARRAY(SELECT name FROM public.automations WHERE account_id = current_setting('fx.c')::uuid AND is_active ORDER BY substr(name, 2)::int),
  ARRAY['a8', 'a9', 'a10', 'a11', 'a12'], 'the 5 most recently updated automations stay active (AC-R4-2)');
SELECT is((SELECT count(*)::int FROM public.automations WHERE account_id = current_setting('fx.c')::uuid), 12, 'no automation is deleted');
SELECT is((SELECT count(*)::int FROM public.flows WHERE account_id = current_setting('fx.c')::uuid AND status = 'active'), 3, 'excess flows are deactivated (R5)');
SELECT is((SELECT status || '/' || end_reason FROM public.flow_runs WHERE flow_id = (SELECT id FROM public.flows WHERE account_id = current_setting('fx.c')::uuid AND status = 'draft' LIMIT 1)),
  'cancelled/flow_draft', 'a deactivated flow''s run ends as with a manual deactivation');
SELECT is((SELECT count(*)::int FROM public.api_keys WHERE account_id = current_setting('fx.c')::uuid AND plan_suspended_at IS NOT NULL AND revoked_at IS NULL), 2, 'both API keys are suspended, not revoked (AC-R7-2)');
SELECT is((SELECT count(*)::int FROM public.webhook_endpoints WHERE account_id = current_setting('fx.c')::uuid AND NOT is_active), 2, 'both webhooks are inactive and still listed (AC-R8-2)');
SELECT is((SELECT auto_reply_enabled FROM public.ai_configs WHERE account_id = current_setting('fx.c')::uuid), false, 'the bot is off (AC-R9-2)');
SELECT is((SELECT ai_autoreply_disabled AND ai_handoff_summary IS NOT NULL FROM public.conversations WHERE id = '42d00000-0000-4000-8000-000000000001'), true, 'its conversation is handed to a human');

-- Upgrade: immediate, and keys come back with no user action.
SELECT is((public.ent_schedule_change(current_setting('fx.c')::uuid, 'growth', 'op@test')->>'applied'), 'immediate', 'an upgrade applies at once (REQ-D1)');
SELECT is((SELECT count(*)::int FROM public.api_keys WHERE account_id = current_setting('fx.c')::uuid AND plan_suspended_at IS NULL), 2, 'upgrading restores the keys (AC-R7-2)');

-- ── Grace (D-10). ──────────────────────────────────────────────────
UPDATE public.account_subscriptions SET state = 'past_due', state_reason = NULL, state_changed_at = now() - interval '6 days' WHERE account_id = current_setting('fx.c')::uuid;
SELECT is((public.account_entitlements(current_setting('fx.c')::uuid)->>'state'), 'past_due', 'day 6 is still past_due');
UPDATE public.account_subscriptions SET state_changed_at = now() - interval '8 days' WHERE account_id = current_setting('fx.c')::uuid;
SELECT is((public.account_entitlements(current_setting('fx.c')::uuid)->>'state'), 'restricted', 'day 8 is restricted');
UPDATE public.account_subscriptions SET state_changed_at = now() - interval '22 days' WHERE account_id = current_setting('fx.c')::uuid;
SELECT is((public.account_entitlements(current_setting('fx.c')::uuid)->>'state'), 'locked', 'day 22 is locked');
SELECT public.entitlements_run_due();
SELECT is((SELECT state FROM public.account_subscriptions WHERE account_id = current_setting('fx.c')::uuid), 'locked', 'the sweep materialises it');

-- ── Metering arithmetic. ───────────────────────────────────────────
SELECT public.ent_set_state(current_setting('fx.c')::uuid, 'active', 'op@test');
SELECT public.ent_set_override(current_setting('fx.c')::uuid, '{"broadcast_recipients_per_period":50}'::jsonb, 'op@test');
SELECT is((SELECT granted || '/' || used FROM public.entitlement_consume(current_setting('fx.c')::uuid, 'broadcast_recipients', 40)), '40/40', 'a full grant');
SELECT is((SELECT granted || '/' || used || '/' || reason FROM public.entitlement_consume(current_setting('fx.c')::uuid, 'broadcast_recipients', 40)), '10/50/limit', 'a partial grant at the limit');
SELECT is((SELECT public.entitlement_release(current_setting('fx.c')::uuid, 'broadcast_recipients', period_start, 5)
           FROM public.entitlement_consume(current_setting('fx.c')::uuid, 'broadcast_recipients', 0)), 45::bigint, 'release refunds failures (AC-R3-2)');
SELECT public.ent_set_state(current_setting('fx.c')::uuid, 'restricted', 'op@test');
SELECT is((SELECT granted || '/' || reason FROM public.entitlement_consume(current_setting('fx.c')::uuid, 'broadcast_recipients', 1)), '0/account_restricted', 'restricted gets no allowance');

-- ── Switch on, off, on keeps everything (AC-H3). ───────────────────
SELECT set_config('fx.before', (public.account_entitlements(current_setting('fx.c')::uuid)->>'plan') || '/' || (public.account_entitlements(current_setting('fx.c')::uuid)->>'state') || '/' || (public.account_usage(current_setting('fx.c')::uuid)->>'broadcast_recipients'), true);
SELECT public.entitlements_set_enabled(false, 'op@test');
SELECT public.entitlements_set_enabled(true, 'op@test');
SELECT is((public.account_entitlements(current_setting('fx.c')::uuid)->>'plan') || '/' || (public.account_entitlements(current_setting('fx.c')::uuid)->>'state') || '/' || (public.account_usage(current_setting('fx.c')::uuid)->>'broadcast_recipients'),
  current_setting('fx.before'), 'plan, state and usage survive the switch');
SELECT is((SELECT entitlements_first_enabled_at::text FROM public.platform_settings), current_setting('fx.go_live'), 'the go-live stamp is not moved');

-- ── Legacy cut-over (REQ-G2/G3, AC-G3). ────────────────────────────
SELECT is((public.account_entitlements(current_setting('fx.a')::uuid)->>'state'), 'active', 'with no cut-over date legacy stays active (AC-G3)');
UPDATE public.platform_settings SET legacy_ends_at = now() - interval '1 second';
SELECT is((public.account_entitlements(current_setting('fx.a')::uuid)->>'state'), 'locked', 'past the cut-over an account with no plan is locked (REQ-G3)');

-- ── A claim outlives the account that made it (REQ-T2). ────────────
DELETE FROM public.accounts WHERE id = current_setting('fx.a')::uuid;
SELECT is((SELECT count(*)::int FROM public.trial_number_claims WHERE phone_number_id = 'PN-1' AND first_account_id IS NULL), 1, 'the claim survives the account''s deletion');

SELECT * FROM finish();
ROLLBACK;
