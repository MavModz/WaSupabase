-- ============================================================
-- Entitlements configuration (migration 066) — `supabase test db`
-- ============================================================
-- The seed matches the approved plan table (D-02, D-05, D-09, D-14),
-- REQ-X2 holds at the schema level, a currency is a configuration
-- change (REQ-C1), and clients can read the catalogue but not write
-- it. Rolled back at the end.
-- ============================================================
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(27);

-- ── Seed: seats inc/max, contacts, broadcast, automations active/total,
--    flows active/total, numbers, keys, rate, webhooks, drafts, bot, kb,
--    storage GB, pipelines. ─────────────────────────────────────────
CREATE TEMP TABLE seed_view ON COMMIT DROP AS
SELECT key, concat_ws('|', seats_included, seats_max, contacts_max, broadcast_recipients_per_period,
         automations_active_max, automations_total_max, flows_active_max, flows_total_max,
         whatsapp_numbers_max, api_keys_max, api_rate_per_minute, webhook_endpoints_max,
         ai_drafts, ai_auto_reply, kb_documents_max, storage_bytes_max / 1073741824, pipelines_max) AS v
FROM public.plans;

SELECT is((SELECT v FROM seed_view WHERE key = 'trial'),
  '3|3|1000|500|3|30|2|20|1|1|60|1|t|t|10|1|2', 'trial quantities match D-09');
SELECT is((SELECT v FROM seed_view WHERE key = 'starter'),
  '2|5|5000|10000|5|50|3|30|1|0|0|0|t|f|0|2|2', 'starter limits match D-05 and D-14');
SELECT is((SELECT v FROM seed_view WHERE key = 'growth'),
  '5|25|25000|100000|25|250|15|150|1|3|120|3|t|t|50|10|10', 'growth limits match D-05');
SELECT is((SELECT v FROM seed_view WHERE key = 'pro'),
  '10|100|100000|500000|100|1000|50|500|1|20|600|10|t|t|500|50|100', 'pro limits match D-05');
SELECT is((SELECT v FROM seed_view WHERE key = 'legacy_beta'),
  (SELECT v FROM seed_view WHERE key = 'pro'), 'legacy_beta carries Pro limits (D-12)');

-- ── Prices (paise, exclusive of tax). ──────────────────────────────
SELECT is((SELECT amount_minor FROM public.plan_prices WHERE plan_key='starter' AND currency='INR' AND interval='month' AND kind='base'), 149900::bigint, 'Starter is ₹1,499 a month');
SELECT is((SELECT amount_minor FROM public.plan_prices WHERE plan_key='growth' AND currency='INR' AND interval='month' AND kind='base'), 349900::bigint, 'Growth is ₹3,499 a month');
SELECT is((SELECT amount_minor FROM public.plan_prices WHERE plan_key='pro' AND currency='INR' AND interval='month' AND kind='base'), 799900::bigint, 'Pro is ₹7,999 a month');
SELECT is((SELECT amount_minor FROM public.plan_prices WHERE plan_key='growth' AND currency='INR' AND interval='year' AND kind='base'), 3499000::bigint, 'Growth annual is ₹34,990 (D-06)');
SELECT is((SELECT amount_minor FROM public.plan_prices WHERE plan_key='pro' AND currency='INR' AND interval='month' AND kind='extra_seat'), 89900::bigint, 'Pro extra seat is ₹899');
SELECT is(ARRAY(SELECT code::text FROM public.currencies WHERE enabled ORDER BY code), ARRAY['INR'], 'INR is the only enabled currency (D-01)');

-- ── REQ-X2: no plan can hold a missing, negative or unlimited limit. ─
SELECT is(
  (SELECT count(*)::int FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'plans' AND is_nullable = 'YES'),
  0, 'every plan column is NOT NULL');
SELECT throws_ok($$UPDATE public.plans SET contacts_max = -1 WHERE key = 'starter'$$, '23514', NULL, 'a negative limit is rejected');
SELECT throws_ok($$UPDATE public.plans SET contacts_max = NULL WHERE key = 'starter'$$, '23502', NULL, 'a missing limit is rejected');
SELECT throws_ok($$UPDATE public.plans SET seats_included = 500 WHERE key = 'starter'$$, '23514', NULL, 'included seats cannot exceed the maximum');

-- ── REQ-C1: a new currency is rows, no schema change. ──────────────
INSERT INTO public.currencies (code, minor_unit, enabled) VALUES ('EUR', 2, true);
INSERT INTO public.plan_prices (plan_key, currency, interval, kind, amount_minor)
SELECT key, 'EUR', 'month', 'base', 1000 * sort_order FROM public.plans WHERE is_customer_plan;
SELECT is((SELECT count(*)::int FROM public.plan_prices WHERE currency = 'EUR'), 3, 'a test currency reads back a price per customer plan');

-- ── Grants. ────────────────────────────────────────────────────────
INSERT INTO auth.users (instance_id, id, aud, role, email, raw_user_meta_data, created_at, updated_at) VALUES
  ('00000000-0000-0000-0000-000000000000', '40000000-0000-4000-8000-00000000000a', 'authenticated', 'authenticated', 'cfg-a@example.test', '{"full_name":"A"}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '40000000-0000-4000-8000-00000000000b', 'authenticated', 'authenticated', 'cfg-b@example.test', '{"full_name":"B"}', now(), now());
SELECT set_config('fx.a', (SELECT account_id::text FROM public.profiles WHERE user_id = '40000000-0000-4000-8000-00000000000a'), true);
SELECT set_config('fx.b', (SELECT account_id::text FROM public.profiles WHERE user_id = '40000000-0000-4000-8000-00000000000b'), true);

SELECT is((SELECT plan_key || '/' || state FROM public.account_subscriptions WHERE account_id = current_setting('fx.a')::uuid),
  'legacy_beta/active', 'an account created before go-live is on legacy_beta (AC-G1)');

SELECT set_config('request.jwt.claims', '{"sub":"40000000-0000-4000-8000-00000000000a","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

SELECT is((SELECT count(*)::int FROM public.plans), 5, 'a member can read the plan catalogue');
SELECT is((SELECT count(*)::int FROM public.account_subscriptions), 1, 'a member sees only their own subscription');
SELECT is((SELECT count(*)::int FROM public.account_subscriptions WHERE account_id = current_setting('fx.b')::uuid), 0, 'another account''s subscription is invisible');
SELECT throws_ok($$UPDATE public.plans SET contacts_max = 999999 WHERE key = 'starter'$$, '42501', NULL, 'a client cannot change a plan');
SELECT throws_ok($$UPDATE public.account_subscriptions SET plan_key = 'pro'$$, '42501', NULL, 'a client cannot change its subscription');
SELECT throws_ok($$INSERT INTO public.account_usage_counters (account_id, resource, period_start) VALUES (current_setting('fx.a')::uuid, 'broadcast_recipients', now())$$, '42501', NULL, 'a client cannot write usage counters');
SELECT throws_ok($$SELECT * FROM public.platform_settings$$, '42501', NULL, 'a client cannot read platform_settings');
SELECT throws_ok($$SELECT * FROM public.entitlement_audit_log$$, '42501', NULL, 'a client cannot read the audit log');
SELECT throws_ok($$SELECT * FROM public.trial_number_claims$$, '42501', NULL, 'a client cannot read trial claims');
SELECT throws_ok($$INSERT INTO public.plan_prices (plan_key, currency, interval, kind, amount_minor) VALUES ('pro','INR','month','base',1)$$, '42501', NULL, 'a client cannot write prices');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
