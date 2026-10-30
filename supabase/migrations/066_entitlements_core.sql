-- ============================================================
-- 066 — entitlements core: plans, prices, subscriptions, usage
-- ============================================================
-- Phase 2 (plans and limits). This migration only adds data
-- structures; enforcement lives in 067 (functions) and 068
-- (triggers). Everything here is inert until the operator turns the
-- entitlements switch on (platform_settings.entitlements_enabled +
-- the ENTITLEMENTS_ENABLED env var, see docs/entitlements.md).
--
--   platform_settings        singleton: the DB half of the switch,
--                            go-live stamp, grace/trial durations,
--                            legacy cut-over date. Service role only.
--   currencies               ISO code, minor unit, enabled-for-sale.
--   plans                    one row per plan, ONE TYPED COLUMN PER
--                            LIMIT, each NOT NULL and CHECK (>= 0), so
--                            "unlimited" cannot exist on any plan
--                            (REQ-X2). The single configuration source
--                            (REQ-X1): change a value here and both
--                            enforcement and display follow.
--   plan_prices              (plan, currency, interval, kind) → amount
--                            in minor units. A new currency is rows,
--                            not a migration (REQ-C1).
--   account_subscriptions    exactly one row per account: plan, state,
--                            trial/period dates, a scheduled change,
--                            per-account limit overrides.
--   account_usage_counters   period counters for METERED resources
--                            only (broadcast recipients). Count limits
--                            (contacts, seats, …) are always count(*)
--                            over the real rows, so they cannot drift.
--   entitlement_audit_log    one row per operator / system change.
--                            No FK to accounts so it survives deletion.
--                            Service role only.
--   trial_number_claims      phone_number_id → first account that
--                            connected it (REQ-T2). Survives account
--                            deletion (SET NULL). Service role only.
--
-- Backfill: every account that exists now gets legacy_beta / active
-- (REQ-G1). New accounts get a row from an AFTER INSERT trigger on
-- accounts: legacy_beta while the switch has never been on, trial once
-- it has (REQ-G1 / AC-G2). The trigger never raises, so it can never
-- break provision_personal_account or remove_account_member
-- (invariant 14) — a failure is a WARNING and the row is created
-- lazily by the 067 functions instead.
--
-- Grants follow 062 (explicit, nothing from project defaults):
--   plans, plan_prices, currencies     authenticated SELECT only
--   account_subscriptions,
--   account_usage_counters             authenticated SELECT (members)
--   platform_settings,
--   entitlement_audit_log,
--   trial_number_claims                service role only
-- Every client write is revoked: plan and state are changed by the
-- operator RPCs in 067 only.
--
-- Idempotent: IF NOT EXISTS, ON CONFLICT DO NOTHING (a re-run never
-- overwrites limits or prices an operator has tuned), DROP … IF
-- EXISTS before CREATE for policies and triggers.
-- ============================================================

