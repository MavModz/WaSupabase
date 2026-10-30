-- ============================================================
-- 067 — entitlements functions: resolution, usage, metering,
--        operator RPCs, lifecycle sweep
-- ============================================================
-- Builds on 066. Every function here is SECURITY DEFINER with a fixed
-- search_path and is executable by service_role ONLY: the app calls
-- them through the service-role client, and the 068 triggers call
-- them as their (postgres) owner. A customer — owner included —
-- calling an operator RPC gets 42501 (REQ-O1).
--
-- Resolution is LAZY, so correctness never depends on the cron
-- (REQ-S1): account_entitlements() reports
--   * a trialing account past trial_ends_at            → locked
--   * a past_due account past platform past_due_days   → restricted,
--     and past past_due_days + restricted_days          → locked
--   * a due scheduled plan change                      → the new plan
--   * legacy_beta past platform legacy_ends_at          → locked
-- entitlements_run_due() (called by the automations cron) only
-- MATERIALISES those transitions — with an audit row from actor
-- 'system' — and applies a due downgrade's deactivations.
--
-- Errors raised for the app (068 triggers use the same helper):
--   WA001 plan_limit_reached        count / period limit
--   WA002 plan_feature_unavailable  flag off, or state restricted/locked
--   WA003 downgrade_blocked         seats above the new plan's maximum
-- MESSAGE is the code; DETAIL is JSON {code, resource, usage, limit,
-- reason, …}. src/lib/entitlements/errors.ts parses it.
--
-- Downgrade application (_ent_apply_plan_limits) is SQL, not
-- TypeScript, so a plan change and its deactivations are one
-- transaction with one audit row. Each step does exactly what the
-- manual path does today:
--   automations       is_active = false (pending waits are left to the
--                     engine, as with a manual switch-off)
--   flows             status = 'draft' + active runs cancelled with
--                     end_reason 'flow_draft' (flows/[id]/activate)
--   api_keys          plan_suspended_at stamped, never revoked; an
--                     upgrade clears it up to the new limit (R7)
--   webhook_endpoints is_active = false, oldest first (R8)
--   AI auto-reply     auto_reply_enabled = false; conversations in bot
--                     mode get ai_autoreply_disabled + a fixed handoff
--                     note + the configured handoff agent (no LLM call)
-- Nothing is ever deleted (REQ-D3).
--
-- Idempotent: CREATE OR REPLACE everywhere; grants re-applied.
-- ============================================================

-- ------------------------------------------------------------
-- Switch (DB half)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.entitlements_enabled()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce((SELECT entitlements_enabled FROM platform_settings WHERE id), false);
$$;

-- ------------------------------------------------------------
-- Internal helpers
-- ------------------------------------------------------------

-- Raise a typed entitlement error. Never returns.
CREATE OR REPLACE FUNCTION public._ent_raise(
  p_code TEXT,
  p_resource TEXT,
  p_usage BIGINT,
  p_limit BIGINT,
  p_reason TEXT DEFAULT NULL,
  p_extra JSONB DEFAULT '{}'::jsonb
) RETURNS VOID
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  RAISE EXCEPTION USING
    ERRCODE = CASE p_code
                WHEN 'plan_limit_reached' THEN 'WA001'
                WHEN 'plan_feature_unavailable' THEN 'WA002'
                ELSE 'WA003'
              END,
    MESSAGE = p_code,
    DETAIL = (jsonb_strip_nulls(jsonb_build_object(
                'code', p_code,
                'resource', p_resource,
                'usage', p_usage,
                'limit', p_limit,
                'reason', p_reason
              )) || coalesce(p_extra, '{}'::jsonb))::text;
END;
$$;

-- One audit row. Every operator / system change goes through here.
CREATE OR REPLACE FUNCTION public._ent_audit(
  p_account UUID,
  p_actor TEXT,
  p_action TEXT,
  p_old JSONB,
  p_new JSONB,
  p_reason TEXT
) RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  INSERT INTO entitlement_audit_log (account_id, actor, action, old_value, new_value, reason)
  VALUES (p_account, p_actor, p_action, p_old, p_new, p_reason);
$$;

-- Serialise check-then-act for one (account, resource) pair. The
-- caller's NEXT statement takes a fresh READ COMMITTED snapshot, so
-- it sees whatever a competing transaction committed before it
-- released this lock (REQ-X4).
CREATE OR REPLACE FUNCTION public._ent_lock(p_account UUID, p_resource TEXT)
RETURNS VOID
LANGUAGE sql
SET search_path = public
AS $$
  SELECT pg_advisory_xact_lock(hashtextextended('ent:' || p_account::text || ':' || p_resource, 0));
$$;

-- Usage period: the trial window on 'trial'; otherwise the billing
-- period when Phase 3 has set one and it is current; otherwise the
-- calendar month in UTC.
CREATE OR REPLACE FUNCTION public._ent_period(
  p_plan TEXT,
  p_trial_ends_at TIMESTAMPTZ,
  p_period_start TIMESTAMPTZ,
  p_period_end TIMESTAMPTZ,
  p_trial_days INTEGER,
  p_at TIMESTAMPTZ
) RETURNS TABLE (period_start TIMESTAMPTZ, period_end TIMESTAMPTZ)
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  v_month TIMESTAMP := date_trunc('month', p_at AT TIME ZONE 'UTC');
BEGIN
  IF p_plan = 'trial' AND p_trial_ends_at IS NOT NULL THEN
    period_start := coalesce(p_period_start, p_trial_ends_at - make_interval(days => coalesce(p_trial_days, 14)));
    period_end := p_trial_ends_at;
  ELSIF p_period_start IS NOT NULL AND p_period_end IS NOT NULL
        AND p_period_start <= p_at AND p_at < p_period_end THEN
    period_start := p_period_start;
    period_end := p_period_end;
  ELSE
    period_start := v_month AT TIME ZONE 'UTC';
    period_end := (v_month + INTERVAL '1 month') AT TIME ZONE 'UTC';
  END IF;
  RETURN NEXT;
END;
$$;

