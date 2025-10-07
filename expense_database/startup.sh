#!/usr/bin/env bash
set -euo pipefail

# Expense DB startup script (hardened)
# - Defaults: START_LOCAL_POSTGRES=true, HOST=127.0.0.1, PORT=5001
# - Verifies postgres binaries availability (postgres, initdb, pg_ctl, psql)
# - Ensures PGDATA permissions
# - Detects and reports port conflicts
# - Configures postgresql.conf to listen on desired host/port
# - Starts postgres with pg_ctl and waits up to 180s for readiness
# - Ensures DB/role exist; applies schema and seed only after readiness
# - Skips schema/seed if DB unreachable
# - Verbose logs prefixed with [DB]
# - Keeps server running in foreground with pg_ctl; handles termination cleanly

# Defaults and env
: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_PASSWORD:=postgres}"
: "${POSTGRES_DB:=postgres}"
: "${POSTGRES_HOST:=127.0.0.1}"
: "${POSTGRES_PORT:=5001}"
: "${START_LOCAL_POSTGRES:=true}"
: "${READINESS_TIMEOUT:=180}"   # seconds
: "${READINESS_INTERVAL:=2}"    # seconds

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

export PGDATA="${SCRIPT_DIR}/data"
LOG_FILE="${SCRIPT_DIR}/postgres.log"
PID_FILE="${PGDATA}/postmaster.pid"

# Construct URL if not provided
if [[ -z "${POSTGRES_URL:-}" ]]; then
  POSTGRES_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
fi
export POSTGRES_URL
export PGPASSWORD="${POSTGRES_PASSWORD}"

echo "[DB] ------------------------------------------------------------"
echo "[DB] Expense Database Startup (hardened)"
echo "[DB] PGDATA: ${PGDATA}"
echo "[DB] POSTGRES_HOST: ${POSTGRES_HOST}"
echo "[DB] POSTGRES_PORT: ${POSTGRES_PORT}"
echo "[DB] POSTGRES_USER: ${POSTGRES_USER}"
echo "[DB] POSTGRES_DB: ${POSTGRES_DB}"
echo "[DB] START_LOCAL_POSTGRES: ${START_LOCAL_POSTGRES}"
echo "[DB] Effective POSTGRES_URL: ${POSTGRES_URL}"
echo "[DB] Log file: ${LOG_FILE}"
echo "[DB] ------------------------------------------------------------"

# Resolve postgres binaries
resolve_bin() {
  local name="$1"
  if command -v "${name}" >/dev/null 2>&1; then
    command -v "${name}"
    return 0
  fi
  # Attempt Debian/Ubuntu common path fallback
  local debbin="$(ls /usr/lib/postgresql/*/bin/${name} 2>/dev/null | head -n1 || true)"
  if [[ -n "${debbin}" && -x "${debbin}" ]]; then
    echo "${debbin}"
    return 0
  fi
  return 1
}

if ! POSTGRES_BIN="$(resolve_bin postgres)"; then
  echo "[DB][ERROR] 'postgres' binary not found in PATH or standard locations."
  echo "[DB] Ensure PostgreSQL is installed and binaries are available."
  exit 1
fi
if ! INITDB_BIN="$(resolve_bin initdb)"; then
  echo "[DB][ERROR] 'initdb' binary not found."
  echo "[DB] Ensure PostgreSQL client/server tools are installed."
  exit 1
fi
if ! PG_CTL_BIN="$(resolve_bin pg_ctl)"; then
  echo "[DB][ERROR] 'pg_ctl' binary not found."
  echo "[DB] Ensure PostgreSQL client/server tools are installed."
  exit 1
fi
if ! PSQL_BIN="$(resolve_bin psql)"; then
  echo "[DB][ERROR] 'psql' binary not found."
  echo "[DB] Ensure PostgreSQL client tools are installed."
  exit 1
fi

echo "[DB] Detected binaries:"
echo "[DB]   postgres: ${POSTGRES_BIN}"
echo "[DB]   initdb  : ${INITDB_BIN}"
echo "[DB]   pg_ctl  : ${PG_CTL_BIN}"
echo "[DB]   psql    : ${PSQL_BIN}"

# Ensure directories and permissions
mkdir -p "${PGDATA}"
touch "${LOG_FILE}" || true
chmod 600 "${LOG_FILE}" || true

