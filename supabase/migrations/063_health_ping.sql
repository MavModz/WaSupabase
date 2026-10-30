-- ============================================================
-- 063 — health_ping(): a database round trip for GET /api/health
-- ============================================================
-- The health endpoint needs to prove the app can reach Postgres
-- through PostgREST with its service-role client. Selecting from a
-- real table would be an unscoped service-role query on tenant data
-- (the one thing every server-side query must never be), so it calls
-- this constant function instead: it touches no table and returns no
-- data, only that the round trip worked.
--
-- Execute is granted to service_role only; anon and authenticated
-- cannot call it (the endpoint is public, the RPC is not).
--
-- Idempotent: CREATE OR REPLACE, and REVOKE/GRANT are no-ops when
-- already in the requested state.
-- ============================================================

CREATE OR REPLACE FUNCTION public.health_ping()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT TRUE;
$$;

REVOKE ALL ON FUNCTION public.health_ping() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.health_ping() TO service_role;
