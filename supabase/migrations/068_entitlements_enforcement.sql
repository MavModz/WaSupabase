-- ============================================================
-- 068 — entitlements enforcement: triggers, trial claim, switch
-- ============================================================
-- Why triggers: RLS lets `authenticated` write contacts, pipelines,
-- broadcasts, automations, flows (agent+) and api_keys,
-- webhook_endpoints, ai_knowledge_documents, account_invitations,
-- ai_configs (admin+) straight through PostgREST, so a limit checked
-- only in an /api route is bypassable from the browser console
-- (REQ-X3). Route pre-checks exist only for better messages.
--
-- The triggers ship DISABLED. entitlements_set_enabled(true, actor) —
-- the operator's switch — enables them and stamps the go-live moment
-- the first time; (false, actor) disables them and deletes nothing
-- (REQ-H4). With the switch off no enforcement trigger fires at all
-- (REQ-H2). Each function also re-checks entitlements_enabled(), so a
-- trigger enabled by hand is still inert. A re-run of this migration
-- on a live database restores the state the flag says.
--
-- Count limits: AFTER … FOR EACH STATEMENT with transition tables.
--   Take a per-(account, resource) advisory lock, then count the real
--   rows; the count statement gets a fresh READ COMMITTED snapshot, so
--   it sees what a competing transaction committed before releasing
--   the lock. 5 parallel inserts with one slot left → exactly 1 wins
--   (REQ-X4), and a 500-row CSV batch costs one count.
--   A count only ever blocks a statement that ADDS usage: editing an
--   active automation, deactivating one, or reading while over the
--   limit are all untouched.
-- Flags and the broadcast pre-flight: BEFORE … FOR EACH ROW.
-- State: restricted / locked refuse creation with WA002 and reason
--   account_restricted / account_locked (the resource keeps working).
--
-- Inbound exemption (D-13, REQ-X11): there is no trigger on messages,
-- conversations or pending_message_statuses at all. The contacts
-- trigger skips a statement only when the verified JWT role is
-- service_role AND the request carries x-wacrm-inbound: 1, which only
-- the webhook's own client sends. A browser can send the header, but
-- its JWT role is never service_role. If a gateway ever strips the
-- header, the webhook falls back to ent_create_inbound_contact, so a
-- message is never dropped for it: a definer function, service role only,
-- that sets a transaction-local GUC around the insert.
--
-- Seats: account_invitations AFTER INSERT counts members + pending
-- invitations. profiles AFTER UPDATE (account_id changed) counts
-- members only, because the invitation being redeemed is still pending
-- at that moment (047 moves the profile first) and must not be counted
-- twice. A refused redeem rolls back, so the invite stays valid. Signup
-- (profiles INSERT) is never checked.
--
-- One trial per WhatsApp number (REQ-T2): whatsapp_config AFTER INSERT
-- OR UPDATE OF phone_number_id records every number connected while the
-- switch is on (N-8). It never raises: a claim failure must not break
-- saving the WhatsApp configuration.
--
-- api_keys.plan_suspended_at: excess keys after a downgrade are
-- suspended, not revoked. RLS gives admins UPDATE on api_keys, so a
-- guard trigger (always on, it enforces nothing about plans) makes the
-- column read-only for API roles; only the 067 definer functions, which
-- run as the owner, can change it.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS, CREATE OR REPLACE, DROP TRIGGER
-- IF EXISTS before CREATE.
-- ============================================================

-- ------------------------------------------------------------
-- New columns (both additive; NULL for every existing row)
-- ------------------------------------------------------------
ALTER TABLE public.broadcasts
  ADD COLUMN IF NOT EXISTS paused_reason TEXT;
ALTER TABLE public.broadcasts
  DROP CONSTRAINT IF EXISTS broadcasts_paused_reason_check;
ALTER TABLE public.broadcasts
  ADD CONSTRAINT broadcasts_paused_reason_check CHECK (paused_reason IN ('plan_limit'));

ALTER TABLE public.api_keys
  ADD COLUMN IF NOT EXISTS plan_suspended_at TIMESTAMPTZ;

