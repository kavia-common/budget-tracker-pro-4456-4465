#!/bin/bash

# Minimal PostgreSQL startup script with full paths + schema/seed execution
DB_NAME="myapp"
DB_USER="appuser"
DB_PASSWORD="dbuser123"
DB_PORT="5000"

echo "Starting PostgreSQL setup..."

# Find PostgreSQL version and set paths
PG_VERSION=$(ls /usr/lib/postgresql/ | head -1)
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"

echo "Found PostgreSQL version: ${PG_VERSION}"

# Helper to run psql as postgres
run_psql_super() {
  sudo -u postgres ${PG_BIN}/psql -X -v ON_ERROR_STOP=1 "$@"
}

# Helper to run psql against app DB as postgres
run_psql_super_appdb() {
  run_psql_super -p ${DB_PORT} -d ${DB_NAME} "$@"
}

# Check if PostgreSQL is already running on the specified port
if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
    echo "PostgreSQL is already running on port ${DB_PORT}!"
else
    # Also check if there's a PostgreSQL process running (in case pg_isready fails)
    if pgrep -f "postgres.*-p ${DB_PORT}" > /dev/null 2>&1; then
        echo "Found existing PostgreSQL process on port ${DB_PORT}"
    else
        # Initialize PostgreSQL data directory if it doesn't exist
        if [ ! -f "/var/lib/postgresql/data/PG_VERSION" ]; then
            echo "Initializing PostgreSQL..."
            sudo -u postgres ${PG_BIN}/initdb -D /var/lib/postgresql/data
        fi

        # Start PostgreSQL server in background
        echo "Starting PostgreSQL server..."
        sudo -u postgres ${PG_BIN}/postgres -D /var/lib/postgresql/data -p ${DB_PORT} &
        sleep 1
    fi
fi

# Wait for PostgreSQL to start
echo "Waiting for PostgreSQL to start..."
for i in {1..20}; do
    if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
        echo "PostgreSQL is ready!"
        break
    fi
    echo "Waiting... ($i/20)"
    sleep 2
done

# Create database and user
echo "Setting up database and user..."
sudo -u postgres ${PG_BIN}/createdb -p ${DB_PORT} ${DB_NAME} 2>/dev/null || echo "Database might already exist"

# Set up user and permissions with proper schema ownership
run_psql_super -p ${DB_PORT} -d postgres << EOF
-- Create user if doesn't exist
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';
    END IF;
    ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
END
\$\$;

-- Grant database-level permissions
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
EOF

# Ensure schema permissions in app database
run_psql_super_appdb << EOF
-- Grant/ensure permissions on public schema
GRANT USAGE ON SCHEMA public TO ${DB_USER};
GRANT CREATE ON SCHEMA public TO ${DB_USER};
GRANT ALL ON SCHEMA public TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES TO ${DB_USER};
EOF

# Apply schema.sql (idempotent)
if [ -f "schema.sql" ]; then
  echo "Applying schema.sql..."
  run_psql_super_appdb -f schema.sql && echo "✓ Schema applied"
else
  echo "⚠ schema.sql not found; skipping"
fi

# Apply seed.sql (idempotent)
if [ -f "seed.sql" ]; then
  echo "Applying seed.sql..."
  run_psql_super_appdb -f seed.sql && echo "✓ Seed data applied"
else
  echo "⚠ seed.sql not found; skipping"
fi

# Optionally refresh materialized views if they exist
run_psql_super_appdb -c "REFRESH MATERIALIZED VIEW CONCURRENTLY mv_monthly_spend_by_category;" 2>/dev/null || \
echo "Materialized view refresh skipped or not supported."

# Save connection command to a file
echo "psql postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}" > db_connection.txt
echo "Connection string saved to db_connection.txt"

# Save environment variables to a file
cat > db_visualizer/postgres.env << EOF
export POSTGRES_URL="postgresql://localhost:${DB_PORT}/${DB_NAME}"
export POSTGRES_USER="${DB_USER}"
export POSTGRES_PASSWORD="${DB_PASSWORD}"
export POSTGRES_DB="${DB_NAME}"
export POSTGRES_PORT="${DB_PORT}"
EOF

echo "PostgreSQL setup complete!"
echo "Database: ${DB_NAME}"
echo "User: ${DB_USER}"
echo "Port: ${DB_PORT}"
echo ""
echo "Environment variables saved to db_visualizer/postgres.env"
echo "To use with Node.js viewer, run: source db_visualizer/postgres.env"
echo "To connect to the database, use one of the following commands:"
echo "psql -h localhost -U ${DB_USER} -d ${DB_NAME} -p ${DB_PORT}"
echo "$(cat db_connection.txt)"
