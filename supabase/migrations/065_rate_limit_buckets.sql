-- ============================================================
-- 065 — shared rate-limit counters in Postgres
-- ============================================================
-- src/lib/rate-limit.ts kept its fixed-window counters in a per-process
-- Map, so every extra instance (Vercel serverless fan-out, several
-- containers) multiplied every budget. With RATE_LIMIT_BACKEND=postgres
-- the app counts here instead: one table, one atomic upsert per check,
-- through the service-role client. No new infrastructure.
--
--   rate_limit_hit(key, limit, window_ms) → (allowed, remaining, reset_at)
--     Fixed window, same semantics as the in-memory limiter: the first
--     hit opens a window of window_ms; hits past `limit` inside it are
--     refused; the next hit after reset_at starts a new window. The
--     stored count is capped at limit + 1, so a client hammering a
--     closed window can't grow it.
--   rate_limit_sweep() → rows deleted
--     Drops windows that ended more than 5 minutes ago. Called best-
--     effort by GET /api/automations/cron. Rows are reused per key, so
--     without the sweep the table grows only with distinct keys
--     (users, IPs, API keys), not with traffic.
--
-- UNLOGGED: counters are disposable. Skipping WAL makes the per-request
-- write cheap; after a crash the table comes back empty, which only
-- means every window restarts. Unlogged tables are not replicated to
-- read replicas, which never read them.
--
-- Service-role only: RLS on with no policies, and the 062 default
-- grant to authenticated is revoked. Keys hold user ids, API key ids
-- and client IPs, so they are not exposed to clients.
--
-- Idempotent: IF NOT EXISTS, CREATE OR REPLACE, REVOKE/GRANT.
-- ============================================================

CREATE UNLOGGED TABLE IF NOT EXISTS public.rate_limit_buckets (
  key      TEXT PRIMARY KEY CHECK (length(key) BETWEEN 1 AND 256),
  count    INTEGER NOT NULL,
  reset_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_rate_limit_buckets_reset_at
  ON public.rate_limit_buckets (reset_at);

ALTER TABLE public.rate_limit_buckets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.rate_limit_buckets FROM anon, authenticated;
GRANT ALL ON TABLE public.rate_limit_buckets TO service_role;

CREATE OR REPLACE FUNCTION public.rate_limit_hit(
  p_key TEXT,
  p_limit INTEGER,
  p_window_ms INTEGER
) RETURNS TABLE (allowed BOOLEAN, remaining INTEGER, reset_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_now TIMESTAMPTZ := clock_timestamp();
  v_count INTEGER;
  v_reset TIMESTAMPTZ;
BEGIN
  IF p_key IS NULL OR p_limit IS NULL OR p_limit < 1
     OR p_window_ms IS NULL OR p_window_ms < 1 THEN
    RAISE EXCEPTION 'rate_limit_hit: invalid arguments' USING ERRCODE = '22023';
  END IF;

  INSERT INTO rate_limit_buckets AS b (key, count, reset_at)
  VALUES (p_key, 1, v_now + make_interval(secs => p_window_ms / 1000.0))
  ON CONFLICT (key) DO UPDATE
    SET count = CASE WHEN b.reset_at <= v_now THEN 1
                     ELSE LEAST(b.count + 1, p_limit + 1) END,
        reset_at = CASE WHEN b.reset_at <= v_now THEN EXCLUDED.reset_at
                        ELSE b.reset_at END
  RETURNING b.count, b.reset_at INTO v_count, v_reset;

  allowed := v_count <= p_limit;
  remaining := GREATEST(p_limit - v_count, 0);
  reset_at := v_reset;
  RETURN NEXT;
END;
$$;

ALTER FUNCTION public.rate_limit_hit(TEXT, INTEGER, INTEGER) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.rate_limit_hit(TEXT, INTEGER, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rate_limit_hit(TEXT, INTEGER, INTEGER) TO service_role;

CREATE OR REPLACE FUNCTION public.rate_limit_sweep()
RETURNS INTEGER
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  WITH gone AS (
    DELETE FROM rate_limit_buckets
    WHERE reset_at < clock_timestamp() - INTERVAL '5 minutes'
    RETURNING 1
  )
  SELECT count(*)::int FROM gone;
$$;

ALTER FUNCTION public.rate_limit_sweep() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.rate_limit_sweep() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rate_limit_sweep() TO service_role;
