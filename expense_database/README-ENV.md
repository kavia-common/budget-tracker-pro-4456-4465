Database environment quickstart

- Default preview port is 5001. The startup.sh respects:
  POSTGRES_URL or POSTGRES_HOST, POSTGRES_PORT, POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB

- Example:
  POSTGRES_HOST=localhost
  POSTGRES_PORT=5001
  POSTGRES_USER=postgres
  POSTGRES_PASSWORD=postgres
  POSTGRES_DB=postgres

- The startup.sh runs schema.sql idempotently and seeds only when needed.
