-- ============================================================
-- Tenant isolation (behavioural test) — run with `supabase test db`
-- ============================================================
-- Proves at the database level what the app relies on: a signed-in
-- user of account B can neither read nor write account A's data, deals
-- can't point at another account's pipeline/stage (060), and a member
-- removed from an account stops seeing its notifications (061).
--
-- Fixtures are inserted as `postgres` (table owner, so RLS does not
-- apply). Assertions then run as `authenticated` with a JWT `sub` claim
-- (what auth.uid() reads), or as `service_role` for the engine path.
-- Everything happens inside BEGIN … ROLLBACK, so nothing persists.
--
--   A = owner of account A     C = agent in account A, later removed
--   B = owner of account B
-- ============================================================
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(34);

-- ── Users: the on_auth_user_created trigger (handle_new_user) gives
--    each one a profile and their own account. ──────────────────────
INSERT INTO auth.users (instance_id, id, aud, role, email, raw_user_meta_data, created_at, updated_at)
VALUES
  ('00000000-0000-0000-0000-000000000000', '11111111-1111-4111-8111-111111111111',
   'authenticated', 'authenticated', 'tenant-a@example.test', '{"full_name":"Tenant A"}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '22222222-2222-4222-8222-222222222222',
   'authenticated', 'authenticated', 'tenant-b@example.test', '{"full_name":"Tenant B"}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '33333333-3333-4333-8333-333333333333',
   'authenticated', 'authenticated', 'agent-c@example.test', '{"full_name":"Agent C"}', now(), now());

SELECT is(
  (SELECT count(*)::int FROM public.profiles
   WHERE user_id IN ('11111111-1111-4111-8111-111111111111',
                     '22222222-2222-4222-8222-222222222222',
                     '33333333-3333-4333-8333-333333333333')),
  3,
  'handle_new_user provisioned a profile for every new user'
);
SELECT is(
  (SELECT count(DISTINCT account_id)::int FROM public.profiles
   WHERE user_id IN ('11111111-1111-4111-8111-111111111111',
                     '22222222-2222-4222-8222-222222222222')),
  2,
  'A and B were given separate accounts'
);

-- Account ids are generated; keep them in transaction-local settings so
-- every later statement (under any role) can read them.
SELECT set_config('fx.acct_a', (SELECT account_id::text FROM public.profiles WHERE user_id = '11111111-1111-4111-8111-111111111111'), true);
SELECT set_config('fx.acct_b', (SELECT account_id::text FROM public.profiles WHERE user_id = '22222222-2222-4222-8222-222222222222'), true);
SELECT set_config('fx.acct_c', (SELECT account_id::text FROM public.profiles WHERE user_id = '33333333-3333-4333-8333-333333333333'), true);

-- C joins A as an agent (what redeem_invitation does: move the profile,
-- drop the now-empty personal account so the one-account-per-owner
-- index lets remove_account_member create a fresh one later).
UPDATE public.profiles
SET account_id = current_setting('fx.acct_a')::uuid, account_role = 'agent'
WHERE user_id = '33333333-3333-4333-8333-333333333333';
DELETE FROM public.accounts WHERE id = current_setting('fx.acct_c')::uuid;

-- ── Account A's data ───────────────────────────────────────────────
INSERT INTO public.contacts (id, user_id, account_id, phone, name) VALUES
  ('a0000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111',
   current_setting('fx.acct_a')::uuid, '15550000001', 'Alice'),
  ('b0000000-0000-4000-8000-000000000001', '22222222-2222-4222-8222-222222222222',
   current_setting('fx.acct_b')::uuid, '15550000002', 'Bob');

INSERT INTO public.conversations (id, user_id, account_id, contact_id) VALUES
  ('a0000000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111',
   current_setting('fx.acct_a')::uuid, 'a0000000-0000-4000-8000-000000000001');

INSERT INTO public.messages (id, conversation_id, sender_type, content_text) VALUES
  ('a0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000002',
   'customer', 'hello from A''s customer');

