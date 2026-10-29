-- ============================================================
-- 062 — explicit table privileges for the API roles
-- ============================================================
-- No migration before this one grants table privileges: every table
-- relied on the default privileges a Supabase project ships with
-- (anon / authenticated / service_role get ALL on new public tables,
-- RLS does the restricting). A database without those defaults (the
-- CLI's local stack in CI, and possibly a newly created hosted
-- project) gives `authenticated` nothing, so every browser-side query
-- fails with 42501 "permission denied for table …" before RLS is even
-- consulted. supabase/tests/10_tenant_isolation caught this.
--
-- Grant what the app needs explicitly, so the schema no longer depends
-- on project defaults:
--   * authenticated: SELECT/INSERT/UPDATE/DELETE on every public table;
--     RLS policies decide which rows.
--   * service_role: ALL (server-side admin client, bypasses RLS).
--   * anon: nothing. No RLS policy targets anon, so a table grant would
--     only ever widen the surface. Existing projects that still carry
--     the platform default are left as they are (this migration only
--     grants; it does not revoke).
-- Default privileges cover tables created by later migrations.
--
-- Then re-apply the two deliberate narrowings the blanket grant would
-- otherwise undo:
--   * 027: clients may UPDATE only notifications.read_at;
--   * 054: pending_message_statuses is service-role only.
--
-- Idempotent: GRANT / REVOKE / ALTER DEFAULT PRIVILEGES are no-ops when
-- already in the requested state. On a project with the platform
-- defaults this changes nothing.
-- ============================================================

GRANT USAGE ON SCHEMA public TO authenticated, service_role;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO authenticated, service_role;

-- 027: only read_at is client-writable on notifications.
REVOKE UPDATE ON public.notifications FROM authenticated;
GRANT UPDATE (read_at) ON public.notifications TO authenticated;

-- 054: pending_message_statuses is written and read by the webhook's
-- service-role client only.
REVOKE ALL ON TABLE public.pending_message_statuses FROM anon, authenticated;
