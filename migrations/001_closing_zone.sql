-- =============================================================================
-- Migration 001: Closing Zone — expected_close_date + deal_events
-- =============================================================================
-- Run this in the Supabase SQL Editor. Review first, execute inside a
-- transaction (the BEGIN/COMMIT below). Safe to re-run: uses IF NOT EXISTS.
--
-- What this adds:
--   1. deals.expected_close_date  (nullable date)
--   2. deal_events                (new table: change history for deals)
--   3. trigger on deals           (auto-writes event rows when tracked fields change)
--
-- What this does NOT do:
--   - Drop any columns
--   - Modify any existing data
--   - Change RLS policies (you may need to add a SELECT policy on deal_events
--     for your app's users — see note at the bottom)
-- =============================================================================

BEGIN;

-- 1. Add expected_close_date to deals -----------------------------------------
ALTER TABLE public.deals
  ADD COLUMN IF NOT EXISTS expected_close_date date;

COMMENT ON COLUMN public.deals.expected_close_date IS
  'When the deal is expected to close. Nullable. Used by Closing Zone forecast.';

-- 2. Create deal_events table -------------------------------------------------
CREATE TABLE IF NOT EXISTS public.deal_events (
  id          bigserial PRIMARY KEY,
  deal_id     uuid NOT NULL REFERENCES public.deals(id) ON DELETE CASCADE,
  event_type  text NOT NULL,      -- 'stage_changed' | 'value_changed' | 'close_date_changed' | 'champion_changed'
  from_value  text,               -- text-serialised previous value (nullable)
  to_value    text,               -- text-serialised new value (nullable)
  user_id     uuid,               -- who made the change (nullable — trigger can't always know)
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS deal_events_deal_id_idx    ON public.deal_events(deal_id);
CREATE INDEX IF NOT EXISTS deal_events_created_at_idx ON public.deal_events(created_at DESC);

COMMENT ON TABLE public.deal_events IS
  'Append-only change log for deals. Populated by trigger on public.deals.';

-- 3. Trigger function ---------------------------------------------------------
-- Writes a row to deal_events whenever one of the tracked fields changes.
CREATE OR REPLACE FUNCTION public.log_deal_event()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.stage IS DISTINCT FROM OLD.stage THEN
    INSERT INTO public.deal_events(deal_id, event_type, from_value, to_value)
    VALUES (NEW.id, 'stage_changed', OLD.stage, NEW.stage);
  END IF;

  IF NEW.deal_value IS DISTINCT FROM OLD.deal_value THEN
    INSERT INTO public.deal_events(deal_id, event_type, from_value, to_value)
    VALUES (NEW.id, 'value_changed', OLD.deal_value::text, NEW.deal_value::text);
  END IF;

  IF NEW.expected_close_date IS DISTINCT FROM OLD.expected_close_date THEN
    INSERT INTO public.deal_events(deal_id, event_type, from_value, to_value)
    VALUES (NEW.id, 'close_date_changed', OLD.expected_close_date::text, NEW.expected_close_date::text);
  END IF;

  IF NEW.champion_name IS DISTINCT FROM OLD.champion_name THEN
    INSERT INTO public.deal_events(deal_id, event_type, from_value, to_value)
    VALUES (NEW.id, 'champion_changed', OLD.champion_name, NEW.champion_name);
  END IF;

  RETURN NEW;
END;
$$;

-- 4. Attach trigger -----------------------------------------------------------
DROP TRIGGER IF EXISTS deals_log_event ON public.deals;
CREATE TRIGGER deals_log_event
  AFTER UPDATE ON public.deals
  FOR EACH ROW
  EXECUTE FUNCTION public.log_deal_event();

-- 5. Enable RLS on deal_events (match your deals table policy model) ----------
-- You probably already have RLS on deals. Mirror it here. Adjust the policy
-- below to match how your app authenticates — this default lets any
-- authenticated user read events, which is usually fine for an internal tool.
ALTER TABLE public.deal_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "deal_events readable by authenticated" ON public.deal_events;
CREATE POLICY "deal_events readable by authenticated"
  ON public.deal_events
  FOR SELECT
  TO authenticated
  USING (true);

-- IMPORTANT: the trigger writes to this table on behalf of whoever is updating
-- a deal. If your app uses the anon key (typical Supabase setup), you also need
-- an INSERT policy for anon, otherwise every UPDATE that fires the trigger will
-- be rolled back with "new row violates row-level security policy".
DROP POLICY IF EXISTS "deal_events insertable by anon" ON public.deal_events;
CREATE POLICY "deal_events insertable by anon"
  ON public.deal_events
  FOR INSERT
  TO anon
  WITH CHECK (true);

DROP POLICY IF EXISTS "deal_events readable by anon" ON public.deal_events;
CREATE POLICY "deal_events readable by anon"
  ON public.deal_events
  FOR SELECT
  TO anon
  USING (true);

-- No INSERT policy for authenticated needed — rows are written by the trigger,
-- which executes whatever role made the original UPDATE on deals.

COMMIT;

-- =============================================================================
-- Verification queries (run AFTER commit to sanity check)
-- =============================================================================
-- SELECT column_name, data_type FROM information_schema.columns
--   WHERE table_name = 'deals' AND column_name = 'expected_close_date';
--
-- SELECT * FROM public.deal_events ORDER BY created_at DESC LIMIT 5;
--
-- -- Force a test event:
-- UPDATE public.deals SET champion_name = champion_name WHERE id = '<some-id>';
-- -- (should NOT create an event — IS DISTINCT FROM handles this)
--
-- UPDATE public.deals SET champion_name = 'Test ' || champion_name WHERE id = '<some-id>';
-- -- (should create a champion_changed event; then revert it to clean up)
-- =============================================================================
