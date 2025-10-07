#!/usr/bin/env bash
set -euo pipefail

# Simple health check for PostgreSQL using POSTGRES_URL.
# Exits 0 when reachable and ready; 1 otherwise.

: "${POSTGRES_URL:=}"
: "${POSTGRES_HOST:=127.0.0.1}"
: "${POSTGRES_PORT:=5001}"
: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_DB:=postgres}"

# Resolve psql
if command -v psql >/dev/null 2>&1; then
  PSQL_BIN="psql"
else
  PSQL_BIN="$(ls /usr/lib/postgresql/*/bin/psql 2>/dev/null | head -n1 || true)"
  if [[ -z "${PSQL_BIN}" ]]; then
    echo "[DB][HEALTH] psql not found"
    exit 1
  fi
fi

if [[ -z "${POSTGRES_URL}" ]]; then
  POSTGRES_URL="postgresql://${POSTGRES_USER}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
fi

echo "[DB][HEALTH] Checking PostgreSQL availability: ${POSTGRES_URL}"
if "${PSQL_BIN}" "${POSTGRES_URL}" -c "SELECT 1" >/dev/null 2>&1; then
  echo "[DB][HEALTH] OK"
  exit 0
else
  echo "[DB][HEALTH] UNREACHABLE"
  exit 1
fi
