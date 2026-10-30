-- ============================================================
-- Shared rate limiter (migration 065) — run with `supabase test db`
-- ============================================================
-- rate_limit_hit must count atomically per key, refuse past the limit
-- inside a window, restart after the window, keep keys independent,
-- and be callable by service_role only. Rolled back at the end.
-- ============================================================
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(12);

SET LOCAL ROLE service_role;

SELECT is((SELECT allowed::text || '|' || remaining FROM public.rate_limit_hit('t:a', 2, 60000)), 'true|1',
  'first hit is allowed with limit-1 remaining');
SELECT is((SELECT allowed::text || '|' || remaining FROM public.rate_limit_hit('t:a', 2, 60000)), 'true|0',
  'second hit is allowed with 0 remaining');
SELECT is((SELECT allowed::text || '|' || remaining FROM public.rate_limit_hit('t:a', 2, 60000)), 'false|0',
  'third hit inside the window is refused');
SELECT public.rate_limit_hit('t:a', 2, 60000);
SELECT is((SELECT count FROM public.rate_limit_buckets WHERE key = 't:a'), 3,
  'the stored count is capped at limit + 1 while refused');
SELECT is((SELECT allowed FROM public.rate_limit_hit('t:b', 2, 60000)), true,
  'another key has its own budget');
SELECT ok((SELECT reset_at > now() + interval '50 seconds' AND reset_at <= clock_timestamp() + interval '60 seconds'
           FROM public.rate_limit_buckets WHERE key = 't:b'),
  'reset_at is one window after the first hit');

-- Close the window for t:a.
RESET ROLE;
UPDATE public.rate_limit_buckets SET reset_at = clock_timestamp() - interval '1 second' WHERE key = 't:a';
SET LOCAL ROLE service_role;
SELECT is((SELECT allowed::text || '|' || remaining FROM public.rate_limit_hit('t:a', 2, 60000)), 'true|1',
  'after the window ends the next hit opens a new one');

SELECT throws_ok($$SELECT * FROM public.rate_limit_hit('t:c', 0, 60000)$$, '22023', NULL,
  'a non-positive limit is rejected');

-- Sweep removes only windows that ended more than 5 minutes ago.
RESET ROLE;
UPDATE public.rate_limit_buckets SET reset_at = clock_timestamp() - interval '10 minutes' WHERE key = 't:b';
SET LOCAL ROLE service_role;
SELECT is(public.rate_limit_sweep(), 1, 'sweep deletes the long-expired window');
SELECT is((SELECT count(*)::int FROM public.rate_limit_buckets WHERE key = 't:a'), 1,
  'sweep keeps a live window');
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT throws_ok($$SELECT * FROM public.rate_limit_hit('t:x', 5, 60000)$$, '42501', NULL,
  'authenticated cannot call rate_limit_hit');
SELECT throws_ok($$SELECT * FROM public.rate_limit_buckets$$, '42501', NULL,
  'authenticated cannot read the counters');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
