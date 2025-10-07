#!/usr/bin/env bash
set -euo pipefail

# Expense DB startup script
# - Reads POSTGRES_URL from env or builds it from POSTGRES_HOST/PORT/USER/PASSWORD/DB
# - Waits for Postgres readiness using psql before applying schema/seed
# - Optional local Postgres start when START_LOCAL_POSTGRES=true
# - Defaults to port 5001 per preview environment

# Defaults (preview: 5001)
: "${POSTGRES_HOST:=localhost}"
: "${POSTGRES_PORT:=5001}"
: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_PASSWORD:=postgres}"
: "${POSTGRES_DB:=postgres}"
: "${START_LOCAL_POSTGRES:=false}"

# If explicit overrides for components exist, prefer them to compose URL when POSTGRES_URL absent
if [[ -z "${POSTGRES_URL:-}" ]]; then
  POSTGRES_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
fi

export POSTGRES_URL

echo "[DB] Effective POSTGRES_URL=${POSTGRES_URL}"
echo "[DB] START_LOCAL_POSTGRES=${START_LOCAL_POSTGRES}"

# Optionally attempt to start a local postgres (only when explicitly requested)
start_local_postgres_if_requested() {
  if [[ "${START_LOCAL_POSTGRES}" == "true" ]]; then
    echo "[DB] START_LOCAL_POSTGRES=true -> attempting to start local postgres (best-effort)"
    # Try common Linux service names; ignore failures if not available
    if command -v systemctl >/dev/null 2>&1; then
      sudo systemctl start postgresql || true
    elif command -v service >/dev/null 2>&1; then
      sudo service postgresql start || true
    else
      echo "[DB] No service manager found to start postgres; continuing to wait for external DB..."
    fi
  fi
}

# Extract password for psql if available in URL; else rely on POSTGRES_PASSWORD via PGPASSWORD
export PGPASSWORD="${POSTGRES_PASSWORD}"

# Wait for Postgres to be ready
wait_for_db() {
  local url="$1"
  local max_attempts="${2:-30}"   # 30 attempts
  local sleep_seconds="${3:-2}"   # 2s per attempt (~60s total)

  echo "[DB] Waiting for database to be ready (timeout ~$((max_attempts*sleep_seconds))s)..."
  local attempt=1
  while (( attempt <= max_attempts )); do
    # Try a lightweight command
    if psql "${url}" -v ON_ERROR_STOP=1 -c "SELECT 1;" >/dev/null 2>&1; then
      echo "[DB] Database is ready (after ${attempt} attempt(s))"
      return 0
    fi
    echo "[DB] Attempt ${attempt}/${max_attempts} - database not ready yet; retrying in ${sleep_seconds}s..."
    sleep "${sleep_seconds}"
    ((attempt++))
  done
  return 1
}

# Helpers to run SQL/file with strict failure handling
run_sql() {
  local sql="$1"
  echo "[DB] Running SQL: ${sql}"
  psql "${POSTGRES_URL}" -v ON_ERROR_STOP=1 -c "${sql}"
}

run_sql_file() {
  local file="$1"
  echo "[DB] Applying file: ${file}"
  psql "${POSTGRES_URL}" -v ON_ERROR_STOP=1 -f "${file}"
}

# Determine script dir and relevant files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_FILE="${SCRIPT_DIR}/schema.sql"
SEED_FILE="${SCRIPT_DIR}/seed.sql"

# Start local postgres if requested
start_local_postgres_if_requested

# Wait until DB becomes available
if ! wait_for_db "${POSTGRES_URL}" 30 2; then
  echo "[DB][ERROR] Could not reach PostgreSQL within timeout. Effective POSTGRES_URL=${POSTGRES_URL}"
  echo "[DB][HINT] Ensure the DB is running and reachable on host/port above, or set START_LOCAL_POSTGRES=true if local service is available."
  exit 1
fi

# Apply schema if present
if [[ -f "${SCHEMA_FILE}" ]]; then
  if ! run_sql_file "${SCHEMA_FILE}"; then
    echo "[DB][ERROR] Applying schema failed (${SCHEMA_FILE})."
    exit 1
  fi
else
  echo "[DB][WARN] schema.sql not found at ${SCHEMA_FILE}; skipping."
fi

# Seed if present and needed
if [[ -f "${SEED_FILE}" ]]; then
  echo "[DB] Checking if seeding is required..."
  # Check if users table exists
  if run_sql "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='users' LIMIT 1;" >/dev/null 2>&1; then
    # Now check if users table is empty
    USER_COUNT=$(psql "${POSTGRES_URL}" -t -A -c "SELECT COUNT(*) FROM users;" 2>/dev/null || echo "0")
    if [[ "${USER_COUNT}" =~ ^[0-9]+$ ]] && [[ "${USER_COUNT}" -eq 0 ]]; then
      echo "[DB] users table empty; running seed.sql"
      if ! run_sql_file "${SEED_FILE}"; then
        echo "[DB][ERROR] Applying seed failed (${SEED_FILE})."
        exit 1
      fi
    else
      echo "[DB] Seed skipped; users table already has ${USER_COUNT} row(s)."
    fi
  else
    echo "[DB] users table not found; running seed.sql after schema"
    if ! run_sql_file "${SEED_FILE}"; then
      echo "[DB][ERROR] Applying seed failed (${SEED_FILE})."
      exit 1
    fi
  fi
else
  echo "[DB][WARN] seed.sql not found at ${SEED_FILE}; skipping."
fi

echo "[DB] Database initialization complete."