-- ------------------------------------------------------------
-- api_keys.plan_suspended_at is not client-writable
-- ------------------------------------------------------------
-- SECURITY INVOKER on purpose: current_user is the API role here, and
-- is the owner when the write comes from a 067 definer function.
CREATE OR REPLACE FUNCTION public.api_keys_guard_plan_suspended()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon') THEN
    IF TG_OP = 'INSERT' THEN
      NEW.plan_suspended_at := NULL;
    ELSE
      NEW.plan_suspended_at := OLD.plan_suspended_at;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS api_keys_guard_plan_suspended ON public.api_keys;
CREATE TRIGGER api_keys_guard_plan_suspended
  BEFORE INSERT OR UPDATE ON public.api_keys
  FOR EACH ROW EXECUTE FUNCTION public.api_keys_guard_plan_suspended();

-- ------------------------------------------------------------
-- Shared count check
-- ------------------------------------------------------------
-- p_count_sql takes the account as $1 and must count usage INCLUDING
-- the statement's own rows. p_zero_is_flag: a limit of 0 means "this
-- plan has no such feature" (API keys, webhooks; D-14), reported as
-- plan_feature_unavailable. p_added = rows the statement added, so the
-- reported usage is what the account had before it.
CREATE OR REPLACE FUNCTION public._ent_enforce_count(
  p_account UUID,
  p_resource TEXT,
  p_limit_key TEXT,
  p_count_sql TEXT,
  p_zero_is_flag BOOLEAN DEFAULT false,
  p_check_state BOOLEAN DEFAULT true,
  p_added BIGINT DEFAULT 1
) RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ent JSONB;
  v_limit BIGINT;
  v_count BIGINT;
BEGIN
  PERFORM _ent_lock(p_account, p_resource);
  v_ent := account_entitlements(p_account);
  IF p_check_state THEN
    PERFORM _ent_assert_state(v_ent, p_resource);
  END IF;
  v_limit := (v_ent->'limits'->>p_limit_key)::bigint;
  IF p_zero_is_flag AND v_limit = 0 THEN
    PERFORM _ent_raise('plan_feature_unavailable', p_resource, NULL, NULL, 'not_on_plan');
  END IF;
  EXECUTE p_count_sql INTO v_count USING p_account;
  IF v_count > v_limit THEN
    PERFORM _ent_raise('plan_limit_reached', p_resource, greatest(v_count - p_added, 0), v_limit);
  END IF;
END;
$$;

-- ------------------------------------------------------------
-- contacts (R2), with the inbound exemption
-- ------------------------------------------------------------
-- Separate function so the pgTAP suite can assert it directly. Reads
-- PostgREST's per-request GUCs; a malformed value means "not exempt".
CREATE OR REPLACE FUNCTION public._ent_is_inbound_request()
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
BEGIN
  IF current_setting('wacrm.inbound_contact', true) = '1' THEN
    RETURN true;
  END IF;
  RETURN coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role', '') = 'service_role'
     AND coalesce(nullif(current_setting('request.headers', true), '')::jsonb->>'x-wacrm-inbound', '') = '1';
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END;
$$;

CREATE OR REPLACE FUNCTION public.ent_contacts_limit()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account UUID;
BEGIN
  IF NOT entitlements_enabled() OR _ent_is_inbound_request() THEN
    RETURN NULL;
  END IF;
  FOR v_account IN SELECT DISTINCT account_id FROM new_rows WHERE account_id IS NOT NULL LOOP
    PERFORM _ent_enforce_count(v_account, 'contacts', 'contacts_max',
      'SELECT count(*) FROM contacts WHERE account_id = $1', false, true,
      (SELECT count(*) FROM new_rows WHERE account_id = v_account));
  END LOOP;
  RETURN NULL;
END;
$$;

-- The webhook's fallback (see the header). Inserts exactly the keys
-- given, so column defaults still apply. Service role only; PostgREST
-- runs each request in its own transaction, so the GUC can't outlive this.
CREATE OR REPLACE FUNCTION public.ent_create_inbound_contact(p_row JSONB)
RETURNS public.contacts
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cols TEXT;
  v_row contacts%ROWTYPE;