-- ------------------------------------------------------------
-- platform_settings (singleton)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.platform_settings (
  id                            BOOLEAN PRIMARY KEY DEFAULT true CHECK (id),
  entitlements_enabled          BOOLEAN NOT NULL DEFAULT false,
  -- Stamped the first time the switch goes on: the grandfathering
  -- "go-live" moment (REQ-H4). Never cleared.
  entitlements_first_enabled_at TIMESTAMPTZ,
  trial_days                    INTEGER NOT NULL DEFAULT 14 CHECK (trial_days BETWEEN 1 AND 365),
  past_due_days                 INTEGER NOT NULL DEFAULT 7 CHECK (past_due_days BETWEEN 0 AND 365),
  restricted_days               INTEGER NOT NULL DEFAULT 14 CHECK (restricted_days BETWEEN 0 AND 365),
  -- legacy_beta cut-over (REQ-G2/G3). NULL = no cut-over scheduled.
  legacy_ends_at                TIMESTAMPTZ,
  updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO public.platform_settings (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.platform_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.platform_settings FROM anon, authenticated;
GRANT ALL ON TABLE public.platform_settings TO service_role;

-- ------------------------------------------------------------
-- currencies
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.currencies (
  code       CHAR(3) PRIMARY KEY CHECK (code ~ '^[A-Z]{3}$'),
  minor_unit INTEGER NOT NULL DEFAULT 2 CHECK (minor_unit BETWEEN 0 AND 4),
  enabled    BOOLEAN NOT NULL DEFAULT false
);

-- D-01: INR only at launch; USD stored, not enabled.
INSERT INTO public.currencies (code, minor_unit, enabled) VALUES
  ('INR', 2, true),
  ('USD', 2, false)
ON CONFLICT (code) DO NOTHING;

-- ------------------------------------------------------------
-- plans
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.plans (
  key                             TEXT PRIMARY KEY CHECK (key ~ '^[a-z][a-z0-9_]{1,31}$'),
  name                            TEXT NOT NULL,
  sort_order                      INTEGER NOT NULL DEFAULT 0,
  -- true for the plans a customer can buy (starter/growth/pro). trial
  -- and legacy_beta are assigned, never sold.
  is_customer_plan                BOOLEAN NOT NULL DEFAULT false,
  seats_included                  INTEGER NOT NULL CHECK (seats_included >= 0),
  seats_max                       INTEGER NOT NULL CHECK (seats_max >= 0),
  contacts_max                    INTEGER NOT NULL CHECK (contacts_max >= 0),
  broadcast_recipients_per_period INTEGER NOT NULL CHECK (broadcast_recipients_per_period >= 0),
  automations_active_max          INTEGER NOT NULL CHECK (automations_active_max >= 0),
  automations_total_max           INTEGER NOT NULL CHECK (automations_total_max >= 0),
  flows_active_max                INTEGER NOT NULL CHECK (flows_active_max >= 0),
  flows_total_max                 INTEGER NOT NULL CHECK (flows_total_max >= 0),
  whatsapp_numbers_max            INTEGER NOT NULL CHECK (whatsapp_numbers_max >= 0),
  api_keys_max                    INTEGER NOT NULL CHECK (api_keys_max >= 0),
  api_rate_per_minute             INTEGER NOT NULL CHECK (api_rate_per_minute >= 0),
  webhook_endpoints_max           INTEGER NOT NULL CHECK (webhook_endpoints_max >= 0),
  ai_drafts                       BOOLEAN NOT NULL,
  ai_auto_reply                   BOOLEAN NOT NULL,
  kb_documents_max                INTEGER NOT NULL CHECK (kb_documents_max >= 0),
  storage_bytes_max               BIGINT  NOT NULL CHECK (storage_bytes_max >= 0),
  pipelines_max                   INTEGER NOT NULL CHECK (pipelines_max >= 0),
  CHECK (seats_included <= seats_max),
  CHECK (automations_active_max <= automations_total_max),
  CHECK (flows_active_max <= flows_total_max),
  created_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Option B (D-02 / D-05), trial quantities D-09. Fair-use totals for
-- automations and flows are 10x the active limit (R4/R5), stored
-- explicitly. legacy_beta = Pro (D-12). 1 GB = 1024^3 bytes.
INSERT INTO public.plans (
  key, name, sort_order, is_customer_plan,
  seats_included, seats_max, contacts_max, broadcast_recipients_per_period,
  automations_active_max, automations_total_max, flows_active_max, flows_total_max,
  whatsapp_numbers_max, api_keys_max, api_rate_per_minute, webhook_endpoints_max,
  ai_drafts, ai_auto_reply, kb_documents_max, storage_bytes_max, pipelines_max
) VALUES
  ('trial',       'Trial',       0, false,  3,   3,   1000,    500,   3,   30,  2,  20, 1,  1,  60,  1, true, true,   10,  1::bigint * 1073741824,   2),
  ('starter',     'Starter',     1, true,   2,   5,   5000,  10000,   5,   50,  3,  30, 1,  0,   0,  0, true, false,   0,  2::bigint * 1073741824,   2),
  ('growth',      'Growth',      2, true,   5,  25,  25000, 100000,  25,  250, 15, 150, 1,  3, 120,  3, true, true,   50, 10::bigint * 1073741824,  10),
  ('pro',         'Pro',         3, true,  10, 100, 100000, 500000, 100, 1000, 50, 500, 1, 20, 600, 10, true, true,  500, 50::bigint * 1073741824, 100),
  ('legacy_beta', 'Legacy beta', 4, false, 10, 100, 100000, 500000, 100, 1000, 50, 500, 1, 20, 600, 10, true, true,  500, 50::bigint * 1073741824, 100)
ON CONFLICT (key) DO NOTHING;

-- ------------------------------------------------------------
-- plan_prices
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.plan_prices (
  plan_key     TEXT NOT NULL REFERENCES public.plans(key) ON DELETE CASCADE,
  currency     CHAR(3) NOT NULL REFERENCES public.currencies(code),
  interval     TEXT NOT NULL CHECK (interval IN ('month', 'year')),
  kind         TEXT NOT NULL CHECK (kind IN ('base', 'extra_seat')),
  -- Minor units (paise / cents), exclusive of tax (D-04).
  amount_minor BIGINT NOT NULL CHECK (amount_minor >= 0),
  PRIMARY KEY (plan_key, currency, interval, kind)
);

-- D-05 / D-06. USD is "future, not launched": stored, but its
-- currency row is not enabled, so nothing may display it (REQ-C2).
INSERT INTO public.plan_prices (plan_key, currency, interval, kind, amount_minor) VALUES
  ('starter', 'INR', 'month', 'base',        149900),
  ('starter', 'INR', 'year',  'base',       1499000),
  ('starter', 'INR', 'month', 'extra_seat',   49900),
  ('growth',  'INR', 'month', 'base',        349900),
  ('growth',  'INR', 'year',  'base',       3499000),
  ('growth',  'INR', 'month', 'extra_seat',   69900),
  ('pro',     'INR', 'month', 'base',        799900),
  ('pro',     'INR', 'year',  'base',       7999000),
  ('pro',     'INR', 'month', 'extra_seat',   89900),
  ('starter', 'USD', 'month', 'base',          2900),
  ('starter', 'USD', 'month', 'extra_seat',    1000),
  ('growth',  'USD', 'month', 'base',          7900),
  ('growth',  'USD', 'month', 'extra_seat',    1500),
  ('pro',     'USD', 'month', 'base',         19900),
  ('pro',     'USD', 'month', 'extra_seat',    2000)
ON CONFLICT (plan_key, currency, interval, kind) DO NOTHING;

-- Read-only catalogue for clients (the Phase 2b plan page reads it).
ALTER TABLE public.currencies  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.plans       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.plan_prices ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS currencies_select ON public.currencies;
CREATE POLICY currencies_select ON public.currencies FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS plans_select ON public.plans;
CREATE POLICY plans_select ON public.plans FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS plan_prices_select ON public.plan_prices;
CREATE POLICY plan_prices_select ON public.plan_prices FOR SELECT TO authenticated USING (true);

REVOKE ALL ON TABLE public.currencies, public.plans, public.plan_prices FROM anon, authenticated;
GRANT SELECT ON TABLE public.currencies, public.plans, public.plan_prices TO authenticated;
GRANT ALL ON TABLE public.currencies, public.plans, public.plan_prices TO service_role;

-- ------------------------------------------------------------
-- account_subscriptions
-- ------------------------------------------------------------
-- This table and account_usage_counters are bookkeeping, not customer data:
-- every account has a subscription row, so redeem_invitation must not refuse
-- to delete an account because of them. They cascade with the account and are
-- listed in tablesWithoutDomainData in redeem-invitation-migration.test.ts.
CREATE TABLE IF NOT EXISTS public.account_subscriptions (
  account_id           UUID PRIMARY KEY REFERENCES public.accounts(id) ON DELETE CASCADE,
  plan_key             TEXT NOT NULL REFERENCES public.plans(key),
  state                TEXT NOT NULL DEFAULT 'active'
                         CHECK (state IN ('trialing', 'active', 'past_due', 'restricted', 'locked')),
  state_reason         TEXT,
  state_changed_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  trial_ends_at        TIMESTAMPTZ,
  -- NULL = calendar month (UTC) until Phase 3 supplies billing periods.
  current_period_start TIMESTAMPTZ,
  current_period_end   TIMESTAMPTZ,
  scheduled_plan_key   TEXT REFERENCES public.plans(key),
  scheduled_change_at  TIMESTAMPTZ,
  -- Owner's "keep active" selections for R4/R5/R7/R8:
  -- {"automations":[uuid…],"flows":[…],"api_keys":[…],"webhook_endpoints":[…]}
  scheduled_keep       JSONB NOT NULL DEFAULT '{}'::jsonb,
  -- Per-account limit overrides, keyed by plans column name, e.g.
  -- {"seats_max": 120}. Merged over the plan row by 067.
  limit_overrides      JSONB NOT NULL DEFAULT '{}'::jsonb
                         CHECK (jsonb_typeof(limit_overrides) = 'object'),
  -- REQ-G4: remembered after the account leaves legacy_beta.
  was_legacy_beta      BOOLEAN NOT NULL DEFAULT false,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK ((scheduled_plan_key IS NULL) = (scheduled_change_at IS NULL))
);

CREATE INDEX IF NOT EXISTS idx_account_subscriptions_due_trial
  ON public.account_subscriptions (trial_ends_at) WHERE state = 'trialing';
CREATE INDEX IF NOT EXISTS idx_account_subscriptions_due_change
  ON public.account_subscriptions (scheduled_change_at) WHERE scheduled_change_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_account_subscriptions_grace
  ON public.account_subscriptions (state_changed_at) WHERE state IN ('past_due', 'restricted');

ALTER TABLE public.account_subscriptions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS account_subscriptions_select ON public.account_subscriptions;
CREATE POLICY account_subscriptions_select ON public.account_subscriptions FOR SELECT
  TO authenticated USING (is_account_member(account_id));
REVOKE ALL ON TABLE public.account_subscriptions FROM anon, authenticated;
GRANT SELECT ON TABLE public.account_subscriptions TO authenticated;
GRANT ALL ON TABLE public.account_subscriptions TO service_role;

DROP TRIGGER IF EXISTS set_updated_at ON public.account_subscriptions;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.account_subscriptions
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ------------------------------------------------------------
-- account_usage_counters (metered resources only)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.account_usage_counters (
  account_id   UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  resource     TEXT NOT NULL CHECK (resource IN ('broadcast_recipients')),
  period_start TIMESTAMPTZ NOT NULL,
  used         BIGINT NOT NULL DEFAULT 0 CHECK (used >= 0),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, resource, period_start)
);

ALTER TABLE public.account_usage_counters ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS account_usage_counters_select ON public.account_usage_counters;
CREATE POLICY account_usage_counters_select ON public.account_usage_counters FOR SELECT
  TO authenticated USING (is_account_member(account_id));
REVOKE ALL ON TABLE public.account_usage_counters FROM anon, authenticated;
GRANT SELECT ON TABLE public.account_usage_counters TO authenticated;
GRANT ALL ON TABLE public.account_usage_counters TO service_role;

-- ------------------------------------------------------------
-- entitlement_audit_log (service role only)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.entitlement_audit_log (
  id         BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  -- Deliberately no FK: the log outlives the account.
  account_id UUID,
  actor      TEXT NOT NULL CHECK (length(actor) BETWEEN 1 AND 200),
  action     TEXT NOT NULL,
  old_value  JSONB,
  new_value  JSONB,
  reason     TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_entitlement_audit_log_account
  ON public.entitlement_audit_log (account_id, created_at DESC);

ALTER TABLE public.entitlement_audit_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.entitlement_audit_log FROM anon, authenticated;
GRANT ALL ON TABLE public.entitlement_audit_log TO service_role;

-- ------------------------------------------------------------
-- trial_number_claims (service role only, REQ-T2)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.trial_number_claims (
  phone_number_id     TEXT PRIMARY KEY CHECK (length(phone_number_id) BETWEEN 1 AND 64),
  -- SET NULL: the claim must survive the account's deletion.
  first_account_id    UUID REFERENCES public.accounts(id) ON DELETE SET NULL,
  claimed_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- Reserved for Phase 4 (Embedded Signup may only know the number).
  display_number_hash TEXT
);

ALTER TABLE public.trial_number_claims ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.trial_number_claims FROM anon, authenticated;
GRANT ALL ON TABLE public.trial_number_claims TO service_role;

-- ------------------------------------------------------------
-- Backfill: existing accounts are grandfathered (REQ-G1).
-- Seat maximum is raised to cover current members above Pro's 100.
-- ------------------------------------------------------------
INSERT INTO public.account_subscriptions (account_id, plan_key, state, was_legacy_beta, limit_overrides)
SELECT a.id, 'legacy_beta', 'active', true,
       CASE WHEN m.members > 100
            THEN jsonb_build_object('seats_max', m.members)
            ELSE '{}'::jsonb END
FROM public.accounts a
CROSS JOIN LATERAL (
  SELECT count(*)::int AS members FROM public.profiles p WHERE p.account_id = a.id
) m
ON CONFLICT (account_id) DO NOTHING;

-- ------------------------------------------------------------
-- New accounts: legacy_beta before go-live, trial after.
-- Never raises (invariant 14).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ensure_account_subscription()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_settings platform_settings%ROWTYPE;
BEGIN
  BEGIN
    SELECT * INTO v_settings FROM platform_settings WHERE id;
    IF v_settings.entitlements_first_enabled_at IS NULL THEN
      INSERT INTO account_subscriptions (account_id, plan_key, state, was_legacy_beta)
      VALUES (NEW.id, 'legacy_beta', 'active', true)
      ON CONFLICT (account_id) DO NOTHING;
    ELSE
      INSERT INTO account_subscriptions (
        account_id, plan_key, state, trial_ends_at, current_period_start, current_period_end
      ) VALUES (
        NEW.id, 'trial', 'trialing',
        now() + make_interval(days => coalesce(v_settings.trial_days, 14)),
        now(),
        now() + make_interval(days => coalesce(v_settings.trial_days, 14))
      )
      ON CONFLICT (account_id) DO NOTHING;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'ensure_account_subscription(%) failed: % %', NEW.id, SQLSTATE, SQLERRM;
  END;
  RETURN NULL;
END;
$$;

ALTER FUNCTION public.ensure_account_subscription() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.ensure_account_subscription() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS accounts_ensure_subscription ON public.accounts;
CREATE TRIGGER accounts_ensure_subscription AFTER INSERT ON public.accounts
  FOR EACH ROW EXECUTE FUNCTION public.ensure_account_subscription();
