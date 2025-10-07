# Database Environment Configuration (PostgreSQL)

Standard local configuration
- Host: 127.0.0.1
- Port: 5001
- Database: myapp (example)
- User/Password: set locally to your preferred credentials

Example environment variables
POSTGRES_HOST=127.0.0.1
POSTGRES_PORT=5001
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=myapp

Example single connection URL
POSTGRES_URL=postgres://postgres:postgres@127.0.0.1:5001/myapp

Quickstart
1) Start PostgreSQL listening on 127.0.0.1:5001
2) Create database `myapp`
3) Apply migrations (see migrations/001_init.sql and 002_align_backend.sql)
4) Backend should use the `POSTGRES_URL` above and run with PORT=3001

Integration notes
- Backend connects via POSTGRES_URL and expects the database to be reachable at 127.0.0.1:5001.
- Frontend talks to backend at http://localhost:3001 (iOS simulator) or http://10.0.2.2:3001 (Android emulator).

Troubleshooting
- If the backend cannot connect:
  - Verify the DB is running at 127.0.0.1:5001
  - Check credentials and that the `myapp` database exists
- Network/port conflicts:
  - Ensure nothing else is bound to port 5001
- SSL or driver issues:
  - For local dev, use non-SSL connections unless configured otherwise
