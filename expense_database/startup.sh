#!/usr/bin/env bash
set -euo pipefail

# Expense DB startup script
# Manages a local PostgreSQL instance and applies schema/seed files idempotently.
# - Detects/creates PGDATA under ./data
# - Initializes cluster if needed (initdb)
# - Starts postgres via pg_ctl on localhost with configured port (default 5001)
# - Waits for readiness using psql
# - Ensures superuser and database exist
# - Applies schema.sql and seed.sql idempotently
# - Keeps postgres running in foreground by tailing log
#
# Env vars with defaults:
#   POSTGRES_USER=postgres
#   POSTGRES_PASSWORD=postgres
#   POSTGRES_DB=postgres
#   POSTGRES_HOST=127.0.0.1
#   POSTGRES_PORT=5001
#   POSTGRES_URL (overrides constructed URL if provided)
#   START_LOCAL_POSTGRES=true (default for this container)
#
# Notes:
# - This script binds postgres to 127.0.0.1 only.
# - It uses pg_ctl for controlled start/stop and a local postgres.log for output.

# Defaults
: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_PASSWORD:=postgres}"
: "${POSTGRES_DB:=postgres}"
: "${POSTGRES_HOST:=127.0.0.1}"
: "${POSTGRES_PORT:=5001}"
: "${START_LOCAL_POSTGRES:=true}"

# Work dir and files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

export PGDATA="${SCRIPT_DIR}/data"
LOG_FILE="${SCRIPT_DIR}/postgres.log"
PID_FILE="${PGDATA}/postmaster.pid"

# Construct POSTGRES_URL if not given (use localhost binding)
if [[ -z "${POSTGRES_URL:-}" ]]; then
  POSTGRES_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
fi
export POSTGRES_URL
export PGPASSWORD="${POSTGRES_PASSWORD}"

echo "[DB] -----------------------------------------------"
echo "[DB] Expense Database Startup"
echo "[DB] PGDATA: ${PGDATA}"
echo "[DB] POSTGRES_HOST: ${POSTGRES_HOST}"
echo "[DB] POSTGRES_PORT: ${POSTGRES_PORT}"
echo "[DB] POSTGRES_USER: ${POSTGRES_USER}"
echo "[DB] POSTGRES_DB: ${POSTGRES_DB}"
echo "[DB] START_LOCAL_POSTGRES: ${START_LOCAL_POSTGRES}"
echo "[DB] Effective POSTGRES_URL: ${POSTGRES_URL}"
echo "[DB] Log file: ${LOG_FILE}"
echo "[DB] -----------------------------------------------"

# Ensure directories
mkdir -p "${PGDATA}"
touch "${LOG_FILE}"

# Cleanup function on exit
stop_postgres() {
  echo "[DB] Caught termination signal. Stopping postgres..."
  if [[ -d "${PGDATA}" ]]; then
    if pg_ctl -D "${PGDATA}" status >/dev/null 2>&1; then
      pg_ctl -D "${PGDATA}" -m fast stop || true
    fi
  fi
  echo "[DB] Postgres stopped."
}
trap stop_postgres SIGINT SIGTERM

# Detect initialization
NEEDS_INIT=1
if [[ -s "${PGDATA}/PG_VERSION" ]]; then
  NEEDS_INIT=0
fi