BEGIN
  IF p_row IS NULL OR jsonb_typeof(p_row) <> 'object' OR NOT p_row ? 'account_id' THEN
    RAISE EXCEPTION 'ent_create_inbound_contact: invalid row' USING ERRCODE = '22023';
  END IF;
  SELECT string_agg(format('%I', a.attname), ', ') INTO v_cols
  FROM pg_attribute a
  WHERE a.attrelid = 'public.contacts'::regclass
    AND a.attnum > 0 AND NOT a.attisdropped
    AND p_row ? a.attname::text;

  PERFORM set_config('wacrm.inbound_contact', '1', true);
  EXECUTE format(
    'INSERT INTO contacts (%1$s) SELECT %1$s FROM jsonb_populate_record(NULL::contacts, $1) RETURNING *',
    v_cols
  ) INTO v_row USING p_row;
  PERFORM set_config('wacrm.inbound_contact', '', true);
  RETURN v_row;
END;
$$;

-- ------------------------------------------------------------
-- Seats (R1)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ent_invitations_seats()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account UUID;
BEGIN
  IF NOT entitlements_enabled() THEN
    RETURN NULL;
  END IF;
  FOR v_account IN SELECT DISTINCT account_id FROM new_rows LOOP
    PERFORM _ent_enforce_count(v_account, 'seats', 'seats_max',
      'SELECT public._ent_seats($1)');
  END LOOP;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.ent_profiles_seats()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account UUID;
BEGIN
  IF NOT entitlements_enabled() THEN
    RETURN NULL;
  END IF;
  FOR v_account IN
    SELECT DISTINCT n.account_id
    FROM new_rows n JOIN old_rows o ON o.user_id = n.user_id
    WHERE n.account_id IS NOT NULL AND n.account_id IS DISTINCT FROM o.account_id
  LOOP
    -- No state check: "existing members keep signing in", and joining
    -- is limited only by the seat maximum.
    PERFORM _ent_enforce_count(v_account, 'seats', 'seats_max',
      'SELECT count(*) FROM profiles WHERE account_id = $1', false, false);
  END LOOP;
  RETURN NULL;
END;
$$;

-- ------------------------------------------------------------
-- Broadcast pre-flight (R3). Metering itself happens at the Meta call
-- (entitlement_consume); this refuses a start that cannot fit.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ent_broadcasts_preflight()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ent JSONB;
  v_limit BIGINT;
  v_used BIGINT;
  v_remaining BIGINT;
BEGIN
  IF NEW.status IS DISTINCT FROM 'sending' OR NOT entitlements_enabled() THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'sending' THEN
    RETURN NEW;
  END IF;

  v_ent := account_entitlements(NEW.account_id);
  PERFORM _ent_assert_state(v_ent, 'broadcast_recipients');

  -- Resume of a finished campaign: only the state applies here, and
  -- each batch is metered as it goes out.
  IF TG_OP = 'UPDATE' AND OLD.status NOT IN ('draft', 'scheduled') THEN
    RETURN NEW;
  END IF;

  v_limit := (v_ent->'limits'->>'broadcast_recipients_per_period')::bigint;
  SELECT coalesce((
    SELECT used FROM account_usage_counters
    WHERE account_id = NEW.account_id AND resource = 'broadcast_recipients'
      AND period_start = (v_ent->>'period_start')::timestamptz), 0)
  INTO v_used;
  v_remaining := greatest(v_limit - v_used, 0);

  IF coalesce(NEW.total_recipients, 0) > v_remaining THEN
    PERFORM _ent_raise('plan_limit_reached', 'broadcast_recipients', v_used, v_limit, NULL,
      jsonb_build_object(
        'requested', NEW.total_recipients,
        'remaining', v_remaining,
        'resets_at', v_ent->'period_end'));
  END IF;
  RETURN NEW;
END;
$$;

-- ------------------------------------------------------------
-- Automations (R4): active count + fair-use total
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ent_automations_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account UUID;
BEGIN
  IF NOT entitlements_enabled() THEN
    RETURN NULL;
  END IF;
  FOR v_account IN SELECT DISTINCT account_id FROM new_rows WHERE account_id IS NOT NULL LOOP
    PERFORM _ent_enforce_count(v_account, 'automations_total', 'automations_total_max',
      'SELECT count(*) FROM automations WHERE account_id = $1');
    IF EXISTS (SELECT 1 FROM new_rows WHERE account_id = v_account AND is_active) THEN
      PERFORM _ent_enforce_count(v_account, 'automations_active', 'automations_active_max',
        'SELECT count(*) FROM automations WHERE account_id = $1 AND is_active');
    END IF;
  END LOOP;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.ent_automations_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account UUID;
