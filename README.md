# matsu Auth

Haskell + Servant authentication server for the matsu workspace.

It issues RS256 JWT access tokens for `matsu-api` and refresh tokens used by `matsu-bff`.

## Tech Stack

- Haskell
- Servant
- PostgreSQL
- Docker / Docker Compose

## Endpoints

- `GET /health`
- `POST /auth/register`
- `POST /auth/login`
- `POST /auth/refresh`
- `GET /.well-known/jwks.json`

Access tokens are RS256 JWTs. The Laravel API verifies them with the JWKS endpoint.

## Local Start

```bash
docker compose up -d --build
```

Auth API:

```text
http://localhost:18081
```

PostgreSQL:

```text
localhost:15432
database: matsu-auth
user: matsu-auth
password: matsu-auth-pass
```

## Environment

Local Docker defaults:

```text
AUTH_PORT=8080
AUTH_DATABASE_URL=postgres://matsu-auth:matsu-auth-pass@auth-db:5432/matsu-auth
AUTH_ISSUER=http://localhost:18081
AUTH_AUDIENCE=matsu-api
AUTH_ACCESS_TOKEN_TTL_SECONDS=900
AUTH_REFRESH_TOKEN_TTL_SECONDS=2592000
AUTH_PRIVATE_KEY_PATH=/app/keys/private.pem
AUTH_JWKS_PATH=/app/keys/jwks.json
AUTH_KEY_ID=matsu-dev-key-1
AUTH_ALLOWED_ORIGIN=http://localhost:5173
```

## Development Key

`keys/private.pem` and `keys/jwks.json` are development-only key material so the full authentication flow can run locally without external secret management.

For production-like environments, replace these files with keys managed outside the repository and rotate `kid` values deliberately.
