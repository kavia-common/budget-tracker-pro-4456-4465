-- Migration 002 - Backend alignment (non-destructive, idempotent)
-- Changes:
-- 1) budgets.period (text default 'monthly')
-- 2) budgets.active (boolean default true)
-- 3) goals.due_date (date, nullable)
-- 4) Helpful indexes
-- 5) Refresh materialized view if present

BEGIN;

-- 1) Add budgets.period with default 'monthly'
ALTER TABLE IF EXISTS public.budgets
    ADD COLUMN IF NOT EXISTS period TEXT DEFAULT 'monthly';

-- 2) Add budgets.active with default true
ALTER TABLE IF EXISTS public.budgets
    ADD COLUMN IF NOT EXISTS active BOOLEAN DEFAULT true;

-- 3) Add goals.due_date (nullable)
ALTER TABLE IF EXISTS public.goals
    ADD COLUMN IF NOT EXISTS due_date DATE;

-- 4) Create indexes if not present
-- Transaction date index (speeds date range queries)
CREATE INDEX IF NOT EXISTS idx_transactions_date ON public.transactions (date);

-- Transaction category_id index (explicit; complements existing idx_tx_category)
CREATE INDEX IF NOT EXISTS idx_transactions_category_id ON public.transactions (category_id);

-- Budgets user+month index (helps monthly budget lookups)
CREATE INDEX IF NOT EXISTS idx_budgets_user_month ON public.budgets (user_id, month);

COMMIT;

-- 5) Refresh materialized view if it exists.
-- Prefer CONCURRENTLY if supported; otherwise, regular REFRESH.
DO $$
BEGIN
  IF EXISTS (
      SELECT 1 FROM pg_matviews WHERE schemaname = 'public' AND matviewname = 'mv_monthly_spend_by_category'
  ) THEN
    BEGIN
      -- Try concurrent refresh when possible
      EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY public.mv_monthly_spend_by_category';
    EXCEPTION
      WHEN OTHERS THEN
        -- Fallback to standard refresh (may lock view)
        EXECUTE 'REFRESH MATERIALIZED VIEW public.mv_monthly_spend_by_category';
    END;
  END IF;
END$$;