BEGIN
  IF NOT entitlements_enabled() THEN
    RETURN NULL;
  END IF;
  FOR v_account IN
    SELECT DISTINCT n.account_id
    FROM new_rows n JOIN old_rows o ON o.id = n.id
    WHERE n.is_active AND NOT o.is_active AND n.account_id IS NOT NULL
  LOOP
    PERFORM _ent_enforce_count(v_account, 'automations_active', 'automations_active_max',
      'SELECT count(*) FROM automations WHERE account_id = $1 AND is_active');
  END LOOP;
  RETURN NULL;
END;
$$;

-- ------------------------------------------------------------
-- Flows (R5): active count + fair-use total
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ent_flows_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account UUID;
BEGIN
  IF NOT entitlements_enabled() THEN
    RETURN NULL;
  END IF;
  FOR v_account IN SELECT DISTINCT account_id FROM new_rows WHERE account_id IS NOT NULL LOOP
    PERFORM _ent_enforce_count(v_account, 'flows_total', 'flows_total_max',
      'SELECT count(*) FROM flows WHERE account_id = $1');
    IF EXISTS (SELECT 1 FROM new_rows WHERE account_id = v_account AND status = 'active') THEN
      PERFORM _ent_enforce_count(v_account, 'flows_active', 'flows_active_max',
        'SELECT count(*) FROM flows WHERE account_id = $1 AND status = ''active''');
    END IF;
  END LOOP;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.ent_flows_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account UUID;
BEGIN
  IF NOT entitlements_enabled() THEN
    RETURN NULL;
  END IF;
  FOR v_account IN
    SELECT DISTINCT n.account_id
    FROM new_rows n JOIN old_rows o ON o.id = n.id
    WHERE n.status = 'active' AND o.status <> 'active' AND n.account_id IS NOT NULL
  LOOP
    PERFORM _ent_enforce_count(v_account, 'flows_active', 'flows_active_max',
      'SELECT count(*) FROM flows WHERE account_id = $1 AND status = ''active''');
  END LOOP;
  RETURN NULL;
END;
$$;

-- ------------------------------------------------------------
-- API keys (R7) and webhook endpoints (R8): 0 means not on the plan
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ent_api_keys_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account UUID;
BEGIN
  IF NOT entitlements_enabled() THEN
    RETURN NULL;
  END IF;
  FOR v_account IN SELECT DISTINCT account_id FROM new_rows LOOP
    PERFORM _ent_enforce_count(v_account, 'api_keys', 'api_keys_max',
      'SELECT count(*) FROM api_keys WHERE account_id = $1 AND revoked_at IS NULL
         AND (expires_at IS NULL OR expires_at > now()) AND plan_suspended_at IS NULL',
      true);
  END LOOP;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.ent_webhooks_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account UUID;
BEGIN
  IF NOT entitlements_enabled() THEN
    RETURN NULL;
  END IF;
  FOR v_account IN SELECT DISTINCT account_id FROM new_rows WHERE is_active LOOP
    PERFORM _ent_enforce_count(v_account, 'webhook_endpoints', 'webhook_endpoints_max',
      'SELECT count(*) FROM webhook_endpoints WHERE account_id = $1 AND is_active', true);
  END LOOP;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.ent_webhooks_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account UUID;
BEGIN
  IF NOT entitlements_enabled() THEN
    RETURN NULL;
  END IF;
  FOR v_account IN
    SELECT DISTINCT n.account_id
    FROM new_rows n JOIN old_rows o ON o.id = n.id
    WHERE n.is_active AND NOT o.is_active
  LOOP
    PERFORM _ent_enforce_count(v_account, 'webhook_endpoints', 'webhook_endpoints_max',
      'SELECT count(*) FROM webhook_endpoints WHERE account_id = $1 AND is_active', true);
  END LOOP;
  RETURN NULL;
END;
$$;

