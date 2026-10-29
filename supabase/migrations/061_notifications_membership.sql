-- ============================================================
-- 061 — notifications are readable only while you are a member
-- ============================================================
-- notifications_select / notifications_update (027) check only
-- auth.uid() = user_id. A member who is removed (remove_account_member
-- moves them to a fresh account) or who leaves therefore kept reading
-- the old account's notifications, whose title/body carry contact
-- names. Add current membership of the row's account to both policies.
--
-- The column-level grant from 027 (UPDATE (read_at) only) is left
-- untouched. Rows are still created only by the SECURITY DEFINER
-- assignment trigger; there is no client INSERT/DELETE policy.
--
-- Idempotent: DROP POLICY IF EXISTS before each CREATE POLICY.
-- ============================================================

DROP POLICY IF EXISTS notifications_select ON public.notifications;
CREATE POLICY notifications_select ON public.notifications FOR SELECT
  USING (auth.uid() = user_id AND is_account_member(account_id));

DROP POLICY IF EXISTS notifications_update ON public.notifications;
CREATE POLICY notifications_update ON public.notifications FOR UPDATE
  USING (auth.uid() = user_id AND is_account_member(account_id))
  WITH CHECK (auth.uid() = user_id AND is_account_member(account_id));
