-- ============================================================
-- RLS coverage (catalog test) — run with `supabase test db`
-- ============================================================
-- Fails when a migration lands a public table without row level
-- security, or a tenant table (one with an account_id column) without a
-- single policy. Each assertion names the offending tables, so a red run
-- says exactly what to fix.
--
-- Tables that are deliberately service-role-only (RLS on, NO policies,
-- so every anon/authenticated query is denied) are listed in
-- service_only below. Adding a table there is a security decision —
-- say why in the migration that creates it.
-- ============================================================
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(3);

SELECT is(
  ARRAY(
    SELECT c.relname::text
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p')
      AND NOT c.relrowsecurity
    ORDER BY 1
  ),
  ARRAY[]::text[],
  'every public table has row level security enabled'
);

SELECT is(
  ARRAY(
    SELECT c.relname::text
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p')
      AND EXISTS (
        SELECT 1 FROM pg_attribute a
        WHERE a.attrelid = c.oid
          AND a.attname = 'account_id'
          AND NOT a.attisdropped
      )
      AND NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = c.oid)
      -- service_only: written and read only by the service role.
      --   automation_pending_executions (006) — engine wait queue
      --   pending_message_statuses (054)      — webhook status buffer
      --   entitlement_audit_log (066)         — operator audit trail
      AND c.relname <> ALL (ARRAY[
        'automation_pending_executions',
        'pending_message_statuses',
        'entitlement_audit_log'
      ])
    ORDER BY 1
  ),
  ARRAY[]::text[],
  'every public table with an account_id column has at least one RLS policy'
);

-- Keep the allowlist honest: each entry must still exist, have RLS on and
-- have no policy. If one gains a policy, drop it from the list above.
SELECT is(
  ARRAY(
    SELECT c.relname::text
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname IN ('automation_pending_executions', 'entitlement_audit_log', 'pending_message_statuses')
      AND c.relrowsecurity
      AND NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = c.oid)
    ORDER BY 1
  ),
  ARRAY['automation_pending_executions', 'entitlement_audit_log', 'pending_message_statuses']::text[],
  'service-role-only tables exist, have RLS enabled and expose no policy'
);

SELECT * FROM finish();
ROLLBACK;