# PGDATA permissions (safe for local dev)
chmod 700 "${PGDATA}" || true

# Port-in-use detection helper
port_in_use() {
  local host="$1" port="$2"
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP -sTCP:LISTEN -P 2>/dev/null | grep -E "[\:\ ]${port}\b" >/dev/null 2>&1 && return 0 || return 1
  elif command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -E "(:|\\b)${port}\\b" >/dev/null 2>&1 && return 0 || return 1
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | awk '{print $4}' | grep -E "(:|\\b)${port}\\b" >/dev/null 2>&1 && return 0 || return 1
  else
    # Fallback: try connecting
    (echo > /dev/tcp/${host}/${port}) >/dev/null 2>&1 && return 0 || return 1
  fi
}

# Stop postgres function
stop_postgres() {
  echo "[DB] Stopping postgres (if running)..."
  if "${PG_CTL_BIN}" -D "${PGDATA}" status >/dev/null 2>&1; then
    "${PG_CTL_BIN}" -D "${PGDATA}" -m fast stop || true
  fi
  echo "[DB] Postgres stopped."
}

# Trap for graceful shutdown
trap stop_postgres SIGINT SIGTERM

# Determine if cluster needs init
NEEDS_INIT=1
if [[ -s "${PGDATA}/PG_VERSION" ]]; then
  NEEDS_INIT=0
fi

# Initialize cluster if requested and needed
if [[ "${START_LOCAL_POSTGRES}" == "true" ]]; then
  # Quick port check before start (only meaningful if we bind to TCP)
  if port_in_use "${POSTGRES_HOST}" "${POSTGRES_PORT}"; then
    echo "[DB][WARN] Port ${POSTGRES_PORT} appears to be in use."
    echo "[DB] Attempting to detect service binding on that port:"
    if command -v lsof >/dev/null 2>&1; then
      lsof -iTCP -sTCP:LISTEN -P | grep -E "[\:\ ]${POSTGRES_PORT}\b" || true
    fi
    echo "[DB] If this is a different Postgres instance, set POSTGRES_PORT to a free port, or STOP the other instance."
  fi

  if [[ "${NEEDS_INIT}" -eq 1 ]]; then
    echo "[DB] Initializing new PostgreSQL cluster in ${PGDATA} ..."
    PWFILE="$(mktemp)"
    # ensure cleanup
    cleanup_pw() { rm -f "${PWFILE}" >/dev/null 2>&1 || true; }
    trap 'cleanup_pw; stop_postgres' EXIT
    printf "%s" "${POSTGRES_PASSWORD}" > "${PWFILE}"

    # Use --auth-local=md5, --auth-host=md5 for dev (require password)
    "${INITDB_BIN}" -D "${PGDATA}" -U "${POSTGRES_USER}" --pwfile="${PWFILE}" --auth=md5 >/dev/null
    cleanup_pw

    # Update postgresql.conf to listen on desired host and port
    echo "[DB] Configuring postgresql.conf (listen_addresses='*', port=${POSTGRES_PORT})"
    {
      echo "listen_addresses = '*'"
      echo "port = ${POSTGRES_PORT}"
      echo "max_connections = 100"
      echo "shared_buffers = 128MB"
      echo "fsync = on"
      echo "synchronous_commit = on"
      echo "log_timezone = 'UTC'"
      echo "timezone = 'UTC'"
      echo "logging_collector = on"
      echo "log_directory = 'log'"
      echo "log_filename = 'postgresql-%Y-%m-%d.log'"
    } >> "${PGDATA}/postgresql.conf"

    # Configure pg_hba.conf: trust local connections for dev
    echo "[DB] Configuring pg_hba.conf for local development (trust for local, md5 for others)"
    {
      echo "local   all             all                                     trust"
      echo "host    all             all             127.0.0.1/32            md5"
      echo "host    all             all             ::1/128                 md5"
      echo "host    all             all             0.0.0.0/0               md5"
    } > "${PGDATA}/pg_hba.conf"

  else
    echo "[DB] Existing PostgreSQL cluster detected at ${PGDATA}."
    # Ensure minimal config present/updated
    if ! grep -qE "^[#\s]*listen_addresses\s*=" "${PGDATA}/postgresql.conf" 2>/dev/null; then
      echo "listen_addresses = '*'" >> "${PGDATA}/postgresql.conf"
    else
      sed -i "s/^[#\s]*listen_addresses\s*=.*/listen_addresses = '*'/" "${PGDATA}/postgresql.conf" || true
    fi
    if grep -qE "^[#\s]*port\s*=" "${PGDATA}/postgresql.conf" 2>/dev/null; then
      sed -i "s/^[#\s]*port\s*=.*/port = ${POSTGRES_PORT}/" "${PGDATA}/postgresql.conf" || true
    else
      echo "port = ${POSTGRES_PORT}" >> "${PGDATA}/postgresql.conf"
    fi
    # Ensure pg_hba allows local dev
    if ! grep -q "^local\s\+all\s\+all\s\+trust" "${PGDATA}/pg_hba.conf" 2>/dev/null; then
      echo "local   all             all                                     trust" >> "${PGDATA}/pg_hba.conf"
    fi
    if ! grep -q "127.0.0.1/32" "${PGDATA}/pg_hba.conf" 2>/dev/null; then
      echo "host    all             all             127.0.0.1/32            md5" >> "${PGDATA}/pg_hba.conf"
    fi
    if ! grep -q "::1/128" "${PGDATA}/pg_hba.conf" 2>/dev/null; then
      echo "host    all             all             ::1/128                 md5" >> "${PGDATA}/pg_hba.conf"
    fi
  fi

  # Start postgres with explicit host/port options ensuring bind as requested
  if ! "${PG_CTL_BIN}" -D "${PGDATA}" status >/dev/null 2>&1; then
    echo "[DB] Starting postgres via pg_ctl ..."
    # -w waits for server start; -l logs to file
    "${PG_CTL_BIN}" -D "${PGDATA}" -l "${LOG_FILE}" -w start -o "-p ${POSTGRES_PORT} -h ${POSTGRES_HOST}"
    echo "[DB] Postgres started (pg_ctl)."
  else
    echo "[DB] Postgres already running (pg_ctl status OK)."
  fi
