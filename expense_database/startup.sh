#!/usr/bin/env bash
set -euo pipefail

# This script initializes the PostgreSQL database for the app.
# It reads connection details from environment variables when provided,
# otherwise it will fall back to sensible local defaults (port 5001 for preview).

: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_PASSWORD:=postgres}"
: "${POSTGRES_DB:=postgres}"
: "${POSTGRES_HOST:=localhost}"
: "${POSTGRES_PORT:=5001}"

# Build connection URL if POSTGRES_URL not provided
if [[ -z "${POSTGRES_URL:-}" ]]; then
  export POSTGRES_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
fi

echo "[DB] Using POSTGRES_URL=${POSTGRES_URL}"

# Helper to run a single SQL statement or file via psql
run_sql() {
  local sql="$1"
  PGPASSWORD="${POSTGRES_PASSWORD}" psql "${POSTGRES_URL}" -v ON_ERROR_STOP=1 -c "${sql}"
}

run_sql_file() {
  local file="$1"
  echo "[DB] Running ${file}"
  PGPASSWORD="${POSTGRES_PASSWORD}" psql "${POSTGRES_URL}" -v ON_ERROR_STOP=1 -f "${file}"
}

# Determine script directory for schema and seed
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_FILE="${SCRIPT_DIR}/schema.sql"
SEED_FILE="${SCRIPT_DIR}/seed.sql"

# Create tables idempotently using IF NOT EXISTS and OR clauses inside SQL
# Expect schema.sql to be written idempotently; we re-run safely.
if [[ -f "${SCHEMA_FILE}" ]]; then
  run_sql_file "${SCHEMA_FILE}"
else
  echo "[DB][WARN] schema.sql not found at ${SCHEMA_FILE}"
fi

# Seed only if data is not already present.
# We check for presence of at least one user; adjust checks to your schema as needed.
if [[ -f "${SEED_FILE}" ]]; then
  echo "[DB] Checking if seed is needed..."
  EXISTING_USERS=$(PGPASSWORD="${POSTGRES_PASSWORD}" psql "${POSTGRES_URL}" -t -A -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'users';")
  if [[ "${EXISTING_USERS}" == "0" ]]; then
    echo "[DB] 'users' table missing; running seed.sql after schema..."
    run_sql_file "${SEED_FILE}"
  else
    # If users table exists, do a lightweight existence check to avoid duplicate seeding
    USER_COUNT=$(PGPASSWORD="${POSTGRES_PASSWORD}" psql "${POSTGRES_URL}" -t -A -c "SELECT COUNT(*) FROM users;") || USER_COUNT="0"
    if [[ "${USER_COUNT}" == "0" ]]; then
      echo "[DB] users table empty; running seed.sql"
      run_sql_file "${SEED_FILE}"
    else
      echo "[DB] Seed skipped; users table already populated (${USER_COUNT} rows)"
    fi
  fi
else
  echo "[DB][WARN] seed.sql not found at ${SEED_FILE}"
fi

echo "[DB] Database initialization complete."