# Ensure local postgres is started if requested
if [[ "${START_LOCAL_POSTGRES}" == "true" ]]; then
  if [[ "${NEEDS_INIT}" -eq 1 ]]; then
    echo "[DB] Initializing new PostgreSQL cluster..."
    # Initialize cluster with auth for our superuser
    # --pwfile requires a file; we create a temp one safely
    PWFILE="$(mktemp)"
    trap 'rm -f "${PWFILE}" || true' EXIT
    printf "%s" "${POSTGRES_PASSWORD}" > "${PWFILE}"

    # Initialize with specified superuser
    initdb -D "${PGDATA}" -U "${POSTGRES_USER}" --pwfile="${PWFILE}"

    # Configure postgresql.conf
    echo "[DB] Writing postgresql.conf with listen_addresses=127.0.0.1 and port=${POSTGRES_PORT}"
    {
      echo "listen_addresses = '127.0.0.1'"
      echo "port = ${POSTGRES_PORT}"
      echo "max_connections = 100"
      echo "shared_buffers = 128MB"
      echo "fsync = on"
      echo "synchronous_commit = on"
      echo "log_timezone = 'UTC'"
      echo "timezone = 'UTC'"
    } >> "${PGDATA}/postgresql.conf"

    # Configure pg_hba.conf for local md5 auth
    echo "[DB] Configuring pg_hba.conf for local md5..."
    {
      echo "local   all             all                                     md5"
      echo "host    all             all             127.0.0.1/32            md5"
      echo "host    all             all             ::1/128                 md5"
    } > "${PGDATA}/pg_hba.conf"

  else
    echo "[DB] Existing PostgreSQL cluster detected at ${PGDATA}."
    # Ensure postgresql.conf has our settings; append if not present
    grep -q "listen_addresses" "${PGDATA}/postgresql.conf" 2>/dev/null || echo "listen_addresses = '127.0.0.1'" >> "${PGDATA}/postgresql.conf"
    if grep -qE "^[#\s]*port\s*=" "${PGDATA}/postgresql.conf"; then
      # Replace port line
      sed -i "s/^[#\s]*port\s*=.*/port = ${POSTGRES_PORT}/" "${PGDATA}/postgresql.conf" || true
    else
      echo "port = ${POSTGRES_PORT}" >> "${PGDATA}/postgresql.conf"
    fi
    # Ensure pg_hba has local md5
    if ! grep -q "127.0.0.1/32" "${PGDATA}/pg_hba.conf" 2>/dev/null; then
      echo "host    all             all             127.0.0.1/32            md5" >> "${PGDATA}/pg_hba.conf"
    fi
    if ! grep -q "^local\s\+all\s\+all\s\+md5" "${PGDATA}/pg_hba.conf" 2>/dev/null; then
      echo "local   all             all                                     md5" >> "${PGDATA}/pg_hba.conf"
    fi
  fi

  # Start postgres if not already running
  if ! pg_ctl -D "${PGDATA}" status >/dev/null 2>&1; then
    echo "[DB] Starting postgres (pg_ctl) ..."
    pg_ctl -D "${PGDATA}" -l "${LOG_FILE}" -w start
    echo "[DB] postgres started."
  else
    echo "[DB] postgres already running (pg_ctl status OK)."
  fi
else
  echo "[DB] START_LOCAL_POSTGRES=false - Skipping local postgres management."
fi

# Wait for readiness on configured host/port
echo "[DB] Waiting for PostgreSQL readiness on ${POSTGRES_HOST}:${POSTGRES_PORT} ..."
ATTEMPTS=0
until psql "host=${POSTGRES_HOST} port=${POSTGRES_PORT} user=${POSTGRES_USER} dbname=postgres" -c "SELECT 1" >/dev/null 2>&1; do
  ATTEMPTS=$((ATTEMPTS+1))
  if [[ $ATTEMPTS -ge 60 ]]; then
    echo "[DB][ERROR] PostgreSQL not ready after 60 attempts (~60s)."
    echo "Check ${LOG_FILE} for details."
    exit 1
  fi
  sleep 1
done
echo "[DB] PostgreSQL is ready."

# Ensure superuser exists (if initdb created a different user or in reuse cases)
# Create role only if not exists, set password.
echo "[DB] Ensuring role \"${POSTGRES_USER}\" exists with login/superuser..."
psql "host=${POSTGRES_HOST} port=${POSTGRES_PORT} user=${POSTGRES_USER} dbname=postgres" -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${POSTGRES_USER}') THEN
      CREATE ROLE "${POSTGRES_USER}" WITH LOGIN SUPERUSER PASSWORD '${POSTGRES_PASSWORD}';
   ELSE
      -- ensure password matches
      EXECUTE format('ALTER ROLE %I WITH PASSWORD %L', '${POSTGRES_USER}', '${POSTGRES_PASSWORD}');
   END IF;
