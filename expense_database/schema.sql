BEGIN;

-- Ensure UUID generation is available
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Enums
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'account_type') THEN
        CREATE TYPE account_type AS ENUM ('checking','savings','credit','investment');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'alert_type') THEN
        CREATE TYPE alert_type AS ENUM ('budget_exceeded','large_transaction','goal_reached');
    END IF;
END
$$;

-- Users
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    name TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Accounts
CREATE TABLE IF NOT EXISTS accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    institution TEXT,
    type account_type NOT NULL DEFAULT 'checking',
    masked_number TEXT,
    currency TEXT NOT NULL DEFAULT 'USD',
    balance NUMERIC(12,2) NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_accounts_user ON accounts(user_id);

-- Categories
CREATE TABLE IF NOT EXISTS categories (
    id SERIAL PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    type TEXT NOT NULL CHECK (type IN ('income','expense')),
    color TEXT
);

-- Transactions
CREATE TABLE IF NOT EXISTS transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    account_id UUID REFERENCES accounts(id) ON DELETE SET NULL,
    date DATE NOT NULL,
    description TEXT,
    amount NUMERIC(12,2) NOT NULL,
    currency TEXT NOT NULL DEFAULT 'USD',
    category_id INT REFERENCES categories(id) ON DELETE SET NULL,
    is_transfer BOOLEAN NOT NULL DEFAULT false,
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_tx_user_date ON transactions(user_id, date DESC);
CREATE INDEX IF NOT EXISTS idx_tx_category ON transactions(category_id);

-- Budgets
CREATE TABLE IF NOT EXISTS budgets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    category_id INT NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
    month DATE NOT NULL,
    amount NUMERIC(12,2) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(user_id, category_id, month)
);

-- Goals
CREATE TABLE IF NOT EXISTS goals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    target_amount NUMERIC(12,2) NOT NULL,
    current_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
    target_date DATE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Alerts
CREATE TABLE IF NOT EXISTS alerts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type alert_type NOT NULL,
    message TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    read BOOLEAN NOT NULL DEFAULT false
);

-- Optional helper materialized view for monthly spend by category
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_monthly_spend_by_category AS
SELECT
    user_id,
    date_trunc('month', date)::date AS month,
    category_id,
    SUM(CASE WHEN amount < 0 THEN -amount ELSE 0 END) AS spend
FROM transactions
GROUP BY user_id, month, category_id;

COMMIT;
