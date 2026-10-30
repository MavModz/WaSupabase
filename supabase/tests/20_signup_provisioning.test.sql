-- ============================================================
-- Signup provisioning (migration 064) — run with `supabase test db`
-- ============================================================
-- handle_new_user must provision every new auth user (email or
-- phone-only), must never block a signup when provisioning fails but
-- record the failure, and ensure_my_account() must heal such a user
-- without ever moving a user who already has a profile.
-- Everything runs in one transaction and is rolled back.
-- ============================================================
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(23);

-- Force a provisioning failure for one user only: a BEFORE INSERT
-- trigger on profiles that raises for that user id. Dropped again
-- before the self-heal step.
CREATE FUNCTION public.__test_fail_profile_insert() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.user_id = '64000000-0000-4000-8000-000000000005' THEN
    RAISE EXCEPTION 'forced provisioning failure';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER __test_fail_profile_insert BEFORE INSERT ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.__test_fail_profile_insert();

-- ── Fixture users ─────────────────────────────────────────────
--  …01 email + name       …02 email, no name
--  …03 phone-only         …04 phone-only (second, distinct phone)
--  …05 phone-only, provisioning forced to fail
--  …06 account owner      …07 member moved into …06's account
--  …08 user whose profile is later deleted (orphaned own account)
INSERT INTO auth.users (instance_id, id, aud, role, email, phone, raw_user_meta_data, created_at, updated_at)
VALUES
  ('00000000-0000-0000-0000-000000000000', '64000000-0000-4000-8000-000000000001',
   'authenticated', 'authenticated', 'email-one@example.test', NULL, '{"full_name":"Email One"}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '64000000-0000-4000-8000-000000000002',
   'authenticated', 'authenticated', 'no-name@example.test', NULL, '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '64000000-0000-4000-8000-000000000003',
   'authenticated', 'authenticated', NULL, '15550001001', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '64000000-0000-4000-8000-000000000004',
   'authenticated', 'authenticated', NULL, '15550001002', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '64000000-0000-4000-8000-000000000005',
   'authenticated', 'authenticated', NULL, '15550001003', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '64000000-0000-4000-8000-000000000006',
   'authenticated', 'authenticated', 'owner@example.test', NULL, '{"full_name":"Owner"}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '64000000-0000-4000-8000-000000000007',
   'authenticated', 'authenticated', 'member@example.test', NULL, '{"full_name":"Member"}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '64000000-0000-4000-8000-000000000008',
   'authenticated', 'authenticated', 'orphan@example.test', NULL, '{"full_name":"Orphan"}', now(), now());

-- ── Email users: unchanged behaviour ──────────────────────────
SELECT is(
  (SELECT full_name || '|' || email || '|' || coalesce(phone, 'null') || '|' || account_role::text
   FROM public.profiles WHERE user_id = '64000000-0000-4000-8000-000000000001'),
  'Email One|email-one@example.test|null|owner',
  'email user: profile keeps name and email, no phone, owner role');
SELECT is(
  (SELECT p.full_name || '|' || a.name FROM public.profiles p JOIN public.accounts a ON a.id = p.account_id
   WHERE p.user_id = '64000000-0000-4000-8000-000000000002'),
  '|no-name@example.test',
  'email user without a name: empty full_name, account named after the email');

-- ── Phone-only users ──────────────────────────────────────────
SELECT is(
  (SELECT count(*)::int FROM public.profiles
   WHERE user_id IN ('64000000-0000-4000-8000-000000000003', '64000000-0000-4000-8000-000000000004')),
  2,
  'two phone-only users (email NULL) both get a profile');
SELECT is(
  (SELECT count(DISTINCT account_id)::int FROM public.profiles
   WHERE user_id IN ('64000000-0000-4000-8000-000000000003', '64000000-0000-4000-8000-000000000004')),
  2,
  'each phone-only user owns a separate account');
SELECT is(
  (SELECT p.email || '|' || p.phone || '|' || p.full_name || '|' || a.name || '|' || (a.owner_user_id = p.user_id)::text
   FROM public.profiles p JOIN public.accounts a ON a.id = p.account_id
   WHERE p.user_id = '64000000-0000-4000-8000-000000000003'),
  '|+15550001001|+15550001001|+15550001001|true',
  'phone-only user: email stored as empty string, phone/full_name/account name from the E.164 phone');
SELECT is(
  (SELECT phone FROM public.profiles WHERE user_id = '64000000-0000-4000-8000-000000000004'),
  '+15550001002',
  'second phone-only user carries its own phone');

-- ── Swallowed failure is recorded, signup not blocked ─────────
SELECT isnt_empty(
  $$SELECT 1 FROM auth.users WHERE id = '64000000-0000-4000-8000-000000000005'$$,
  'a provisioning failure does not block the auth user insert');