-- ------------------------------------------------------------
-- AI (R9): auto-reply flag, knowledge base documents
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ent_ai_configs_flag()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ent JSONB;
BEGIN
  IF NOT NEW.auto_reply_enabled OR NOT entitlements_enabled() THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.auto_reply_enabled THEN
    RETURN NEW;
  END IF;
  v_ent := account_entitlements(NEW.account_id);
  PERFORM _ent_assert_state(v_ent, 'ai_auto_reply');
  IF NOT (v_ent->'limits'->>'ai_auto_reply')::boolean THEN
    PERFORM _ent_raise('plan_feature_unavailable', 'ai_auto_reply', NULL, NULL, 'not_on_plan');
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.ent_kb_documents_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account UUID;
BEGIN
  IF NOT entitlements_enabled() THEN
    RETURN NULL;
  END IF;
  FOR v_account IN SELECT DISTINCT account_id FROM new_rows LOOP
    PERFORM _ent_enforce_count(v_account, 'kb_documents', 'kb_documents_max',
      'SELECT count(*) FROM ai_knowledge_documents WHERE account_id = $1');
  END LOOP;
  RETURN NULL;
END;
$$;

-- ------------------------------------------------------------
-- Pipelines (R11)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ent_pipelines_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account UUID;
BEGIN
  IF NOT entitlements_enabled() THEN
    RETURN NULL;
  END IF;
  FOR v_account IN SELECT DISTINCT account_id FROM new_rows WHERE account_id IS NOT NULL LOOP
    PERFORM _ent_enforce_count(v_account, 'pipelines', 'pipelines_max',
      'SELECT count(*) FROM pipelines WHERE account_id = $1');
  END LOOP;
  RETURN NULL;
END;
$$;

-- ------------------------------------------------------------
-- One trial per WhatsApp number (REQ-T2). Never raises.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ent_whatsapp_trial_claim()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_first UUID;
BEGIN
  BEGIN
    IF NOT entitlements_enabled()
       OR NEW.account_id IS NULL
       OR coalesce(NEW.phone_number_id, '') = '' THEN
      RETURN NULL;
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.phone_number_id IS NOT DISTINCT FROM NEW.phone_number_id THEN
      RETURN NULL;
    END IF;

    INSERT INTO trial_number_claims (phone_number_id, first_account_id)
    VALUES (NEW.phone_number_id, NEW.account_id)
    ON CONFLICT (phone_number_id) DO NOTHING;
    IF FOUND THEN
      RETURN NULL;
    END IF;

    SELECT first_account_id INTO v_first
    FROM trial_number_claims WHERE phone_number_id = NEW.phone_number_id;

    -- NULL first account: the claimant was deleted. Still a reuse.
    IF v_first IS DISTINCT FROM NEW.account_id THEN
      UPDATE account_subscriptions
      SET state = 'locked', state_reason = 'trial_number_reused',
          state_changed_at = now(), trial_ends_at = now()
      WHERE account_id = NEW.account_id AND plan_key = 'trial' AND state = 'trialing';
      IF FOUND THEN
        PERFORM _ent_audit(NEW.account_id, 'system', 'trial_number_reused',
          jsonb_build_object('state', 'trialing'),
          jsonb_build_object('state', 'locked', 'first_account_id', v_first),
          'trial_number_reused');
      END IF;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'ent_whatsapp_trial_claim(%) failed: % %', NEW.account_id, SQLSTATE, SQLERRM;
  END;
  RETURN NULL;
END;
$$;

