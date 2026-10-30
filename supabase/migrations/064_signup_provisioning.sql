-- ============================================================
-- 064 — signup provisioning: record failures, self-heal, phone-ready
-- ============================================================
-- handle_new_user (017) creates the personal account + owner profile
-- for every new auth.users row and swallows any error as a WARNING so
-- a provisioning bug can never block a signup. The cost was an auth
-- user with no profile and no account, a WARNING in the Postgres log
-- nobody reads, and no way back: clients cannot insert profiles (055)
-- and the dashboard's Retry only re-read the missing row.
--
-- This migration keeps the "never block signup" behaviour and adds:
--
--   1. signup_provisioning_failures — one row per swallowed failure
--      (SQLSTATE + message), service-role only. Operators query
--      `WHERE resolved_at IS NULL`.
--   2. provision_personal_account(user_id) — the provisioning logic,
--      shared by the trigger and the self-heal RPC. Idempotent: an
--      existing profile is returned untouched (so invited members and
--      removed members, who already have one, are never moved); an
--      account the user already owns but no profile points at is
--      reused (accounts are one-per-owner, idx_accounts_one_per_owner).
--      Serialised per user with an advisory lock.
--   3. handle_new_user — same trigger, now calls (2) and records a
--      failure row. Recording is itself guarded, so it can't fail a
--      signup either.
--   4. ensure_my_account() — authenticated self-heal: provisions the
--      caller if (and only if) they have no profile, then marks their
--      open failure rows resolved. Called by getCurrentAccount, the
--      dashboard's AuthProvider and the invitation redeem route.
--
-- Phone-ready (phone sign-in is planned; email/password stays):
--   * auth.users.email is NULL for a phone user. profiles.email is
--     NOT NULL with no unique index and no CHECK, invitations carry no
--     email, and the 017 backfill already stored '' for email-less
--     users, so '' is stored again rather than relaxing the column:
--     many phone users cannot collide, and app code that assumes a
--     string (e.g. profile-form's `profile.email.toLowerCase()`) keeps
--     working.
--   * profiles.phone (new, nullable, no unique index — auth.users owns
--     uniqueness) is a display copy of auth.users.phone in E.164 form
--     ('+' prefixed). Like account_id it is not client-writable:
--     enforce_profile_privilege_columns now rejects an authenticated
--     change to it, so nothing can later mistake a user-typed value
--     for the verified sign-in number.
--   * full_name falls back to that phone when the user has neither a
--     name nor an email (an email user without a name keeps '' so the
--     UI shows the email, as before). The account name falls back
--     name → email → phone → 'My account'.
--
-- Existing auth users without a profile are NOT backfilled here: they
-- heal on their next dashboard load / API call, which also avoids
-- minting accounts for abandoned, never-confirmed signups.
--
-- Idempotent: IF NOT EXISTS, CREATE OR REPLACE, DROP ... IF EXISTS,
-- and the phone backfill only touches rows where phone IS NULL.
-- ============================================================

-- ── 1. Failure log ────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.signup_provisioning_failures (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  sqlstate    TEXT NOT NULL,
  message     TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_signup_provisioning_failures_open
  ON public.signup_provisioning_failures (user_id)
  WHERE resolved_at IS NULL;

-- Service-role only (RLS on, no policies). The 062 default privileges
-- granted authenticated CRUD on creation; take it back explicitly.
ALTER TABLE public.signup_provisioning_failures ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.signup_provisioning_failures FROM anon, authenticated;
GRANT ALL ON TABLE public.signup_provisioning_failures TO service_role;

-- ── Phone column ──────────────────────────────────────────────

ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS phone TEXT;

-- Same guard as 055, plus phone (a copy of the verified sign-in
-- number, not a user-editable field).
CREATE OR REPLACE FUNCTION public.enforce_profile_privilege_columns()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    RAISE EXCEPTION
      'profiles are created by the signup trigger; they cannot be inserted directly'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NEW.account_role IS DISTINCT FROM OLD.account_role
     OR NEW.account_id IS DISTINCT FROM OLD.account_id
  THEN
    RAISE EXCEPTION
      'account_role and account_id cannot be changed directly; use the account member/invitation RPCs'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NEW.phone IS DISTINCT FROM OLD.phone THEN
    RAISE EXCEPTION
      'phone mirrors the sign-in phone number and cannot be changed directly'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END;
$$;

ALTER FUNCTION public.enforce_profile_privilege_columns() OWNER TO postgres;

-- Backfill the copy for existing phone users (runs as the migration
-- owner, so the guard above does not apply).
UPDATE public.profiles p
SET phone = CASE WHEN left(btrim(u.phone), 1) = '+' THEN btrim(u.phone)
                 ELSE '+' || btrim(u.phone) END
FROM auth.users u
WHERE u.id = p.user_id
  AND p.phone IS NULL
  AND NULLIF(btrim(u.phone), '') IS NOT NULL;

-- ── 2. Shared provisioning ────────────────────────────────────

CREATE OR REPLACE FUNCTION public.provision_personal_account(p_user_id UUID)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id UUID;
  v_email TEXT;
  v_phone TEXT;
  v_meta_name TEXT;
  v_full_name TEXT;
BEGIN
  -- One provisioning at a time per user (trigger vs. self-heal, or two
  -- tabs healing at once).
  PERFORM pg_advisory_xact_lock(hashtextextended('provision_personal_account:' || p_user_id::text, 0));

  SELECT account_id INTO v_account_id FROM profiles WHERE user_id = p_user_id;
  IF FOUND THEN
    RETURN v_account_id;
  END IF;

  SELECT NULLIF(btrim(u.email), ''),
         NULLIF(btrim(u.phone), ''),
         NULLIF(btrim(u.raw_user_meta_data->>'full_name'), '')
  INTO v_email, v_phone, v_meta_name
  FROM auth.users u
  WHERE u.id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No auth user %', p_user_id USING ERRCODE = '22023';
  END IF;

  IF v_phone IS NOT NULL AND left(v_phone, 1) <> '+' THEN
    v_phone := '+' || v_phone;
  END IF;

  v_full_name := COALESCE(v_meta_name, CASE WHEN v_email IS NULL THEN v_phone END, '');

  SELECT id INTO v_account_id FROM accounts WHERE owner_user_id = p_user_id;
  IF NOT FOUND THEN
    INSERT INTO accounts (name, owner_user_id)
    VALUES (COALESCE(v_meta_name, v_email, v_phone, 'My account'), p_user_id)
    RETURNING id INTO v_account_id;
  END IF;

  INSERT INTO profiles (user_id, full_name, email, phone, account_id, account_role)
  VALUES (p_user_id, v_full_name, COALESCE(v_email, ''), v_phone, v_account_id, 'owner');

  RETURN v_account_id;
END;
$$;

ALTER FUNCTION public.provision_personal_account(UUID) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.provision_personal_account(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.provision_personal_account(UUID) TO service_role;

-- ── 3. Signup trigger ─────────────────────────────────────────
-- CREATE OR REPLACE keeps the existing on_auth_user_created trigger.

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_state TEXT;
  v_message TEXT;
BEGIN
  BEGIN
    PERFORM public.provision_personal_account(NEW.id);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
    RAISE WARNING 'Failed to bootstrap account/profile for user %: % (%)', NEW.id, v_message, v_state;
    BEGIN
      INSERT INTO public.signup_provisioning_failures (user_id, sqlstate, message)
      VALUES (NEW.id, v_state, left(v_message, 2000));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Could not record the provisioning failure for user %: %', NEW.id, SQLERRM;
    END;
  END;
  RETURN NEW;
END;
$$;

ALTER FUNCTION public.handle_new_user() OWNER TO postgres;

-- Recreate only if missing (e.g. a fork that dropped it); never twice.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'on_auth_user_created' AND tgrelid = 'auth.users'::regclass
  ) THEN
    CREATE TRIGGER on_auth_user_created
      AFTER INSERT ON auth.users
      FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
  END IF;
END;
$$;

-- ── 4. Self-heal ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.ensure_my_account()
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_account_id UUID;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthorized' USING ERRCODE = '42501';
  END IF;

  v_account_id := public.provision_personal_account(v_uid);

  UPDATE signup_provisioning_failures
  SET resolved_at = NOW()
  WHERE user_id = v_uid AND resolved_at IS NULL;

  RETURN v_account_id;
END;
$$;

ALTER FUNCTION public.ensure_my_account() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.ensure_my_account() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ensure_my_account() TO authenticated, service_role;