SELECT is_empty(
  $$SELECT 1 FROM public.profiles WHERE user_id = '64000000-0000-4000-8000-000000000005'$$,
  'the failed user has no profile');
SELECT is_empty(
  $$SELECT 1 FROM public.accounts WHERE owner_user_id = '64000000-0000-4000-8000-000000000005'$$,
  'the failed user has no half-created account (sub-transaction rolled back)');
SELECT is(
  (SELECT sqlstate || '|' || message FROM public.signup_provisioning_failures
   WHERE user_id = '64000000-0000-4000-8000-000000000005' AND resolved_at IS NULL),
  'P0001|forced provisioning failure',
  'the failure is recorded with its SQLSTATE and message');

DROP TRIGGER __test_fail_profile_insert ON public.profiles;
DROP FUNCTION public.__test_fail_profile_insert();

-- Fixture state, as the migration owner: …07 joins …06's account as
-- an agent; …08 loses its profile but keeps the account it owns.
UPDATE public.profiles
SET account_id = (SELECT account_id FROM public.profiles WHERE user_id = '64000000-0000-4000-8000-000000000006'),
    account_role = 'agent'
WHERE user_id = '64000000-0000-4000-8000-000000000007';
SELECT set_config('fx.orphan_acct',
  (SELECT account_id::text FROM public.profiles WHERE user_id = '64000000-0000-4000-8000-000000000008'), true);
DELETE FROM public.profiles WHERE user_id = '64000000-0000-4000-8000-000000000008';

-- ── Grants ────────────────────────────────────────────────────
SET LOCAL ROLE anon;
SELECT throws_ok($$SELECT public.ensure_my_account()$$, '42501', NULL,
  'anon cannot execute ensure_my_account');
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"64000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
SELECT throws_ok($$SELECT * FROM public.signup_provisioning_failures$$, '42501', NULL,
  'authenticated cannot read the failure log');
SELECT throws_ok($$SELECT public.provision_personal_account('64000000-0000-4000-8000-000000000003')$$, '42501', NULL,
  'authenticated cannot call provision_personal_account directly');
SELECT throws_ok($$UPDATE public.profiles SET phone = '+19999999999' WHERE user_id = auth.uid()$$, '42501', NULL,
  'a user cannot overwrite the phone copy on their own profile');
SELECT lives_ok($$UPDATE public.profiles SET full_name = 'Phone Person' WHERE user_id = auth.uid()$$,
  'a phone user can still edit their own name');

-- ── Self-heal the failed phone-only user ──────────────────────
SELECT set_config('request.jwt.claims', '{"sub":"64000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
SELECT set_config('fx.healed', public.ensure_my_account()::text, true);
RESET ROLE;

SELECT is(
  (SELECT p.account_role::text || '|' || p.phone || '|' || p.email || '|' || (a.owner_user_id = p.user_id)::text
   FROM public.profiles p JOIN public.accounts a ON a.id = p.account_id
   WHERE p.user_id = '64000000-0000-4000-8000-000000000005' AND p.account_id = current_setting('fx.healed')::uuid),
  'owner|+15550001003||true',
  'ensure_my_account provisions the failed phone-only user as owner of a new account');
SELECT is_empty(
  $$SELECT 1 FROM public.signup_provisioning_failures
    WHERE user_id = '64000000-0000-4000-8000-000000000005' AND resolved_at IS NULL$$,
  'healing resolves the open failure rows');

SET LOCAL ROLE authenticated;
SELECT is(public.ensure_my_account(), current_setting('fx.healed')::uuid,
  'ensure_my_account is idempotent: a second call returns the same account');

-- A member of someone else's account is never moved.
SELECT set_config('request.jwt.claims', '{"sub":"64000000-0000-4000-8000-000000000007","role":"authenticated"}', true);
SELECT is(public.ensure_my_account(),
  (SELECT account_id FROM public.profiles WHERE user_id = '64000000-0000-4000-8000-000000000006'),
  'ensure_my_account returns a member''s current (shared) account');

-- The orphaned user is relinked to the account they already own.
SELECT set_config('request.jwt.claims', '{"sub":"64000000-0000-4000-8000-000000000008","role":"authenticated"}', true);
SELECT is(public.ensure_my_account(), current_setting('fx.orphan_acct')::uuid,
  'a user without a profile is relinked to the account they already own');
RESET ROLE;

SELECT is(
  (SELECT account_role::text FROM public.profiles WHERE user_id = '64000000-0000-4000-8000-000000000007'),
  'agent',
  'the member keeps their role');
SELECT is(
  (SELECT count(*)::int FROM public.accounts WHERE owner_user_id = '64000000-0000-4000-8000-000000000008'),
  1,
  'relinking creates no second account');

SET LOCAL ROLE service_role;
SELECT is(
  (SELECT count(*)::int FROM public.signup_provisioning_failures
   WHERE user_id = '64000000-0000-4000-8000-000000000005'),
  1,
  'service_role can read the failure log');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
