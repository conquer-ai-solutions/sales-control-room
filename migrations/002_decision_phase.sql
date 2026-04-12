-- =============================================================================
-- Migration 002: Rename Procurement → Decision Phase + add decision_signal
-- =============================================================================
-- IMPORTANT: deals.stage is a Postgres enum (deal_stage), not a text column.
-- ALTER TYPE ... ADD VALUE must run OUTSIDE a transaction, so this migration
-- is in TWO STEPS. Run step 1 first, wait for success, then run step 2.
--
-- Before running, sanity-check how many deals will be retagged:
--   SELECT COUNT(*) FROM public.deals WHERE stage = 'procurement';
--
-- =============================================================================
-- STEP 1 — Run this first, on its own (no transaction wrapper)
-- =============================================================================

ALTER TYPE deal_stage ADD VALUE IF NOT EXISTS 'decision_phase' AFTER 'procurement';

-- =============================================================================
-- STEP 2 — Then run this as a separate query
-- =============================================================================

BEGIN;

-- 1. Add decision_signal column -----------------------------------------------
ALTER TABLE public.deals
  ADD COLUMN IF NOT EXISTS decision_signal text;

COMMENT ON COLUMN public.deals.decision_signal IS
  'Signal strength within Decision Phase. Values: submitted | engaged | positive_signal | verbal_commit. Nullable.';

-- 2. Temporarily disable the event-logging trigger ----------------------------
ALTER TABLE public.deals DISABLE TRIGGER deals_log_event;

-- 3. Rename stage on existing deals -------------------------------------------
UPDATE public.deals
  SET stage = 'decision_phase'
  WHERE stage = 'procurement';

-- 4. Re-enable the trigger ----------------------------------------------------
ALTER TABLE public.deals ENABLE TRIGGER deals_log_event;

-- 5. Extend trigger function — also track decision_signal, cast enums to text -
CREATE OR REPLACE FUNCTION public.log_deal_event()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.stage IS DISTINCT FROM OLD.stage THEN
    INSERT INTO public.deal_events(deal_id, event_type, from_value, to_value)
    VALUES (NEW.id, 'stage_changed', OLD.stage::text, NEW.stage::text);
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

  IF NEW.decision_signal IS DISTINCT FROM OLD.decision_signal THEN
    INSERT INTO public.deal_events(deal_id, event_type, from_value, to_value)
    VALUES (NEW.id, 'signal_changed', OLD.decision_signal, NEW.decision_signal);
  END IF;

  RETURN NEW;
END;
$$;

COMMIT;

-- =============================================================================
-- Post-migration verification
-- =============================================================================
-- SELECT stage, COUNT(*) FROM public.deals GROUP BY stage ORDER BY stage;
-- SELECT column_name FROM information_schema.columns
--   WHERE table_name = 'deals' AND column_name = 'decision_signal';
-- =============================================================================