else
  echo "[DB] START_LOCAL_POSTGRES=false - Skipping local postgres management."
fi

# Readiness check using both constructed URL and host/port split
is_ready() {
  # Try host/port direct (prefer socket/host explicit)
  "${PSQL_BIN}" "host=${POSTGRES_HOST} port=${POSTGRES_PORT} user=${POSTGRES_USER} dbname=postgres" -c "SELECT 1" >/dev/null 2>&1 && return 0
  # Try POSTGRES_URL if previous failed
  "${PSQL_BIN}" "${POSTGRES_URL%/*}/postgres" -c "SELECT 1" >/dev/null 2>&1 && return 0
  return 1
}

echo "[DB] Waiting for PostgreSQL readiness on ${POSTGRES_HOST}:${POSTGRES_PORT} (timeout ${READINESS_TIMEOUT}s)..."
elapsed=0
while ! is_ready; do
  sleep "${READINESS_INTERVAL}"
  elapsed=$((elapsed + READINESS_INTERVAL))
  if (( elapsed >= READINESS_TIMEOUT )); then
    echo "[DB][ERROR] PostgreSQL not ready after ${READINESS_TIMEOUT}s."
    echo "[DB] Last 50 log lines (if any):"
    tail -n 50 "${LOG_FILE}" 2>/dev/null || true
    echo "[DB] Skipping schema/seed because DB is unreachable."
    # Keep process running if we started postgres (tail logs), else exit non-zero
    if [[ "${START_LOCAL_POSTGRES}" == "true" ]]; then
      echo "[DB] Keeping postgres running. Exiting readiness loop."
      break
    else
      exit 1
    fi
  fi
  echo "[DB] ... still waiting (${elapsed}s)"
done

if is_ready; then
  echo "[DB] PostgreSQL is ready."

  # Ensure role exists and password is set
  echo "[DB] Ensuring role \"${POSTGRES_USER}\" exists with login/superuser..."
  "${PSQL_BIN}" "host=${POSTGRES_HOST} port=${POSTGRES_PORT} user=${POSTGRES_USER} dbname=postgres" -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${POSTGRES_USER}') THEN
      CREATE ROLE "${POSTGRES_USER}" WITH LOGIN SUPERUSER PASSWORD '${POSTGRES_PASSWORD}';
   ELSE
      EXECUTE format('ALTER ROLE %I WITH PASSWORD %L', '${POSTGRES_USER}', '${POSTGRES_PASSWORD}');
   END IF;