INSERT INTO public.pipelines (id, user_id, account_id, name) VALUES
  ('a0000000-0000-4000-8000-000000000010', '11111111-1111-4111-8111-111111111111',
   current_setting('fx.acct_a')::uuid, 'A sales'),
  ('a0000000-0000-4000-8000-000000000011', '11111111-1111-4111-8111-111111111111',
   current_setting('fx.acct_a')::uuid, 'A renewals'),
  ('b0000000-0000-4000-8000-000000000010', '22222222-2222-4222-8222-222222222222',
   current_setting('fx.acct_b')::uuid, 'B sales');

INSERT INTO public.pipeline_stages (id, pipeline_id, name, position) VALUES
  ('a0000000-0000-4000-8000-000000000020', 'a0000000-0000-4000-8000-000000000010', 'New', 0),
  ('a0000000-0000-4000-8000-000000000021', 'a0000000-0000-4000-8000-000000000010', 'Won', 1),
  ('a0000000-0000-4000-8000-000000000022', 'a0000000-0000-4000-8000-000000000011', 'Renewal', 0),
  ('b0000000-0000-4000-8000-000000000020', 'b0000000-0000-4000-8000-000000000010', 'New', 0);

INSERT INTO public.deals (id, user_id, account_id, pipeline_id, stage_id, contact_id, title) VALUES
  ('a0000000-0000-4000-8000-000000000030', '11111111-1111-4111-8111-111111111111',
   current_setting('fx.acct_a')::uuid, 'a0000000-0000-4000-8000-000000000010',
   'a0000000-0000-4000-8000-000000000020', 'a0000000-0000-4000-8000-000000000001', 'A deal'),
  ('b0000000-0000-4000-8000-000000000030', '22222222-2222-4222-8222-222222222222',
   current_setting('fx.acct_b')::uuid, 'b0000000-0000-4000-8000-000000000010',
   'b0000000-0000-4000-8000-000000000020', 'b0000000-0000-4000-8000-000000000001', 'B deal');

INSERT INTO public.message_templates (id, user_id, account_id, name, body_text, meta_template_id) VALUES
  ('a0000000-0000-4000-8000-000000000040', '11111111-1111-4111-8111-111111111111',
   current_setting('fx.acct_a')::uuid, 'a_promo', 'A''s template body', 'T-A');

INSERT INTO public.notifications (id, account_id, user_id, conversation_id, contact_id, title, body) VALUES
  ('a0000000-0000-4000-8000-000000000050', current_setting('fx.acct_a')::uuid,
   '11111111-1111-4111-8111-111111111111', 'a0000000-0000-4000-8000-000000000002',
   'a0000000-0000-4000-8000-000000000001', 'New conversation assigned', 'about Alice'),
  ('a0000000-0000-4000-8000-000000000051', current_setting('fx.acct_a')::uuid,
   '33333333-3333-4333-8333-333333333333', 'a0000000-0000-4000-8000-000000000002',
   'a0000000-0000-4000-8000-000000000001', 'New conversation assigned', 'about Alice');

-- ── As A: positive controls (proves the claims setup works, so the
--    "B sees nothing" results below are meaningful) ─────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);

SELECT isnt_empty($$SELECT 1 FROM public.contacts          WHERE id = 'a0000000-0000-4000-8000-000000000001'$$, 'A sees its contact');
SELECT isnt_empty($$SELECT 1 FROM public.conversations     WHERE id = 'a0000000-0000-4000-8000-000000000002'$$, 'A sees its conversation');
SELECT isnt_empty($$SELECT 1 FROM public.messages          WHERE id = 'a0000000-0000-4000-8000-000000000003'$$, 'A sees its message');
SELECT isnt_empty($$SELECT 1 FROM public.pipelines         WHERE id = 'a0000000-0000-4000-8000-000000000010'$$, 'A sees its pipeline');
SELECT isnt_empty($$SELECT 1 FROM public.pipeline_stages   WHERE id = 'a0000000-0000-4000-8000-000000000020'$$, 'A sees its pipeline stage');
SELECT isnt_empty($$SELECT 1 FROM public.deals             WHERE id = 'a0000000-0000-4000-8000-000000000030'$$, 'A sees its deal');
SELECT isnt_empty($$SELECT 1 FROM public.message_templates WHERE id = 'a0000000-0000-4000-8000-000000000040'$$, 'A sees its template');
SELECT isnt_empty($$SELECT 1 FROM public.notifications     WHERE id = 'a0000000-0000-4000-8000-000000000050'$$, 'A sees its notification');

