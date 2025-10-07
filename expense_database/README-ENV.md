Database environment quickstart

- Standard connection defaults (for local dev):
  HOST: 127.0.0.1
  PORT: 5001
  DB:   myapp

- The startup.sh respects:
  POSTGRES_URL or POSTGRES_HOST, POSTGRES_PORT, POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB

- Example environment:
  POSTGRES_HOST=127.0.0.1
  POSTGRES_PORT=5001
  POSTGRES_USER=postgres
  POSTGRES_PASSWORD=postgres
  POSTGRES_DB=myapp
  # Or a single URL:
  POSTGRES_URL=postgresql://postgres:postgres@127.0.0.1:5001/myapp

- The startup.sh runs schema.sql idempotently, applies migrations in order, and seeds only when needed.
