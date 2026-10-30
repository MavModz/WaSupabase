-- ============================================================
-- Entitlements enforcement (migration 068) — `supabase test db`
-- ============================================================
-- Each limit blocks at its limit and works again below it, on the path
-- a browser actually uses (`authenticated` under RLS, REQ-X3). The
-- inbound webhook is exempt and a spoofed header is not. Limits are
-- lowered with per-account overrides so no test needs 5,000 rows.
-- Concurrency is in supabase/ci/entitlements-concurrency.sh, because
-- pgTAP runs on a single session. Rolled back at the end.
--
--   A = owner of the account under test      D = invitee
-- ============================================================
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(58);

INSERT INTO auth.users (instance_id, id, aud, role, email, raw_user_meta_data, created_at, updated_at) VALUES
  ('00000000-0000-0000-0000-000000000000', '41000000-0000-4000-8000-00000000000a', 'authenticated', 'authenticated', 'enf-a@example.test', '{"full_name":"A"}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '41000000-0000-4000-8000-00000000000d', 'authenticated', 'authenticated', 'enf-d@example.test', '{"full_name":"D"}', now(), now());
SELECT set_config('fx.a', (SELECT account_id::text FROM public.profiles WHERE user_id = '41000000-0000-4000-8000-00000000000a'), true);

-- Runs SQL as authenticated and returns the error's DETAIL as jsonb.
-- Called as postgres: the role switch is inside, because a temp
-- function's schema is not usable by the API roles.
CREATE FUNCTION pg_temp.err(q text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE d text;
BEGIN
  PERFORM set_config('role', 'authenticated', true);
  EXECUTE q;
  PERFORM set_config('role', 'postgres', true);
  RETURN '{"none":true}'::jsonb;
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS d = PG_EXCEPTION_DETAIL;
  PERFORM set_config('role', 'postgres', true);
  RETURN coalesce(nullif(d, '')::jsonb, '{}'::jsonb);
END $$;

-- ── Switch off: nothing is enforced (REQ-H2). ──────────────────────
SELECT is((SELECT count(*)::int FROM pg_trigger WHERE tgname LIKE 'ent\_%' AND NOT tgisinternal AND tgenabled <> 'D'), 0,
  'enforcement triggers ship disabled');
SELECT public.ent_set_override(current_setting('fx.a')::uuid, '{"contacts_max":1}'::jsonb, 'test');
SELECT lives_ok($$INSERT INTO public.contacts (user_id, account_id, phone, name)
  SELECT '41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, '1555100000' || g, 'off' FROM generate_series(1, 3) g$$,
  'with the switch off an account can exceed its limit (AC-H2)');
DELETE FROM public.contacts WHERE account_id = current_setting('fx.a')::uuid;
SELECT public.ent_set_override(current_setting('fx.a')::uuid, '{"contacts_max":null}'::jsonb, 'test');

-- ── Switch on, account A on Starter. ───────────────────────────────
SELECT public.entitlements_set_enabled(true, 'test');
SELECT public.ent_set_plan(current_setting('fx.a')::uuid, 'starter', 'test');
SELECT is((SELECT count(*)::int FROM pg_trigger WHERE tgname LIKE 'ent\_%' AND NOT tgisinternal AND tgenabled = 'O'), 15,
  'turning the switch on enables every enforcement trigger');

SELECT public.ent_set_override(current_setting('fx.a')::uuid,
  '{"contacts_max":2,"seats_max":2,"broadcast_recipients_per_period":100,"automations_active_max":1,"automations_total_max":2,"flows_active_max":1,"flows_total_max":2,"pipelines_max":0}'::jsonb, 'test');

SELECT set_config('fx.as_a', '{"sub":"41000000-0000-4000-8000-00000000000a","role":"authenticated"}', true);
SELECT set_config('request.jwt.claims', current_setting('fx.as_a'), true);

-- ── Contacts (R2). ─────────────────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT lives_ok($$INSERT INTO public.contacts (id, user_id, account_id, phone, name) VALUES
  ('41c00000-0000-4000-8000-000000000001', '41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, '15551000001', 'c1')$$, 'contact below the limit works');
SELECT lives_ok($$INSERT INTO public.contacts (user_id, account_id, phone, name) VALUES
  ('41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, '15551000002', 'c2')$$, 'contact up to the limit works');
SELECT throws_ok($$INSERT INTO public.contacts (user_id, account_id, phone, name) VALUES
  ('41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, '15551000003', 'c3')$$, 'WA001', NULL, 'contact at the limit is blocked for a browser write (REQ-X3)');
RESET ROLE;
SELECT is(pg_temp.err($$INSERT INTO public.contacts (user_id, account_id, phone, name) VALUES
  ('41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, '15551000003', 'c3')$$),
  '{"code":"plan_limit_reached","resource":"contacts","usage":2,"limit":2}'::jsonb, 'the error carries code, resource, usage and limit (REQ-X6)');
SELECT is(pg_temp.err($$INSERT INTO public.contacts (user_id, account_id, phone, name)
  SELECT '41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, '155520000' || g, 'b' FROM generate_series(10, 14) g$$)->>'usage',
  '2', 'a batch reports usage before the statement, not after it');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$UPDATE public.contacts SET name = 'edited' WHERE id = '41c00000-0000-4000-8000-000000000001'$$, 'editing a contact at the limit works');
SELECT set_config('request.headers', '{"x-wacrm-inbound":"1"}', true);
SELECT throws_ok($$INSERT INTO public.contacts (user_id, account_id, phone, name) VALUES
  ('41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, '15551000004', 'spoof')$$, 'WA001', NULL, 'a browser cannot spoof the inbound header');
SELECT throws_ok($$SELECT public.ent_create_inbound_contact('{"account_id":"x"}'::jsonb)$$, '42501', NULL, 'a browser cannot call the fallback RPC');
RESET ROLE;

-- Service role + header = the webhook: exempt, even over the limit.
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
SET LOCAL ROLE service_role;
SELECT lives_ok($$INSERT INTO public.contacts (user_id, account_id, phone, name) VALUES
  ('41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, '15551000005', 'inbound')$$, 'an inbound contact is created at the limit (AC-R2-2)');
SELECT is((SELECT count(*)::int FROM public.contacts WHERE account_id = current_setting('fx.a')::uuid), 3, 'the account is now over its limit');
SELECT is((SELECT name FROM public.ent_create_inbound_contact(jsonb_build_object('user_id', '41000000-0000-4000-8000-00000000000a', 'account_id', current_setting('fx.a'), 'phone', '15551000008', 'name', 'rpc'))),
  'rpc', 'the RPC fallback creates an inbound contact over the limit, without the header');
SELECT is(current_setting('wacrm.inbound_contact', true), '', 'the fallback does not leave its exemption behind');
DELETE FROM public.contacts WHERE phone = '15551000008';
SELECT set_config('request.headers', '', true);
SELECT throws_ok($$INSERT INTO public.contacts (user_id, account_id, phone, name) VALUES
  ('41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, '15551000006', 'api')$$, 'WA001', NULL, 'the service role without the header is blocked (v1 API path)');
RESET ROLE;

SELECT set_config('request.jwt.claims', current_setting('fx.as_a'), true);
SET LOCAL ROLE authenticated;
DELETE FROM public.contacts WHERE account_id = current_setting('fx.a')::uuid AND phone IN ('15551000002', '15551000005');
SELECT lives_ok($$INSERT INTO public.contacts (user_id, account_id, phone, name) VALUES
  ('41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, '15551000007', 'again')$$, 'deleting below the limit frees it (AC-R2-4)');

-- ── Seats (R1): 1 member, max 2. ───────────────────────────────────
SELECT lives_ok($$INSERT INTO public.account_invitations (id, account_id, token_hash, role, expires_at) VALUES
  ('41100000-0000-4000-8000-000000000001', current_setting('fx.a')::uuid, 'h1', 'agent', now() + interval '1 day')$$, 'an invite within the seat maximum works');
RESET ROLE;
SELECT is(pg_temp.err($$INSERT INTO public.account_invitations (account_id, token_hash, role, expires_at) VALUES
  (current_setting('fx.a')::uuid, 'h2', 'agent', now() + interval '1 day')$$),
  '{"code":"plan_limit_reached","resource":"seats","usage":2,"limit":2}'::jsonb, 'a pending invite counts as a seat (AC-R1-2)');
SET LOCAL ROLE authenticated;
DELETE FROM public.account_invitations WHERE id = '41100000-0000-4000-8000-000000000001';
SELECT lives_ok($$INSERT INTO public.account_invitations (id, account_id, token_hash, role, expires_at) VALUES
  ('41100000-0000-4000-8000-000000000002', current_setting('fx.a')::uuid, 'h3', 'agent', now() + interval '1 day')$$, 'revoking an invite frees the seat immediately');
RESET ROLE;

-- Redeem at the maximum: refused, and the invite stays valid (AC-R1-3).
SELECT public.ent_set_override(current_setting('fx.a')::uuid, '{"seats_max":1}'::jsonb, 'test');
SELECT set_config('request.jwt.claims', '{"sub":"41000000-0000-4000-8000-00000000000d","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT public.redeem_invitation('h3')$$, 'WA001', NULL, 'redeeming at the seat maximum is refused');
RESET ROLE;
SELECT is((SELECT accepted_at FROM public.account_invitations WHERE id = '41100000-0000-4000-8000-000000000002'), NULL::timestamptz, 'the refused invite stays unaccepted');
SELECT public.ent_set_override(current_setting('fx.a')::uuid, '{"seats_max":2}'::jsonb, 'test');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$SELECT public.redeem_invitation('h3')$$, 'the same invite redeems once a seat is free');
RESET ROLE;
SELECT is((SELECT count(*)::int FROM public.profiles WHERE account_id = current_setting('fx.a')::uuid), 2, 'the invitee joined the account');
SELECT set_config('request.jwt.claims', current_setting('fx.as_a'), true);

-- ── Automations (R4): active 1, total 2. ───────────────────────────
SET LOCAL ROLE authenticated;
SELECT lives_ok($$INSERT INTO public.automations (id, user_id, account_id, name, trigger_type, is_active) VALUES
  ('41a00000-0000-4000-8000-000000000001', '41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, 'a1', 'keyword', true)$$, 'first active automation works');
RESET ROLE;
SELECT is(pg_temp.err($$INSERT INTO public.automations (user_id, account_id, name, trigger_type, is_active) VALUES
  ('41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, 'a2', 'keyword', true)$$)->>'resource',
  'automations_active', 'creating an active automation at the limit is blocked');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$INSERT INTO public.automations (id, user_id, account_id, name, trigger_type, is_active) VALUES
  ('41a00000-0000-4000-8000-000000000002', '41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, 'a2', 'keyword', false)$$, 'an inactive automation does not count as active');
RESET ROLE;
SELECT is(pg_temp.err($$INSERT INTO public.automations (user_id, account_id, name, trigger_type, is_active) VALUES
  ('41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, 'a3', 'keyword', false)$$)->>'resource',
  'automations_total', 'the fair-use total blocks even an inactive one (AC-R4-4)');
SET LOCAL ROLE authenticated;
SELECT throws_ok($$UPDATE public.automations SET is_active = true WHERE id = '41a00000-0000-4000-8000-000000000002'$$, 'WA001', NULL, 'activating a second automation is blocked (AC-R4-1)');
SELECT lives_ok($$UPDATE public.automations SET name = 'edited' WHERE id = '41a00000-0000-4000-8000-000000000001'$$, 'editing an active automation at the limit works');
SELECT lives_ok($$UPDATE public.automations SET is_active = false WHERE id = '41a00000-0000-4000-8000-000000000001'$$, 'deactivating works');
SELECT lives_ok($$UPDATE public.automations SET is_active = true WHERE id = '41a00000-0000-4000-8000-000000000002'$$, 'activating works again after deactivating another');

-- ── Flows (R5): active 1, total 2. ─────────────────────────────────
SELECT lives_ok($$INSERT INTO public.flows (id, user_id, account_id, name, trigger_type, status) VALUES
  ('41f00000-0000-4000-8000-000000000001', '41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, 'f1', 'manual', 'active')$$, 'first active flow works');
SELECT lives_ok($$INSERT INTO public.flows (id, user_id, account_id, name, trigger_type, status) VALUES
  ('41f00000-0000-4000-8000-000000000002', '41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, 'f2', 'manual', 'draft')$$, 'a draft flow does not count as active');
RESET ROLE;
SELECT is(pg_temp.err($$UPDATE public.flows SET status = 'active' WHERE id = '41f00000-0000-4000-8000-000000000002'$$)->>'resource',
  'flows_active', 'activating a second flow is blocked');
SELECT is(pg_temp.err($$INSERT INTO public.flows (user_id, account_id, name, trigger_type) VALUES
  ('41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, 'f3', 'manual')$$)->>'resource',
  'flows_total', 'the flow fair-use total applies');

-- ── Pipelines (R11): override 0. ───────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT throws_ok($$INSERT INTO public.pipelines (user_id, account_id, name) VALUES
  ('41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, 'p')$$, 'WA001', NULL, 'creating a pipeline at the limit is blocked (AC-R11-1)');
RESET ROLE;

-- ── API keys and webhooks on Starter: 0 means not on the plan. ─────
SELECT is(pg_temp.err($$INSERT INTO public.api_keys (account_id, name, key_prefix, key_hash) VALUES
  (current_setting('fx.a')::uuid, 'k', 'p', 'hash1')$$)->>'code',
  'plan_feature_unavailable', 'Starter cannot create an API key (AC-R7-1)');
SELECT is(pg_temp.err($$INSERT INTO public.webhook_endpoints (account_id, url, secret) VALUES
  (current_setting('fx.a')::uuid, 'https://x.test/h', 's')$$)->>'code',
  'plan_feature_unavailable', 'Starter cannot create a webhook endpoint');

-- ── AI (R9). ───────────────────────────────────────────────────────
SELECT is(pg_temp.err($$INSERT INTO public.ai_configs (account_id, provider, model, api_key, auto_reply_enabled) VALUES
  (current_setting('fx.a')::uuid, 'openai', 'm', 'k', true)$$)->>'code',
  'plan_feature_unavailable', 'Starter cannot enable auto-reply (AC-R9-1)');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$INSERT INTO public.ai_configs (account_id, provider, model, api_key) VALUES
  (current_setting('fx.a')::uuid, 'openai', 'm', 'k')$$, 'AI drafts config without the bot still saves');
SELECT throws_ok($$UPDATE public.ai_configs SET auto_reply_enabled = true WHERE account_id = current_setting('fx.a')::uuid$$, 'WA002', NULL, 'turning the bot on later is blocked too');
SELECT throws_ok($$INSERT INTO public.ai_knowledge_documents (account_id, title, content) VALUES
  (current_setting('fx.a')::uuid, 't', 'c')$$, 'WA001', NULL, 'Starter has no knowledge base documents');
RESET ROLE;

-- ── Over a raised limit, and the plan_suspended_at guard. ──────────
SELECT public.ent_set_override(current_setting('fx.a')::uuid, '{"api_keys_max":1,"webhook_endpoints_max":1,"kb_documents_max":1}'::jsonb, 'test');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$INSERT INTO public.api_keys (id, account_id, name, key_prefix, key_hash) VALUES
  ('41b00000-0000-4000-8000-000000000001', current_setting('fx.a')::uuid, 'k', 'p', 'hash2')$$, 'a key within the limit works');
SELECT throws_ok($$INSERT INTO public.api_keys (account_id, name, key_prefix, key_hash) VALUES
  (current_setting('fx.a')::uuid, 'k2', 'p', 'hash3')$$, 'WA001', NULL, 'a second key is blocked');
UPDATE public.api_keys SET plan_suspended_at = now() WHERE id = '41b00000-0000-4000-8000-000000000001';
SELECT is((SELECT plan_suspended_at FROM public.api_keys WHERE id = '41b00000-0000-4000-8000-000000000001'), NULL::timestamptz, 'a client cannot set plan_suspended_at');
SELECT lives_ok($$INSERT INTO public.webhook_endpoints (id, account_id, url, secret) VALUES
  ('41e00000-0000-4000-8000-000000000001', current_setting('fx.a')::uuid, 'https://x.test/1', 's')$$, 'a webhook within the limit works');
SELECT throws_ok($$INSERT INTO public.webhook_endpoints (account_id, url, secret) VALUES
  (current_setting('fx.a')::uuid, 'https://x.test/2', 's')$$, 'WA001', NULL, 'a second webhook is blocked (AC-R8-1)');
RESET ROLE;

-- ── Broadcast pre-flight (R3): 100 per period. ─────────────────────
SELECT is((SELECT granted FROM public.entitlement_consume(current_setting('fx.a')::uuid, 'broadcast_recipients', 95)), 95, 'metering reserves within the allowance');
SELECT is(pg_temp.err($$INSERT INTO public.broadcasts (user_id, account_id, name, template_name, status, total_recipients) VALUES
  ('41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, 'b', 't', 'sending', 6)$$) - 'resets_at',
  '{"code":"plan_limit_reached","resource":"broadcast_recipients","usage":95,"limit":100,"requested":6,"remaining":5}'::jsonb,
  'a broadcast over the remaining allowance is refused before sending (AC-R3-1)');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$INSERT INTO public.broadcasts (user_id, account_id, name, template_name, status, total_recipients) VALUES
  ('41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, 'b', 't', 'sending', 5)$$, 'a broadcast within the remaining allowance starts');
SELECT lives_ok($$INSERT INTO public.broadcasts (user_id, account_id, name, template_name, status, total_recipients) VALUES
  ('41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, 'b', 't', 'draft', 500)$$, 'a draft is not metered');
RESET ROLE;

-- ── States (section 7). ────────────────────────────────────────────
SELECT public.ent_set_override(current_setting('fx.a')::uuid, '{"contacts_max":100}'::jsonb, 'test');
SELECT public.ent_set_state(current_setting('fx.a')::uuid, 'past_due', 'test');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$INSERT INTO public.contacts (user_id, account_id, phone, name) VALUES
  ('41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, '15551000010', 'pd')$$, 'past_due still creates');
RESET ROLE;
SELECT public.ent_set_state(current_setting('fx.a')::uuid, 'restricted', 'test');
SELECT is(pg_temp.err($$INSERT INTO public.contacts (user_id, account_id, phone, name) VALUES
  ('41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, '15551000011', 'r')$$),
  '{"code":"plan_feature_unavailable","resource":"contacts","reason":"account_restricted"}'::jsonb, 'restricted refuses creation with a reason');
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
SELECT set_config('request.headers', '{"x-wacrm-inbound":"1"}', true);
SET LOCAL ROLE service_role;
SELECT lives_ok($$INSERT INTO public.contacts (user_id, account_id, phone, name) VALUES
  ('41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, '15551000012', 'inbound')$$, 'inbound contacts are still created while restricted (REQ-X11)');
RESET ROLE;
SELECT public.ent_set_state(current_setting('fx.a')::uuid, 'locked', 'test');
SET LOCAL ROLE service_role;
SELECT lives_ok($$INSERT INTO public.contacts (user_id, account_id, phone, name) VALUES
  ('41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, '15551000013', 'inbound')$$, 'inbound contacts are still created while locked (REQ-X11)');
RESET ROLE;
SELECT set_config('request.headers', '', true);
SELECT set_config('request.jwt.claims', current_setting('fx.as_a'), true);
SELECT is(pg_temp.err($$INSERT INTO public.contacts (user_id, account_id, phone, name) VALUES
  ('41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, '15551000014', 'l')$$)->>'reason',
  'account_locked', 'locked refuses creation with a reason');

-- ── Switch off again: enforcement stops at once (AC-H2). ───────────
SELECT public.entitlements_set_enabled(false, 'test');
SET LOCAL ROLE authenticated;
SELECT lives_ok($$INSERT INTO public.contacts (user_id, account_id, phone, name) VALUES
  ('41000000-0000-4000-8000-00000000000a', current_setting('fx.a')::uuid, '15551000015', 'off')$$, 'with the switch off a locked account can create again');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
