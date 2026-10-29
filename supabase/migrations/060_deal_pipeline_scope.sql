-- ============================================================
-- 060 — deals must point at their own account's pipeline / stage
-- ============================================================
-- deals_insert / deals_update (017) only check deals.account_id, so a
-- caller could write a deal into its own account whose pipeline_id or
-- stage_id belongs to ANOTHER account (or a stage from a different
-- pipeline). Two writers were affected:
--   * the browser client, which inserts/updates deals directly under
--     RLS (components/pipelines/deal-form.tsx, the Kanban drag in
--     app/(dashboard)/pipelines/page.tsx);
--   * the automation engine's create_deal step, which inserts with the
--     service role (bypasses RLS) using ids from the step config.
-- One BEFORE trigger closes both paths: the pipeline must belong to
-- NEW.account_id and the stage must sit in NEW.pipeline_id.
--
-- SECURITY DEFINER (owner postgres) so the check sees pipeline rows
-- the caller's RLS may hide, and gives the same answer for every role.
-- On UPDATE the check only runs when one of the three columns actually
-- changes, so editing a title / status / value on a pre-existing
-- mismatched row keeps working. Existing rows are NOT modified: the
-- pre-flight block below only reports how many there are.
--
-- Idempotent: CREATE OR REPLACE FUNCTION, DROP TRIGGER IF EXISTS.
-- ============================================================

-- Pre-flight: report (never fail, never delete) existing mismatches.
DO $$
DECLARE
  v_bad BIGINT;
BEGIN
  SELECT count(*) INTO v_bad
  FROM public.deals d
  WHERE NOT EXISTS (
          SELECT 1 FROM public.pipelines p
          WHERE p.id = d.pipeline_id AND p.account_id = d.account_id
        )
     OR NOT EXISTS (
          SELECT 1 FROM public.pipeline_stages s
          WHERE s.id = d.stage_id AND s.pipeline_id = d.pipeline_id
        );
  RAISE NOTICE '060_deal_pipeline_scope: % existing deal(s) reference a pipeline or stage outside their account/pipeline (left unchanged)', v_bad;
END $$;

CREATE OR REPLACE FUNCTION public.enforce_deal_pipeline_scope()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.pipeline_id IS NOT DISTINCT FROM OLD.pipeline_id
     AND NEW.stage_id IS NOT DISTINCT FROM OLD.stage_id
     AND NEW.account_id IS NOT DISTINCT FROM OLD.account_id
  THEN
    RETURN NEW;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pipelines p
    WHERE p.id = NEW.pipeline_id AND p.account_id = NEW.account_id
  ) THEN
    RAISE EXCEPTION 'deal pipeline does not belong to the deal''s account'
      USING ERRCODE = 'check_violation';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pipeline_stages s
    WHERE s.id = NEW.stage_id AND s.pipeline_id = NEW.pipeline_id
  ) THEN
    RAISE EXCEPTION 'deal stage does not belong to the deal''s pipeline'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

ALTER FUNCTION public.enforce_deal_pipeline_scope() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.enforce_deal_pipeline_scope() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS enforce_deal_pipeline_scope ON public.deals;
CREATE TRIGGER enforce_deal_pipeline_scope
  BEFORE INSERT OR UPDATE OF pipeline_id, stage_id, account_id ON public.deals
  FOR EACH ROW EXECUTE FUNCTION public.enforce_deal_pipeline_scope();