END
\$\$;
SQL

  # Ensure target database exists
  echo "[DB] Ensuring database \"${POSTGRES_DB}\" exists..."
  DB_EXISTS=$("${PSQL_BIN}" -tAc "SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}'" "host=${POSTGRES_HOST} port=${POSTGRES_PORT} user=${POSTGRES_USER} dbname=postgres" || echo "")
  if [[ "${DB_EXISTS}" != "1" ]]; then
    "${PSQL_BIN}" "host=${POSTGRES_HOST} port=${POSTGRES_PORT} user=${POSTGRES_USER} dbname=postgres" -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"${POSTGRES_DB}\";"
    echo "[DB] Created database ${POSTGRES_DB}"
  else
    echo "[DB] Database ${POSTGRES_DB} already exists."
  fi

  # Update POSTGRES_URL to target DB
  POSTGRES_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
  export POSTGRES_URL

  # Helpers
  run_sql() {
    local sql="$1"
    echo "[DB] Running SQL: ${sql}"
    "${PSQL_BIN}" "${POSTGRES_URL}" -v ON_ERROR_STOP=1 -c "${sql}"
  }
  run_sql_file() {
    local file="$1"
    if [[ ! -f "${file}" ]]; then
      echo "[DB][WARN] File not found: ${file}"
      return 0
    fi
    echo "[DB] Applying file: ${file}"
    "${PSQL_BIN}" "${POSTGRES_URL}" -v ON_ERROR_STOP=1 -f "${file}"
  }

  # Apply schema and migrations
  SCHEMA_FILE="${SCRIPT_DIR}/schema.sql"
  if [[ -f "${SCHEMA_FILE}" ]]; then
    echo "[DB] Applying schema.sql ..."
    run_sql_file "${SCHEMA_FILE}"
  else
    echo "[DB][WARN] schema.sql not found; skipping."
  fi

  MIGRATIONS_DIR="${SCRIPT_DIR}/migrations"
  if [[ -d "${MIGRATIONS_DIR}" ]]; then
    echo "[DB] Applying migrations (lexicographic order)..."
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
    if run_sql "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='users' LIMIT 1;" >/dev/null 2>&1; then
      USER_COUNT=$("${PSQL_BIN}" "${POSTGRES_URL}" -t -A -c "SELECT COUNT(*) FROM users;" 2>/dev/null || echo "0")
      if [[ "${USER_COUNT}" =~ ^[0-9]+$ ]] && [[ "${USER_COUNT}" -eq 0 ]]; then
        echo "[DB] users table empty; running seed.sql"
        run_sql_file "${SEED_FILE}"
      else
        echo "[DB] Seed skipped; users table already has ${USER_COUNT} row(s)."
      fi
    else
      echo "[DB] users table not found; running seed.sql"
      run_sql_file "${SEED_FILE}"
    fi
  else
    echo "[DB][WARN] seed.sql not found; skipping."
  fi

  echo "[DB] Database initialization complete."
else
  echo "[DB][WARN] PostgreSQL not confirmed ready; schema/seed skipped."
fi

# Keep postgres running in foreground if we started it (follow logs)
if [[ "${START_LOCAL_POSTGRES}" == "true" ]]; then
  echo "[DB] Following postgres logs. Send SIGTERM/SIGINT to stop."
  # Reuse pg_ctl to maintain server lifecycle; tail for visibility
  tail -F "${LOG_FILE}" &
  TAIL_PID=$!

  # Wait on tail; keep process until termination signal
  wait "${TAIL_PID}" || true

  # Double-check server status
  if "${PG_CTL_BIN}" -D "${PGDATA}" status >/dev/null 2>&1; then
    echo "[DB] tail exited but postgres still running. Reattaching..."
    exec tail -F "${LOG_FILE}"
  else
    echo "[DB] Postgres not running; exiting."
  fi
else
  echo "[DB] START_LOCAL_POSTGRES=false; exiting after setup."
fi