-- ── As B: none of A's rows are visible ─────────────────────────────
SELECT set_config('request.jwt.claims', '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}', true);

SELECT is_empty($$SELECT 1 FROM public.contacts          WHERE account_id = current_setting('fx.acct_a')::uuid$$, 'B sees none of A''s contacts');
SELECT is_empty($$SELECT 1 FROM public.conversations     WHERE account_id = current_setting('fx.acct_a')::uuid$$, 'B sees none of A''s conversations');
SELECT is_empty($$SELECT 1 FROM public.messages          WHERE conversation_id = 'a0000000-0000-4000-8000-000000000002'$$, 'B sees none of A''s messages');
SELECT is_empty($$SELECT 1 FROM public.pipelines         WHERE account_id = current_setting('fx.acct_a')::uuid$$, 'B sees none of A''s pipelines');
SELECT is_empty($$SELECT 1 FROM public.pipeline_stages   WHERE pipeline_id IN ('a0000000-0000-4000-8000-000000000010', 'a0000000-0000-4000-8000-000000000011')$$, 'B sees none of A''s pipeline stages');
SELECT is_empty($$SELECT 1 FROM public.deals             WHERE account_id = current_setting('fx.acct_a')::uuid$$, 'B sees none of A''s deals');
SELECT is_empty($$SELECT 1 FROM public.message_templates WHERE account_id = current_setting('fx.acct_a')::uuid$$, 'B sees none of A''s templates');
SELECT is_empty($$SELECT 1 FROM public.notifications     WHERE account_id = current_setting('fx.acct_a')::uuid$$, 'B sees none of A''s notifications');

-- ── As B: writes into A's account are rejected by RLS ──────────────
SELECT throws_ok(
  $$INSERT INTO public.contacts (user_id, account_id, phone)
    VALUES ('22222222-2222-4222-8222-222222222222', current_setting('fx.acct_a')::uuid, '15550000099')$$,
  '42501', NULL, 'B cannot insert a contact into A''s account');
SELECT throws_ok(
  $$INSERT INTO public.messages (conversation_id, sender_type, content_text)
    VALUES ('a0000000-0000-4000-8000-000000000002', 'agent', 'injected')$$,
  '42501', NULL, 'B cannot insert a message into A''s conversation');
SELECT throws_ok(
  $$INSERT INTO public.message_templates (user_id, account_id, name, body_text)
    VALUES ('22222222-2222-4222-8222-222222222222', current_setting('fx.acct_a')::uuid, 'b_spoof', 'x')$$,
  '42501', NULL, 'B cannot insert a template into A''s account');
-- A fully consistent A deal (so the 060 trigger passes) — RLS must still refuse it.
SELECT throws_ok(
  $$INSERT INTO public.deals (user_id, account_id, pipeline_id, stage_id, contact_id, title)
    VALUES ('22222222-2222-4222-8222-222222222222', current_setting('fx.acct_a')::uuid,
            'a0000000-0000-4000-8000-000000000010', 'a0000000-0000-4000-8000-000000000020',
            'a0000000-0000-4000-8000-000000000001', 'B in A')$$,
  '42501', NULL, 'B cannot insert a deal into A''s account');

-- An UPDATE of a row B can't see matches nothing (checked as postgres below).
UPDATE public.contacts SET name = 'pwned' WHERE id = 'a0000000-0000-4000-8000-000000000001';