END
\$\$;
SQL

# Ensure target database exists
echo "[DB] Ensuring database \"${POSTGRES_DB}\" exists..."
DB_EXISTS=$(psql -tAc "SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}'" "host=${POSTGRES_HOST} port=${POSTGRES_PORT} user=${POSTGRES_USER} dbname=postgres" || echo "")
if [[ "${DB_EXISTS}" != "1" ]]; then
  psql "host=${POSTGRES_HOST} port=${POSTGRES_PORT} user=${POSTGRES_USER} dbname=postgres" -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"${POSTGRES_DB}\";"
  echo "[DB] Created database ${POSTGRES_DB}"
else
  echo "[DB] Database ${POSTGRES_DB} already exists."
fi

# Update POSTGRES_URL to point to target DB explicitly
POSTGRES_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
export POSTGRES_URL

# Helper: run SQL and SQL files against target DB
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

# Apply schema.sql (idempotent)
SCHEMA_FILE="${SCRIPT_DIR}/schema.sql"
if [[ -f "${SCHEMA_FILE}" ]]; then
  echo "[DB] Applying schema.sql (idempotent by design)..."
  run_sql_file "${SCHEMA_FILE}"
else
  echo "[DB][WARN] schema.sql not found; skipping."
fi

# Apply migrations if any (optional; they may include \i ../schema.sql etc.)
MIGRATIONS_DIR="${SCRIPT_DIR}/migrations"
if [[ -d "${MIGRATIONS_DIR}" ]]; then
  echo "[DB] Applying migrations (if any)..."
  # Run migrations in lexicographic order
  shopt -s nullglob
  for m in "${MIGRATIONS_DIR}"/*.sql; do
    echo "[DB] Migration: ${m}"
    run_sql_file "${m}"
  done
  shopt -u nullglob
else
  echo "[DB] No migrations directory found."
fi

# Seed if needed
SEED_FILE="${SCRIPT_DIR}/seed.sql"
if [[ -f "${SEED_FILE}" ]]; then
  echo "[DB] Checking if seeding is required..."
  # If users table exists and empty, seed
  if run_sql "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='users' LIMIT 1;" >/dev/null 2>&1; then
    USER_COUNT=$(psql "${POSTGRES_URL}" -t -A -c "SELECT COUNT(*) FROM users;" 2>/dev/null || echo "0")
    if [[ "${USER_COUNT}" =~ ^[0-9]+$ ]] && [[ "${USER_COUNT}" -eq 0 ]]; then
      echo "[DB] users table empty; running seed.sql"
      run_sql_file "${SEED_FILE}"
    else
      echo "[DB] Seed skipped; users table already has ${USER_COUNT} row(s)."
    fi
  else
    echo "[DB] users table not found; running seed.sql after schema"
    run_sql_file "${SEED_FILE}"
  fi
else
  echo "[DB][WARN] seed.sql not found; skipping."
fi

echo "[DB] Database initialization complete."

# Keep postgres in foreground by tailing the log (only if we started it)
if [[ "${START_LOCAL_POSTGRES}" == "true" ]]; then
  echo "[DB] Tailing postgres.log (Ctrl+C or send SIGTERM to stop)..."
  # Use tail -F to follow across log rotations; ensure tail exits when shell receives SIGTERM via trap
  tail -F "${LOG_FILE}" &
  TAIL_PID=$!

  # Wait on tail process; if it exits, try to keep the script alive while postgres runs
  wait "${TAIL_PID}" || true

  # If tail stopped unexpectedly, keep the script running to serve as a foreground process
  # but check postgres status; if not running, exit.
  if pg_ctl -D "${PGDATA}" status >/dev/null 2>&1; then
    echo "[DB] tail exited but postgres still running. Reattaching..."
    tail -F "${LOG_FILE}"
  else
    echo "[DB] postgres not running; exiting."
  fi
else
  echo "[DB] START_LOCAL_POSTGRES=false; not tailing logs. Exiting."
fi