-- ------------------------------------------------------------
-- Inbound media gate (D-17): mirror up to 110% of the storage limit.
-- Above it the webhook stores the message with the Meta media proxy
-- URL instead. Hard upload enforcement is Phase 5.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.entitlement_can_mirror_media(p_account UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_limit NUMERIC;
BEGIN
  IF NOT entitlements_enabled() THEN
    RETURN true;
  END IF;
  v_limit := (account_entitlements(p_account)->'limits'->>'storage_bytes_max')::numeric;
  RETURN _ent_storage_bytes(p_account) < v_limit * 1.1;
END;
$$;

-- ------------------------------------------------------------
-- Triggers
-- ------------------------------------------------------------
DROP TRIGGER IF EXISTS ent_contacts_limit ON public.contacts;
CREATE TRIGGER ent_contacts_limit AFTER INSERT ON public.contacts
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION public.ent_contacts_limit();

DROP TRIGGER IF EXISTS ent_invitations_seats ON public.account_invitations;
CREATE TRIGGER ent_invitations_seats AFTER INSERT ON public.account_invitations
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION public.ent_invitations_seats();

DROP TRIGGER IF EXISTS ent_profiles_seats ON public.profiles;
CREATE TRIGGER ent_profiles_seats AFTER UPDATE ON public.profiles
  REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION public.ent_profiles_seats();

DROP TRIGGER IF EXISTS ent_broadcasts_preflight ON public.broadcasts;
CREATE TRIGGER ent_broadcasts_preflight BEFORE INSERT OR UPDATE OF status ON public.broadcasts
  FOR EACH ROW EXECUTE FUNCTION public.ent_broadcasts_preflight();

DROP TRIGGER IF EXISTS ent_automations_insert ON public.automations;
CREATE TRIGGER ent_automations_insert AFTER INSERT ON public.automations
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION public.ent_automations_insert();

DROP TRIGGER IF EXISTS ent_automations_update ON public.automations;
CREATE TRIGGER ent_automations_update AFTER UPDATE ON public.automations
  REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION public.ent_automations_update();

DROP TRIGGER IF EXISTS ent_flows_insert ON public.flows;
CREATE TRIGGER ent_flows_insert AFTER INSERT ON public.flows
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION public.ent_flows_insert();

DROP TRIGGER IF EXISTS ent_flows_update ON public.flows;
CREATE TRIGGER ent_flows_update AFTER UPDATE ON public.flows
  REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION public.ent_flows_update();

DROP TRIGGER IF EXISTS ent_api_keys_insert ON public.api_keys;
CREATE TRIGGER ent_api_keys_insert AFTER INSERT ON public.api_keys
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION public.ent_api_keys_insert();

DROP TRIGGER IF EXISTS ent_webhooks_insert ON public.webhook_endpoints;
CREATE TRIGGER ent_webhooks_insert AFTER INSERT ON public.webhook_endpoints
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION public.ent_webhooks_insert();

DROP TRIGGER IF EXISTS ent_webhooks_update ON public.webhook_endpoints;
CREATE TRIGGER ent_webhooks_update AFTER UPDATE ON public.webhook_endpoints
  REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION public.ent_webhooks_update();

DROP TRIGGER IF EXISTS ent_ai_configs_flag ON public.ai_configs;
CREATE TRIGGER ent_ai_configs_flag BEFORE INSERT OR UPDATE OF auto_reply_enabled ON public.ai_configs
  FOR EACH ROW EXECUTE FUNCTION public.ent_ai_configs_flag();

DROP TRIGGER IF EXISTS ent_kb_documents_insert ON public.ai_knowledge_documents;
CREATE TRIGGER ent_kb_documents_insert AFTER INSERT ON public.ai_knowledge_documents
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION public.ent_kb_documents_insert();

DROP TRIGGER IF EXISTS ent_pipelines_insert ON public.pipelines;
CREATE TRIGGER ent_pipelines_insert AFTER INSERT ON public.pipelines
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION public.ent_pipelines_insert();

DROP TRIGGER IF EXISTS ent_whatsapp_trial_claim ON public.whatsapp_config;
CREATE TRIGGER ent_whatsapp_trial_claim AFTER INSERT OR UPDATE OF phone_number_id ON public.whatsapp_config
  FOR EACH ROW EXECUTE FUNCTION public.ent_whatsapp_trial_claim();

-- ------------------------------------------------------------
-- The switch
-- ------------------------------------------------------------
-- Enable / disable every enforcement trigger. ENABLE/DISABLE TRIGGER
-- takes a SHARE ROW EXCLUSIVE lock on each table; flip it off-peak.
CREATE OR REPLACE FUNCTION public._ent_toggle_triggers(p_enabled BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('contacts', 'ent_contacts_limit'),
      ('account_invitations', 'ent_invitations_seats'),
      ('profiles', 'ent_profiles_seats'),
      ('broadcasts', 'ent_broadcasts_preflight'),
      ('automations', 'ent_automations_insert'),
      ('automations', 'ent_automations_update'),
      ('flows', 'ent_flows_insert'),
      ('flows', 'ent_flows_update'),
      ('api_keys', 'ent_api_keys_insert'),
      ('webhook_endpoints', 'ent_webhooks_insert'),
      ('webhook_endpoints', 'ent_webhooks_update'),
      ('ai_configs', 'ent_ai_configs_flag'),
      ('ai_knowledge_documents', 'ent_kb_documents_insert'),
      ('pipelines', 'ent_pipelines_insert'),
      ('whatsapp_config', 'ent_whatsapp_trial_claim')
    ) AS t(tbl, trg) LOOP
    EXECUTE format('ALTER TABLE public.%I %s TRIGGER %I',
                   r.tbl, CASE WHEN p_enabled THEN 'ENABLE' ELSE 'DISABLE' END, r.trg);
  END LOOP;
END;
$$;

-- Operator switch (REQ-H1/H4). The env var ENTITLEMENTS_ENABLED is the
-- app half; docs/entitlements.md says to set both together.
CREATE OR REPLACE FUNCTION public.entitlements_set_enabled(
  p_enabled BOOLEAN,
  p_actor TEXT,
  p_reason TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  ps platform_settings%ROWTYPE;
BEGIN
  PERFORM _ent_require_actor(p_actor);
  IF p_enabled IS NULL THEN
    RAISE EXCEPTION 'enabled is required' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO ps FROM platform_settings WHERE id FOR UPDATE;
  UPDATE platform_settings
  SET entitlements_enabled = p_enabled,
      entitlements_first_enabled_at = CASE WHEN p_enabled
        THEN coalesce(entitlements_first_enabled_at, now())
        ELSE entitlements_first_enabled_at END,
      updated_at = now()
  WHERE id
  RETURNING * INTO ps;
  PERFORM _ent_toggle_triggers(p_enabled);
  -- Numbers connected before go-live, or while the switch was off, are
  -- claimed too, so an existing customer's number can't start a fresh
  -- trial on another account (N-8).
  IF p_enabled THEN
    INSERT INTO trial_number_claims (phone_number_id, first_account_id)
    SELECT phone_number_id, account_id FROM whatsapp_config
    WHERE account_id IS NOT NULL AND coalesce(phone_number_id, '') <> ''
    ON CONFLICT (phone_number_id) DO NOTHING;
  END IF;
  PERFORM _ent_audit(NULL, p_actor, 'set_enabled', NULL,
    jsonb_build_object('enabled', p_enabled, 'first_enabled_at', ps.entitlements_first_enabled_at),
    p_reason);
  RETURN jsonb_build_object(
    'enabled', ps.entitlements_enabled,
    'first_enabled_at', ps.entitlements_first_enabled_at);
END;
$$;

-- ------------------------------------------------------------
-- Ownership and grants
-- ------------------------------------------------------------
DO $$
DECLARE
  f TEXT;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public._ent_enforce_count(uuid,text,text,text,boolean,boolean,bigint)',
    'public._ent_is_inbound_request()',
    'public.entitlement_can_mirror_media(uuid)',
    'public.ent_create_inbound_contact(jsonb)',
    'public._ent_toggle_triggers(boolean)',
    'public.entitlements_set_enabled(boolean,text,text)',
    'public.ent_contacts_limit()',
    'public.ent_invitations_seats()',
    'public.ent_profiles_seats()',
    'public.ent_broadcasts_preflight()',
    'public.ent_automations_insert()',
    'public.ent_automations_update()',
    'public.ent_flows_insert()',
    'public.ent_flows_update()',
    'public.ent_api_keys_insert()',
    'public.ent_webhooks_insert()',
    'public.ent_webhooks_update()',
    'public.ent_ai_configs_flag()',
    'public.ent_kb_documents_insert()',
    'public.ent_pipelines_insert()',
    'public.ent_whatsapp_trial_claim()'
  ] LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO postgres', f);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
  -- The one entry point the operator route needs.
  GRANT EXECUTE ON FUNCTION public.entitlements_set_enabled(boolean, text, text) TO service_role;
  GRANT EXECUTE ON FUNCTION public._ent_is_inbound_request() TO service_role;
  GRANT EXECUTE ON FUNCTION public.entitlement_can_mirror_media(uuid) TO service_role;
  GRANT EXECUTE ON FUNCTION public.ent_create_inbound_contact(jsonb) TO service_role;
END $$;

ALTER FUNCTION public.api_keys_guard_plan_suspended() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.api_keys_guard_plan_suspended() FROM PUBLIC, anon;
-- SECURITY INVOKER trigger functions need EXECUTE only at CREATE
-- TRIGGER time, not at fire time, so no grant is required for the API
-- roles to fire it.
REVOKE ALL ON FUNCTION public.api_keys_guard_plan_suspended() FROM authenticated;

-- Ship disabled (or as the flag says, on a re-run against a live DB).
SELECT public._ent_toggle_triggers(public.entitlements_enabled());