-- ── 060: deals must use their own account's pipeline / stage ───────
SELECT throws_ok(
  $$INSERT INTO public.deals (user_id, account_id, pipeline_id, stage_id, contact_id, title)
    VALUES ('22222222-2222-4222-8222-222222222222', current_setting('fx.acct_b')::uuid,
            'a0000000-0000-4000-8000-000000000010', 'a0000000-0000-4000-8000-000000000020',
            'b0000000-0000-4000-8000-000000000001', 'B deal on A pipeline')$$,
  '23514', NULL, 'B cannot create its own deal on A''s pipeline');
SELECT throws_ok(
  $$UPDATE public.deals
    SET pipeline_id = 'a0000000-0000-4000-8000-000000000010',
        stage_id    = 'a0000000-0000-4000-8000-000000000020'
    WHERE id = 'b0000000-0000-4000-8000-000000000030'$$,
  '23514', NULL, 'B cannot move its deal onto A''s pipeline');

-- As A: the legitimate writers keep working.
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);

SELECT lives_ok(
  $$UPDATE public.deals SET stage_id = 'a0000000-0000-4000-8000-000000000021'
    WHERE id = 'a0000000-0000-4000-8000-000000000030'$$,
  'Kanban move to another stage of the same pipeline is allowed');
SELECT lives_ok(
  $$UPDATE public.deals
    SET title = 'A deal (edited)',
        pipeline_id = 'a0000000-0000-4000-8000-000000000010',
        stage_id    = 'a0000000-0000-4000-8000-000000000021'
    WHERE id = 'a0000000-0000-4000-8000-000000000030'$$,
  'deal-form save (full payload incl. unchanged pipeline/stage) is allowed');
SELECT throws_ok(
  $$UPDATE public.deals SET stage_id = 'a0000000-0000-4000-8000-000000000022'
    WHERE id = 'a0000000-0000-4000-8000-000000000030'$$,
  '23514', NULL, 'a stage from a different pipeline (same account) is rejected');

-- As service_role (bypasses RLS, like the automation engine): the
-- trigger still refuses a cross-account pipeline.
RESET ROLE;
SET LOCAL ROLE service_role;
SELECT throws_ok(
  $$INSERT INTO public.deals (user_id, account_id, pipeline_id, stage_id, contact_id, title)
    VALUES ('22222222-2222-4222-8222-222222222222', current_setting('fx.acct_b')::uuid,
            'a0000000-0000-4000-8000-000000000010', 'a0000000-0000-4000-8000-000000000020',
            'b0000000-0000-4000-8000-000000000001', 'engine deal on A pipeline')$$,
  '23514', NULL, 'service role cannot create a deal on another account''s pipeline');

-- ── 061: notifications need current membership ─────────────────────
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"33333333-3333-4333-8333-333333333333","role":"authenticated"}', true);
SELECT isnt_empty($$SELECT 1 FROM public.notifications WHERE id = 'a0000000-0000-4000-8000-000000000051'$$,
  'C (a member of A) sees its notification');

SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);
SELECT is_empty($$SELECT 1 FROM public.notifications WHERE id = 'a0000000-0000-4000-8000-000000000051'$$,
  'A cannot read a teammate''s notification');
SELECT lives_ok($$SELECT public.remove_account_member('33333333-3333-4333-8333-333333333333')$$,
  'A (owner) removes C from the account');

SELECT set_config('request.jwt.claims', '{"sub":"33333333-3333-4333-8333-333333333333","role":"authenticated"}', true);
SELECT is_empty($$SELECT 1 FROM public.notifications WHERE id = 'a0000000-0000-4000-8000-000000000051'$$,
  'removed member C can no longer read A''s notification');
UPDATE public.notifications SET read_at = now() WHERE id = 'a0000000-0000-4000-8000-000000000051';

-- ── Post-conditions, read as postgres ──────────────────────────────
RESET ROLE;
SELECT is(
  (SELECT name FROM public.contacts WHERE id = 'a0000000-0000-4000-8000-000000000001'),
  'Alice',
  'B''s UPDATE of A''s contact changed nothing');
SELECT is(
  (SELECT read_at FROM public.notifications WHERE id = 'a0000000-0000-4000-8000-000000000051'),
  NULL::timestamptz,
  'removed member C could not mark A''s notification read');

SELECT * FROM finish();
ROLLBACK;