-- Limits for a plan with per-account overrides merged on top. Only
-- keys that are real limit columns are honoured.
CREATE OR REPLACE FUNCTION public._ent_plan_limits(p_plan TEXT, p_overrides JSONB)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_limits JSONB;
BEGIN
  SELECT to_jsonb(p) - ARRAY['key', 'name', 'sort_order', 'is_customer_plan', 'created_at', 'updated_at']
  INTO v_limits
  FROM plans p WHERE p.key = p_plan;
  IF v_limits IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN v_limits || coalesce((
    SELECT jsonb_object_agg(e.key, e.value)
    FROM jsonb_each(coalesce(p_overrides, '{}'::jsonb)) e
    WHERE v_limits ? e.key
  ), '{}'::jsonb);
END;
$$;

-- ------------------------------------------------------------
-- account_entitlements(account) → jsonb
--   {enabled, account_id, plan, plan_name, state, state_reason,
--    limits{…}, period_start, period_end, trial_ends_at,
--    scheduled_plan, scheduled_change_at, was_legacy_beta,
--    legacy_ends_at}
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.account_entitlements(p_account UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_now TIMESTAMPTZ := now();
  ps platform_settings%ROWTYPE;
  s account_subscriptions%ROWTYPE;
  v_found BOOLEAN;
  v_plan TEXT;
  v_state TEXT;
  v_reason TEXT;
  v_due BOOLEAN := false;
  v_limits JSONB;
  v_name TEXT;
  v_pstart TIMESTAMPTZ;
  v_pend TIMESTAMPTZ;
BEGIN
  SELECT * INTO ps FROM platform_settings WHERE id;
  SELECT * INTO s FROM account_subscriptions WHERE account_id = p_account;
  v_found := FOUND;
  IF NOT v_found THEN
    -- Should not happen (066 backfill + accounts trigger). Treat as
    -- grandfathered rather than locking someone out.
    s.plan_key := 'legacy_beta';
    s.state := 'active';
    s.state_reason := 'no_subscription_row';
    s.state_changed_at := v_now;
    s.limit_overrides := '{}'::jsonb;
    s.was_legacy_beta := true;
  END IF;

  v_plan := s.plan_key;
  v_state := s.state;
  v_reason := s.state_reason;

  IF s.scheduled_plan_key IS NOT NULL AND s.scheduled_change_at <= v_now THEN
    v_plan := s.scheduled_plan_key;
    v_due := true;
  END IF;

  IF v_state = 'trialing' THEN
    IF v_plan <> 'trial' THEN
      v_state := 'active';
    ELSIF s.trial_ends_at IS NOT NULL AND s.trial_ends_at <= v_now THEN
      v_state := 'locked';
      v_reason := 'trial_ended';
    END IF;
  ELSIF v_state = 'past_due'
        AND s.state_changed_at + make_interval(days => ps.past_due_days) <= v_now THEN
    IF s.state_changed_at + make_interval(days => ps.past_due_days + ps.restricted_days) <= v_now THEN
      v_state := 'locked';
      v_reason := 'grace_expired';
    ELSE
      v_state := 'restricted';
      v_reason := 'grace_restricted';
    END IF;
  ELSIF v_state = 'restricted' AND s.state_reason = 'grace_restricted'
        AND s.state_changed_at + make_interval(days => ps.restricted_days) <= v_now THEN
    v_state := 'locked';
    v_reason := 'grace_expired';
  END IF;

  IF v_plan = 'legacy_beta' AND ps.legacy_ends_at IS NOT NULL AND ps.legacy_ends_at <= v_now THEN
    v_state := 'locked';
    v_reason := 'legacy_ended';
  END IF;

  v_limits := _ent_plan_limits(v_plan, s.limit_overrides);
  IF v_limits IS NULL THEN
    v_plan := 'legacy_beta';
    v_limits := _ent_plan_limits('legacy_beta', '{}'::jsonb);
  END IF;
  SELECT name INTO v_name FROM plans WHERE key = v_plan;

  SELECT pr.period_start, pr.period_end INTO v_pstart, v_pend
  FROM _ent_period(
    v_plan, s.trial_ends_at,
    CASE WHEN v_due THEN NULL ELSE s.current_period_start END,
    CASE WHEN v_due THEN NULL ELSE s.current_period_end END,
    ps.trial_days, v_now
  ) pr;

  RETURN jsonb_build_object(
    'enabled', coalesce(ps.entitlements_enabled, false),
    'account_id', p_account,
    'plan', v_plan,
    'plan_name', v_name,
    'state', v_state,
    'state_reason', v_reason,
    'limits', v_limits,
    'period_start', v_pstart,
    'period_end', v_pend,
    'trial_ends_at', s.trial_ends_at,
    'scheduled_plan', CASE WHEN v_due THEN NULL ELSE s.scheduled_plan_key END,
    'scheduled_change_at', CASE WHEN v_due THEN NULL ELSE s.scheduled_change_at END,
    'was_legacy_beta', coalesce(s.was_legacy_beta, false),
    'legacy_ends_at', ps.legacy_ends_at
  );
END;
$$;

-- Fail with WA002 when the state forbids creating / activating.
CREATE OR REPLACE FUNCTION public._ent_assert_state(p_ent JSONB, p_resource TEXT)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF p_ent->>'state' = 'restricted' THEN
    PERFORM _ent_raise('plan_feature_unavailable', p_resource, NULL, NULL, 'account_restricted');
  ELSIF p_ent->>'state' = 'locked' THEN
    PERFORM _ent_raise('plan_feature_unavailable', p_resource, NULL, NULL, 'account_locked');
  END IF;
END;
$$;

-- ------------------------------------------------------------
-- Usage
-- ------------------------------------------------------------

-- Members plus pending, unexpired invitations (D-07).
CREATE OR REPLACE FUNCTION public._ent_seats(p_account UUID)
RETURNS BIGINT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT (SELECT count(*) FROM profiles WHERE account_id = p_account)
       + (SELECT count(*) FROM account_invitations
          WHERE account_id = p_account AND accepted_at IS NULL AND expires_at > now());
$$;

-- Bytes in chat-media + flow-media under account-<id>/ (R10). The
-- storage schema is Supabase's; guard for databases without it.
CREATE OR REPLACE FUNCTION public._ent_storage_bytes(p_account UUID)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_bytes BIGINT;
BEGIN
  IF to_regclass('storage.objects') IS NULL THEN
    RETURN 0;
  END IF;
  EXECUTE $q$
    SELECT coalesce(sum(CASE WHEN (metadata->>'size') ~ '^[0-9]+$'
                             THEN (metadata->>'size')::bigint ELSE 0 END), 0)
    FROM storage.objects
    WHERE bucket_id IN ('chat-media', 'flow-media')
      AND name LIKE $1
  $q$ INTO v_bytes USING 'account-' || p_account::text || '/%';
  RETURN coalesce(v_bytes, 0);
END;
$$;

CREATE OR REPLACE FUNCTION public.account_usage(p_account UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ent JSONB := account_entitlements(p_account);
  v_members BIGINT;
  v_pending BIGINT;
BEGIN
  SELECT count(*) INTO v_members FROM profiles WHERE account_id = p_account;
  SELECT count(*) INTO v_pending FROM account_invitations
  WHERE account_id = p_account AND accepted_at IS NULL AND expires_at > now();

  RETURN jsonb_build_object(
    'period_start', v_ent->'period_start',
    'period_end', v_ent->'period_end',
    'seats', v_members + v_pending,
    'seats_members', v_members,
    'seats_pending', v_pending,
    'contacts', (SELECT count(*) FROM contacts WHERE account_id = p_account),
    'broadcast_recipients', coalesce((
      SELECT used FROM account_usage_counters
      WHERE account_id = p_account AND resource = 'broadcast_recipients'
        AND period_start = (v_ent->>'period_start')::timestamptz), 0),
    'automations_active', (SELECT count(*) FROM automations WHERE account_id = p_account AND is_active),
    'automations_total', (SELECT count(*) FROM automations WHERE account_id = p_account),
    'flows_active', (SELECT count(*) FROM flows WHERE account_id = p_account AND status = 'active'),
    'flows_total', (SELECT count(*) FROM flows WHERE account_id = p_account),
    'whatsapp_numbers', (SELECT count(*) FROM whatsapp_config WHERE account_id = p_account AND phone_number_id IS NOT NULL),
    'api_keys', (SELECT count(*) FROM api_keys WHERE account_id = p_account AND revoked_at IS NULL
                   AND (expires_at IS NULL OR expires_at > now()) AND plan_suspended_at IS NULL),
    'webhook_endpoints', (SELECT count(*) FROM webhook_endpoints WHERE account_id = p_account AND is_active),
    'kb_documents', (SELECT count(*) FROM ai_knowledge_documents WHERE account_id = p_account),
    'pipelines', (SELECT count(*) FROM pipelines WHERE account_id = p_account),
    'storage_bytes', _ent_storage_bytes(p_account)
  );
END;
$$;

-- ------------------------------------------------------------
-- Broadcast metering: reserve before the Meta call, refund after.
-- Returns how many of p_requested may be sent now.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.entitlement_consume(
  p_account UUID,
  p_resource TEXT,
  p_requested INTEGER
) RETURNS TABLE (granted INTEGER, period_start TIMESTAMPTZ, used BIGINT, limit_value BIGINT, reason TEXT)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
  v_ent JSONB;
  v_ps TIMESTAMPTZ;
  v_lim BIGINT;
  v_used BIGINT;
  v_grant INTEGER;
BEGIN
  IF p_resource IS DISTINCT FROM 'broadcast_recipients' THEN
    RAISE EXCEPTION 'entitlement_consume: unknown metered resource %', p_resource USING ERRCODE = '22023';
  END IF;
  IF p_account IS NULL OR p_requested IS NULL OR p_requested < 0 THEN
    RAISE EXCEPTION 'entitlement_consume: invalid arguments' USING ERRCODE = '22023';
  END IF;

  IF NOT entitlements_enabled() THEN
    RETURN QUERY SELECT p_requested, NULL::timestamptz, NULL::bigint, NULL::bigint, 'disabled'::text;
    RETURN;
  END IF;

  v_ent := account_entitlements(p_account);
  v_ps := (v_ent->>'period_start')::timestamptz;
  v_lim := (v_ent->'limits'->>'broadcast_recipients_per_period')::bigint;

  INSERT INTO account_usage_counters AS c (account_id, resource, period_start, used)
  VALUES (p_account, p_resource, v_ps, 0)
  ON CONFLICT (account_id, resource, period_start) DO NOTHING;

  SELECT c.used INTO v_used FROM account_usage_counters c
  WHERE c.account_id = p_account AND c.resource = p_resource AND c.period_start = v_ps
  FOR UPDATE;

  IF v_ent->>'state' IN ('restricted', 'locked') THEN
    RETURN QUERY SELECT 0, v_ps, v_used, v_lim, ('account_' || (v_ent->>'state'))::text;
    RETURN;
  END IF;

  v_grant := least(p_requested::bigint, greatest(v_lim - v_used, 0))::int;
  IF v_grant > 0 THEN
    UPDATE account_usage_counters c
    SET used = c.used + v_grant, updated_at = now()
    WHERE c.account_id = p_account AND c.resource = p_resource AND c.period_start = v_ps;
  END IF;

  RETURN QUERY SELECT v_grant, v_ps, v_used + v_grant, v_lim,
    CASE WHEN v_grant < p_requested THEN 'limit' ELSE NULL END::text;
END;
$$;

CREATE OR REPLACE FUNCTION public.entitlement_release(
  p_account UUID,
  p_resource TEXT,
  p_period_start TIMESTAMPTZ,
  p_count INTEGER
) RETURNS BIGINT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_used BIGINT;
BEGIN
  IF p_period_start IS NULL OR p_count IS NULL OR p_count <= 0 THEN
    RETURN NULL;
  END IF;
  UPDATE account_usage_counters
  SET used = greatest(used - p_count, 0), updated_at = now()
  WHERE account_id = p_account AND resource = p_resource AND period_start = p_period_start
  RETURNING used INTO v_used;
  RETURN v_used;
END;
$$;

-- ------------------------------------------------------------
-- Downgrade / plan-change application
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._ent_keep_ids(p_keep JSONB, p_key TEXT)
RETURNS TEXT[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE WHEN jsonb_typeof(p_keep->p_key) = 'array'
              THEN ARRAY(SELECT jsonb_array_elements_text(p_keep->p_key))
              ELSE NULL END;
$$;

-- Bring active resources down to the account's CURRENT limits.
-- p_keep: optional owner selections; a present array for a resource
-- means "keep exactly these (up to the limit)", absent means the
-- default rule. Returns a summary of what changed.
CREATE OR REPLACE FUNCTION public._ent_apply_plan_limits(p_account UUID, p_keep JSONB)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_lim JSONB := (account_entitlements(p_account))->'limits';
  v_keep TEXT[];
  v_auto INTEGER := 0;
  v_flows INTEGER := 0;
  v_runs INTEGER := 0;
  v_keys_suspended INTEGER := 0;
  v_keys_restored INTEGER := 0;
  v_hooks INTEGER := 0;
  v_ai INTEGER := 0;
  v_convs INTEGER := 0;
  v_flow_ids UUID[];
BEGIN
  p_keep := coalesce(p_keep, '{}'::jsonb);

  -- R4: automations — selection, else N most recently updated.
  v_keep := _ent_keep_ids(p_keep, 'automations');
  WITH ranked AS (
    SELECT id, row_number() OVER (
             ORDER BY (v_keep IS NOT NULL AND id::text = ANY (v_keep)) DESC,
                      updated_at DESC NULLS LAST, created_at DESC, id) AS rn,
           (v_keep IS NULL OR id::text = ANY (v_keep)) AS eligible
    FROM automations WHERE account_id = p_account AND is_active
  )
  UPDATE automations a SET is_active = false
  FROM ranked r
  WHERE a.id = r.id AND (r.rn > (v_lim->>'automations_active_max')::int OR NOT r.eligible);
  GET DIAGNOSTICS v_auto = ROW_COUNT;

  -- R5: flows — same rule; deactivation = draft + cancel active runs.
  v_keep := _ent_keep_ids(p_keep, 'flows');
  WITH ranked AS (
    SELECT id, row_number() OVER (
             ORDER BY (v_keep IS NOT NULL AND id::text = ANY (v_keep)) DESC,
                      updated_at DESC NULLS LAST, created_at DESC, id) AS rn,
           (v_keep IS NULL OR id::text = ANY (v_keep)) AS eligible
    FROM flows WHERE account_id = p_account AND status = 'active'
  ), off AS (
    UPDATE flows f SET status = 'draft', updated_at = now()
    FROM ranked r
    WHERE f.id = r.id AND (r.rn > (v_lim->>'flows_active_max')::int OR NOT r.eligible)
    RETURNING f.id
  )
  SELECT array_agg(id) INTO v_flow_ids FROM off;
  v_flows := coalesce(array_length(v_flow_ids, 1), 0);
  IF v_flows > 0 THEN
    UPDATE flow_runs SET status = 'cancelled', ended_at = now(), end_reason = 'flow_draft'
    WHERE flow_id = ANY (v_flow_ids) AND status = 'active';
    GET DIAGNOSTICS v_runs = ROW_COUNT;
  END IF;

  -- R7: API keys — selection, else N most recently used keep working.
  -- Excess keys are suspended (never revoked); keys inside the limit
  -- are un-suspended, which is how an upgrade restores them.
  v_keep := _ent_keep_ids(p_keep, 'api_keys');
  WITH ranked AS (
    SELECT id, plan_suspended_at, row_number() OVER (
             ORDER BY (v_keep IS NOT NULL AND id::text = ANY (v_keep)) DESC,
                      last_used_at DESC NULLS LAST, created_at DESC, id) AS rn,
           (v_keep IS NULL OR id::text = ANY (v_keep)) AS eligible
    FROM api_keys
    WHERE account_id = p_account AND revoked_at IS NULL
      AND (expires_at IS NULL OR expires_at > now())
  ), changed AS (
    UPDATE api_keys k
    SET plan_suspended_at = CASE WHEN r.rn > (v_lim->>'api_keys_max')::int OR NOT r.eligible
                                 THEN coalesce(k.plan_suspended_at, now()) ELSE NULL END
    FROM ranked r
    WHERE k.id = r.id
      AND (k.plan_suspended_at IS NOT NULL) <> (r.rn > (v_lim->>'api_keys_max')::int OR NOT r.eligible)
    RETURNING k.plan_suspended_at IS NOT NULL AS suspended
  )
  SELECT count(*) FILTER (WHERE suspended), count(*) FILTER (WHERE NOT suspended)
  INTO v_keys_suspended, v_keys_restored FROM changed;

  -- R8: webhook endpoints — selection, else the newest stay active
  -- (oldest created_at deactivated first).
  v_keep := _ent_keep_ids(p_keep, 'webhook_endpoints');
  WITH ranked AS (
    SELECT id, row_number() OVER (
             ORDER BY (v_keep IS NOT NULL AND id::text = ANY (v_keep)) DESC,
                      created_at DESC, id) AS rn,
           (v_keep IS NULL OR id::text = ANY (v_keep)) AS eligible
    FROM webhook_endpoints WHERE account_id = p_account AND is_active
  )
  UPDATE webhook_endpoints w SET is_active = false
  FROM ranked r
  WHERE w.id = r.id AND (r.rn > (v_lim->>'webhook_endpoints_max')::int OR NOT r.eligible);
  GET DIAGNOSTICS v_hooks = ROW_COUNT;

  -- R9: auto-reply off (configuration kept) and bot conversations
  -- handed to humans with a fixed note (no LLM call, N-5).
  IF NOT (v_lim->>'ai_auto_reply')::boolean THEN
    UPDATE ai_configs SET auto_reply_enabled = false
    WHERE account_id = p_account AND auto_reply_enabled;
    GET DIAGNOSTICS v_ai = ROW_COUNT;

    IF v_ai > 0 THEN
      UPDATE conversations c
      SET ai_autoreply_disabled = true,
          ai_handoff_summary = 'AI auto-reply was turned off because the workspace plan changed. Please continue this conversation.',
          assigned_agent_id = coalesce(c.assigned_agent_id,
            (SELECT handoff_agent_id FROM ai_configs WHERE account_id = p_account))
      WHERE c.account_id = p_account AND c.ai_reply_count > 0 AND NOT c.ai_autoreply_disabled;
      GET DIAGNOSTICS v_convs = ROW_COUNT;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'automations_deactivated', v_auto,
    'flows_deactivated', v_flows,
    'flow_runs_cancelled', v_runs,
    'api_keys_suspended', v_keys_suspended,
    'api_keys_restored', v_keys_restored,
    'webhook_endpoints_deactivated', v_hooks,
    'ai_auto_reply_disabled', v_ai > 0,
    'conversations_handed_off', v_convs
  );
END;
$$;

-- Lock and return the subscription row, creating it (legacy_beta) if
-- it is somehow missing.
CREATE OR REPLACE FUNCTION public._ent_sub_for_update(p_account UUID)
RETURNS account_subscriptions
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s account_subscriptions%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM accounts WHERE id = p_account) THEN
    RAISE EXCEPTION 'account not found' USING ERRCODE = 'P0002';
  END IF;
  INSERT INTO account_subscriptions (account_id, plan_key, state, was_legacy_beta)
  VALUES (p_account, 'legacy_beta', 'active', true)
  ON CONFLICT (account_id) DO NOTHING;
  SELECT * INTO s FROM account_subscriptions WHERE account_id = p_account FOR UPDATE;
  RETURN s;
END;
$$;

CREATE OR REPLACE FUNCTION public._ent_require_actor(p_actor TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_actor IS NULL OR length(btrim(p_actor)) = 0 OR length(p_actor) > 200 THEN
    RAISE EXCEPTION 'actor is required' USING ERRCODE = '22023';
  END IF;
END;
$$;

-- Seat check for a target plan (REQ-D4). Raises WA003 with how many
-- seats must be freed.
CREATE OR REPLACE FUNCTION public._ent_assert_seats_fit(p_account UUID, p_plan TEXT, p_overrides JSONB)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_seats BIGINT := _ent_seats(p_account);
  v_max BIGINT := (_ent_plan_limits(p_plan, p_overrides)->>'seats_max')::bigint;
BEGIN
  IF v_seats > v_max THEN
    PERFORM _ent_raise('downgrade_blocked', 'seats', v_seats, v_max, 'seats_over_new_maximum',
                       jsonb_build_object('to_free', v_seats - v_max, 'plan', p_plan));
  END IF;
END;
$$;

-- Core of every plan change (operator set_plan, immediate schedule,
-- due scheduled change in the sweep). Caller holds the row lock.
CREATE OR REPLACE FUNCTION public._ent_change_plan(
  p_account UUID,
  p_plan TEXT,
  p_keep JSONB,
  p_actor TEXT,
  p_action TEXT,
  p_reason TEXT
) RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s account_subscriptions%ROWTYPE;
  v_old JSONB;
  v_applied JSONB;
  v_new JSONB;
BEGIN
  SELECT * INTO s FROM account_subscriptions WHERE account_id = p_account;
  v_old := jsonb_build_object('plan', s.plan_key, 'state', s.state,
                              'scheduled_plan', s.scheduled_plan_key,
                              'scheduled_change_at', s.scheduled_change_at,
                              'limit_overrides', s.limit_overrides);

  UPDATE account_subscriptions SET
    plan_key = p_plan,
    state = CASE WHEN state = 'trialing' AND p_plan <> 'trial' THEN 'active'
                 -- A trial or legacy account that the lazy rules locked
                 -- becomes usable again once a plan is chosen.
                 WHEN state = 'locked' AND state_reason IN ('trial_ended', 'trial_number_reused', 'legacy_ended')
                      AND p_plan <> 'trial' THEN 'active'
                 ELSE state END,
    state_reason = CASE WHEN (state = 'trialing' AND p_plan <> 'trial')
                          OR (state = 'locked' AND state_reason IN ('trial_ended', 'trial_number_reused', 'legacy_ended')
                              AND p_plan <> 'trial')
                        THEN NULL ELSE state_reason END,
    state_changed_at = CASE WHEN (state = 'trialing' AND p_plan <> 'trial')
                              OR (state = 'locked' AND state_reason IN ('trial_ended', 'trial_number_reused', 'legacy_ended')
                                  AND p_plan <> 'trial')
                            THEN now() ELSE state_changed_at END,
    -- The trial window is the trial's usage period; a paid plan starts
    -- on calendar months until Phase 3 sets billing periods.
    current_period_start = CASE WHEN p_plan = 'trial' THEN current_period_start ELSE NULL END,
    current_period_end = CASE WHEN p_plan = 'trial' THEN current_period_end ELSE NULL END,
    scheduled_plan_key = NULL,
    scheduled_change_at = NULL,
    scheduled_keep = '{}'::jsonb,
    -- The legacy seat override belongs to legacy_beta only.
    limit_overrides = CASE WHEN plan_key = 'legacy_beta' AND p_plan <> 'legacy_beta'
                           THEN '{}'::jsonb ELSE limit_overrides END,
    was_legacy_beta = was_legacy_beta OR plan_key = 'legacy_beta' OR p_plan = 'legacy_beta'
  WHERE account_id = p_account;

  v_applied := _ent_apply_plan_limits(p_account, coalesce(p_keep, s.scheduled_keep));

  SELECT jsonb_build_object('plan', plan_key, 'state', state, 'limit_overrides', limit_overrides)
  INTO v_new FROM account_subscriptions WHERE account_id = p_account;
  v_new := v_new || jsonb_build_object('changes', v_applied);

  PERFORM _ent_audit(p_account, p_actor, p_action, v_old, v_new, p_reason);
  RETURN v_new;
END;
$$;

-- ------------------------------------------------------------
-- Operator RPCs (REQ-O1). Service role only. One audit row each.
-- ------------------------------------------------------------

-- Set the plan now. Refuses (WA003) when seats exceed the plan's
-- maximum; applies the plan's deactivation rules immediately.
CREATE OR REPLACE FUNCTION public.ent_set_plan(
  p_account UUID,
  p_plan TEXT,
  p_actor TEXT,
  p_reason TEXT DEFAULT NULL,
  p_keep JSONB DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s account_subscriptions%ROWTYPE;
BEGIN
  PERFORM _ent_require_actor(p_actor);
  IF NOT EXISTS (SELECT 1 FROM plans WHERE key = p_plan) THEN
    RAISE EXCEPTION 'unknown plan %', p_plan USING ERRCODE = '22023';
  END IF;
  s := _ent_sub_for_update(p_account);
  PERFORM _ent_assert_seats_fit(p_account, p_plan,
    CASE WHEN s.plan_key = 'legacy_beta' AND p_plan <> 'legacy_beta' THEN '{}'::jsonb ELSE s.limit_overrides END);
  RETURN _ent_change_plan(p_account, p_plan, p_keep, p_actor, 'set_plan', p_reason);
END;
$$;

CREATE OR REPLACE FUNCTION public.ent_set_state(
  p_account UUID,
  p_state TEXT,
  p_actor TEXT,
  p_reason TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s account_subscriptions%ROWTYPE;
BEGIN
  PERFORM _ent_require_actor(p_actor);
  IF p_state NOT IN ('trialing', 'active', 'past_due', 'restricted', 'locked') THEN
    RAISE EXCEPTION 'unknown state %', p_state USING ERRCODE = '22023';
  END IF;
  s := _ent_sub_for_update(p_account);
  IF p_state = 'trialing' AND s.trial_ends_at IS NULL THEN
    RAISE EXCEPTION 'set a trial end date before setting trialing' USING ERRCODE = '22023';
  END IF;
  UPDATE account_subscriptions
  SET state = p_state, state_reason = 'operator', state_changed_at = now()
  WHERE account_id = p_account;
  PERFORM _ent_audit(p_account, p_actor, 'set_state',
    jsonb_build_object('state', s.state, 'state_reason', s.state_reason),
    jsonb_build_object('state', p_state, 'state_reason', 'operator'), p_reason);
  RETURN account_entitlements(p_account);
END;
$$;

-- Set or extend the trial end. An extension past now() re-opens a
-- trial that expired or was ended by number reuse.
CREATE OR REPLACE FUNCTION public.ent_set_trial_end(
  p_account UUID,
  p_trial_ends_at TIMESTAMPTZ,
  p_actor TEXT,
  p_reason TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s account_subscriptions%ROWTYPE;
  v_reopen BOOLEAN;
BEGIN
  PERFORM _ent_require_actor(p_actor);
  IF p_trial_ends_at IS NULL THEN
    RAISE EXCEPTION 'trial end is required' USING ERRCODE = '22023';
  END IF;
  s := _ent_sub_for_update(p_account);
  v_reopen := s.plan_key = 'trial' AND p_trial_ends_at > now() AND s.state IN ('trialing', 'locked');
  UPDATE account_subscriptions SET
    trial_ends_at = p_trial_ends_at,
    current_period_start = CASE WHEN plan_key = 'trial' THEN coalesce(current_period_start, created_at) ELSE current_period_start END,
    current_period_end = CASE WHEN plan_key = 'trial' THEN p_trial_ends_at ELSE current_period_end END,
    state = CASE WHEN v_reopen THEN 'trialing' ELSE state END,
    state_reason = CASE WHEN v_reopen THEN NULL ELSE state_reason END,
    state_changed_at = CASE WHEN v_reopen AND state <> 'trialing' THEN now() ELSE state_changed_at END
  WHERE account_id = p_account;
  PERFORM _ent_audit(p_account, p_actor, 'set_trial_end',
    jsonb_build_object('trial_ends_at', s.trial_ends_at, 'state', s.state),
    jsonb_build_object('trial_ends_at', p_trial_ends_at,
                       'state', CASE WHEN v_reopen THEN 'trialing' ELSE s.state END), p_reason);
  RETURN account_entitlements(p_account);
END;
$$;

-- Schedule a plan change (REQ-D1). Applied at once when the account is
-- trialing / on trial / on legacy_beta, or when it is an upgrade
-- (higher sort_order). Otherwise at p_at, default the period end.
CREATE OR REPLACE FUNCTION public.ent_schedule_change(
  p_account UUID,
  p_plan TEXT,
  p_actor TEXT,
  p_at TIMESTAMPTZ DEFAULT NULL,
  p_keep JSONB DEFAULT '{}'::jsonb,
  p_reason TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s account_subscriptions%ROWTYPE;
  v_ent JSONB;
  v_cur_order INTEGER;
  v_new_order INTEGER;
  v_at TIMESTAMPTZ;
BEGIN
  PERFORM _ent_require_actor(p_actor);
  SELECT sort_order INTO v_new_order FROM plans WHERE key = p_plan;
  IF v_new_order IS NULL THEN
    RAISE EXCEPTION 'unknown plan %', p_plan USING ERRCODE = '22023';
  END IF;
  IF p_keep IS NOT NULL AND jsonb_typeof(p_keep) <> 'object' THEN
    RAISE EXCEPTION 'keep must be an object' USING ERRCODE = '22023';
  END IF;
  s := _ent_sub_for_update(p_account);
  v_ent := account_entitlements(p_account);
  PERFORM _ent_assert_seats_fit(p_account, p_plan,
    CASE WHEN s.plan_key = 'legacy_beta' AND p_plan <> 'legacy_beta' THEN '{}'::jsonb ELSE s.limit_overrides END);

  SELECT sort_order INTO v_cur_order FROM plans WHERE key = v_ent->>'plan';

  IF v_ent->>'plan' IN ('trial', 'legacy_beta') OR s.state = 'trialing'
     OR v_new_order >= coalesce(v_cur_order, 0) THEN
    RETURN jsonb_build_object('applied', 'immediate') ||
           _ent_change_plan(p_account, p_plan, p_keep, p_actor, 'schedule_change_immediate', p_reason);
  END IF;

  v_at := coalesce(p_at, (v_ent->>'period_end')::timestamptz);
  UPDATE account_subscriptions
  SET scheduled_plan_key = p_plan, scheduled_change_at = v_at, scheduled_keep = coalesce(p_keep, '{}'::jsonb)
  WHERE account_id = p_account;
  PERFORM _ent_audit(p_account, p_actor, 'schedule_change',
    jsonb_build_object('scheduled_plan', s.scheduled_plan_key, 'scheduled_change_at', s.scheduled_change_at),
    jsonb_build_object('scheduled_plan', p_plan, 'scheduled_change_at', v_at, 'keep', coalesce(p_keep, '{}'::jsonb)),
    p_reason);
  RETURN jsonb_build_object('applied', 'scheduled', 'plan', p_plan, 'at', v_at);
END;
$$;

CREATE OR REPLACE FUNCTION public.ent_cancel_change(
  p_account UUID,
  p_actor TEXT,
  p_reason TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s account_subscriptions%ROWTYPE;
BEGIN
  PERFORM _ent_require_actor(p_actor);
  s := _ent_sub_for_update(p_account);
  UPDATE account_subscriptions
  SET scheduled_plan_key = NULL, scheduled_change_at = NULL, scheduled_keep = '{}'::jsonb
  WHERE account_id = p_account;
  PERFORM _ent_audit(p_account, p_actor, 'cancel_change',
    jsonb_build_object('scheduled_plan', s.scheduled_plan_key, 'scheduled_change_at', s.scheduled_change_at),
    jsonb_build_object('scheduled_plan', NULL, 'scheduled_change_at', NULL), p_reason);
  RETURN account_entitlements(p_account);
END;
$$;

-- Merge per-account limit overrides; a JSON null removes a key.
CREATE OR REPLACE FUNCTION public.ent_set_override(
  p_account UUID,
  p_overrides JSONB,
  p_actor TEXT,
  p_reason TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s account_subscriptions%ROWTYPE;
  v_cols JSONB := _ent_plan_limits('pro', '{}'::jsonb);
  e RECORD;
  v_new JSONB;
BEGIN
  PERFORM _ent_require_actor(p_actor);
  IF p_overrides IS NULL OR jsonb_typeof(p_overrides) <> 'object' THEN
    RAISE EXCEPTION 'overrides must be an object' USING ERRCODE = '22023';
  END IF;
  FOR e IN SELECT key, value FROM jsonb_each(p_overrides) LOOP
    IF NOT v_cols ? e.key THEN
      RAISE EXCEPTION 'unknown limit %', e.key USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(e.value) <> 'null'
       AND jsonb_typeof(e.value) <> jsonb_typeof(v_cols->e.key) THEN
      RAISE EXCEPTION 'limit % has the wrong type', e.key USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(e.value) = 'number' AND ((e.value)::numeric < 0 OR (e.value)::numeric <> trunc((e.value)::numeric)) THEN
      RAISE EXCEPTION 'limit % must be a non-negative integer', e.key USING ERRCODE = '22023';
    END IF;
  END LOOP;
  s := _ent_sub_for_update(p_account);
  v_new := jsonb_strip_nulls(s.limit_overrides || p_overrides);
  UPDATE account_subscriptions SET limit_overrides = v_new WHERE account_id = p_account;
  PERFORM _ent_audit(p_account, p_actor, 'set_override',
    jsonb_build_object('limit_overrides', s.limit_overrides),
    jsonb_build_object('limit_overrides', v_new), p_reason);
  RETURN account_entitlements(p_account);
END;
$$;

-- Per-resource usage vs a target plan (REQ-D2). Read-only.
CREATE OR REPLACE FUNCTION public.ent_downgrade_preview(p_account UUID, p_plan TEXT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_usage JSONB := account_usage(p_account);
  v_lim JSONB := _ent_plan_limits(p_plan, '{}'::jsonb);
  v_out JSONB := '{}'::jsonb;
  r RECORD;
BEGIN
  IF v_lim IS NULL THEN
    RAISE EXCEPTION 'unknown plan %', p_plan USING ERRCODE = '22023';
  END IF;
  FOR r IN SELECT * FROM (VALUES
      ('seats', 'seats_max'),
      ('contacts', 'contacts_max'),
      ('automations_active', 'automations_active_max'),
      ('automations_total', 'automations_total_max'),
      ('flows_active', 'flows_active_max'),
      ('flows_total', 'flows_total_max'),
      ('api_keys', 'api_keys_max'),
      ('webhook_endpoints', 'webhook_endpoints_max'),
      ('kb_documents', 'kb_documents_max'),
      ('pipelines', 'pipelines_max'),
      ('storage_bytes', 'storage_bytes_max'),
      ('broadcast_recipients', 'broadcast_recipients_per_period')
    ) AS t(resource, col) LOOP
    v_out := v_out || jsonb_build_object(r.resource, jsonb_build_object(
      'usage', v_usage->r.resource,
      'new_limit', v_lim->r.col,
      'over', (v_usage->>r.resource)::bigint > (v_lim->>r.col)::bigint));
  END LOOP;
  RETURN jsonb_build_object(
    'plan', p_plan,
    'resources', v_out,
    'ai_auto_reply', v_lim->'ai_auto_reply',
    'blocked', (v_usage->>'seats')::bigint > (v_lim->>'seats_max')::bigint,
    'seats_to_free', greatest((v_usage->>'seats')::bigint - (v_lim->>'seats_max')::bigint, 0)
  );
END;
$$;

-- ------------------------------------------------------------
-- Lifecycle sweep (called by GET /api/automations/cron when the
-- switch is on). Materialises the lazy transitions with audit rows
-- and applies due scheduled changes. Bounded by p_max per category.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.entitlements_run_due(p_max INTEGER DEFAULT 200)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  ps platform_settings%ROWTYPE;
  r RECORD;
  v_trials INTEGER := 0;
  v_grace INTEGER := 0;
  v_changes INTEGER := 0;
  v_legacy INTEGER := 0;
  v_errors INTEGER := 0;
BEGIN
  SELECT * INTO ps FROM platform_settings WHERE id;
  IF NOT coalesce(ps.entitlements_enabled, false) THEN
    RETURN jsonb_build_object('skipped', true);
  END IF;
  p_max := greatest(1, least(coalesce(p_max, 200), 1000));

  -- 1. Trial expiry.
  FOR r IN
    UPDATE account_subscriptions s
    SET state = 'locked', state_reason = 'trial_ended', state_changed_at = s.trial_ends_at
    WHERE s.account_id IN (
      SELECT account_id FROM account_subscriptions
      WHERE state = 'trialing' AND plan_key = 'trial' AND trial_ends_at <= now()
        AND scheduled_plan_key IS NULL
      ORDER BY trial_ends_at LIMIT p_max FOR UPDATE SKIP LOCKED)
    RETURNING s.account_id, s.trial_ends_at
  LOOP
    PERFORM _ent_audit(r.account_id, 'system', 'trial_expired',
      jsonb_build_object('state', 'trialing'),
      jsonb_build_object('state', 'locked', 'trial_ends_at', r.trial_ends_at), 'trial_ended');
    v_trials := v_trials + 1;
  END LOOP;

  -- 2. Grace: past_due → restricted → locked (D-10).
  FOR r IN
    UPDATE account_subscriptions s
    SET state = CASE WHEN s.state_changed_at + make_interval(days => ps.past_due_days + ps.restricted_days) <= now()
                     THEN 'locked' ELSE 'restricted' END,
        state_reason = CASE WHEN s.state_changed_at + make_interval(days => ps.past_due_days + ps.restricted_days) <= now()
                            THEN 'grace_expired' ELSE 'grace_restricted' END,
        state_changed_at = s.state_changed_at + make_interval(days => ps.past_due_days)
    WHERE s.account_id IN (
      SELECT account_id FROM account_subscriptions
      WHERE state = 'past_due' AND state_changed_at + make_interval(days => ps.past_due_days) <= now()
      LIMIT p_max FOR UPDATE SKIP LOCKED)
    RETURNING s.account_id, s.state
  LOOP
    PERFORM _ent_audit(r.account_id, 'system', 'grace_advance',
      jsonb_build_object('state', 'past_due'), jsonb_build_object('state', r.state), 'grace');
    v_grace := v_grace + 1;
  END LOOP;

  FOR r IN
    UPDATE account_subscriptions s
    SET state = 'locked', state_reason = 'grace_expired',
        state_changed_at = s.state_changed_at + make_interval(days => ps.restricted_days)
    WHERE s.account_id IN (
      SELECT account_id FROM account_subscriptions
      WHERE state = 'restricted' AND state_reason = 'grace_restricted'
        AND state_changed_at + make_interval(days => ps.restricted_days) <= now()
      LIMIT p_max FOR UPDATE SKIP LOCKED)
    RETURNING s.account_id
  LOOP
    PERFORM _ent_audit(r.account_id, 'system', 'grace_advance',
      jsonb_build_object('state', 'restricted'), jsonb_build_object('state', 'locked'), 'grace');
    v_grace := v_grace + 1;
  END LOOP;

  -- 3. Due scheduled changes (downgrades at period end). Seats were
  -- checked when the change was scheduled; the change applies even if
  -- members were added since (the account is then over its seat
  -- maximum: new invites blocked, nobody removed).
  FOR r IN
    SELECT account_id, scheduled_plan_key, scheduled_keep FROM account_subscriptions
    WHERE scheduled_change_at <= now()
    ORDER BY scheduled_change_at LIMIT p_max
    FOR UPDATE SKIP LOCKED
  LOOP
    BEGIN
      PERFORM _ent_change_plan(r.account_id, r.scheduled_plan_key, r.scheduled_keep,
                               'system', 'scheduled_change_applied', 'scheduled_change');
      v_changes := v_changes + 1;
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors + 1;
      RAISE WARNING 'entitlements_run_due: scheduled change for % failed: % %', r.account_id, SQLSTATE, SQLERRM;
    END;
  END LOOP;

  -- 4. legacy_beta cut-over (REQ-G3): accounts that chose a plan have a
  -- scheduled change at the cut-over (step 3); the rest are locked.
  IF ps.legacy_ends_at IS NOT NULL AND ps.legacy_ends_at <= now() THEN
    FOR r IN
      UPDATE account_subscriptions s
      SET state = 'locked', state_reason = 'legacy_ended', state_changed_at = ps.legacy_ends_at
      WHERE s.account_id IN (
        SELECT account_id FROM account_subscriptions
        WHERE plan_key = 'legacy_beta' AND state <> 'locked' AND scheduled_plan_key IS NULL
        LIMIT p_max FOR UPDATE SKIP LOCKED)
      RETURNING s.account_id
    LOOP
      PERFORM _ent_audit(r.account_id, 'system', 'legacy_ended',
        jsonb_build_object('plan', 'legacy_beta', 'state', 'active'),
        jsonb_build_object('state', 'locked'), 'legacy_cutover');
      v_legacy := v_legacy + 1;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'trials_expired', v_trials,
    'grace_advanced', v_grace,
    'changes_applied', v_changes,
    'legacy_locked', v_legacy,
    'errors', v_errors
  );
END;
$$;

-- ------------------------------------------------------------
-- Ownership and grants: service_role only.
-- ------------------------------------------------------------
DO $$
DECLARE
  f TEXT;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.entitlements_enabled()',
    'public._ent_raise(text,text,bigint,bigint,text,jsonb)',
    'public._ent_audit(uuid,text,text,jsonb,jsonb,text)',
    'public._ent_lock(uuid,text)',
    'public._ent_period(text,timestamptz,timestamptz,timestamptz,integer,timestamptz)',
    'public._ent_plan_limits(text,jsonb)',
    'public.account_entitlements(uuid)',
    'public._ent_assert_state(jsonb,text)',
    'public._ent_seats(uuid)',
    'public._ent_storage_bytes(uuid)',
    'public.account_usage(uuid)',
    'public.entitlement_consume(uuid,text,integer)',
    'public.entitlement_release(uuid,text,timestamptz,integer)',
    'public._ent_keep_ids(jsonb,text)',
    'public._ent_apply_plan_limits(uuid,jsonb)',
    'public._ent_sub_for_update(uuid)',
    'public._ent_require_actor(text)',
    'public._ent_assert_seats_fit(uuid,text,jsonb)',
    'public._ent_change_plan(uuid,text,jsonb,text,text,text)',
    'public.ent_set_plan(uuid,text,text,text,jsonb)',
    'public.ent_set_state(uuid,text,text,text)',
    'public.ent_set_trial_end(uuid,timestamptz,text,text)',
    'public.ent_schedule_change(uuid,text,text,timestamptz,jsonb,text)',
    'public.ent_cancel_change(uuid,text,text)',
    'public.ent_set_override(uuid,jsonb,text,text)',
    'public.ent_downgrade_preview(uuid,text)',
    'public.entitlements_run_due(integer)'
  ] LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO postgres', f);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
END $$;
