# matsu Auth

Haskell + Servant authentication server for the matsu workspace.

It issues RS256 JWT access tokens for the allowlisted `matsu-api` and
`matsu-toolbox-api` resource servers, plus refresh tokens that retain their original audience.
Browser login uses an OAuth authorization code flow with PKCE and a server-rendered Lucid page.

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
- `GET /oauth/authorize`
- `POST /oauth/authorize`
- `POST /oauth/token`
- `GET /.well-known/jwks.json`
- `GET /.well-known/oauth-authorization-server`

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
AUTH_ALLOWED_RESOURCES=matsu-api,matsu-toolbox-api
AUTH_ACCESS_TOKEN_TTL_SECONDS=900
AUTH_REFRESH_TOKEN_TTL_SECONDS=2592000
AUTH_AUTHORIZATION_REQUEST_TTL_SECONDS=600
AUTH_AUTHORIZATION_CODE_TTL_SECONDS=120
AUTH_PRIVATE_KEY_PATH=/app/keys/private.pem
AUTH_JWKS_PATH=/app/keys/jwks.json
AUTH_KEY_ID=matsu-dev-key-1
AUTH_ALLOWED_ORIGIN=http://localhost:5173
AUTH_CLIENT_ID=matsu-bff
AUTH_CLIENT_SECRET=matsu-bff-dev-secret
AUTH_REDIRECT_URI=http://localhost:18082/auth/callback
AUTH_SCOPE=matsu-api
AUTH_LOGIN_START_URI=http://localhost:18082/auth/login
```

`AUTH_CLIENT_SECRET` and the development key files are local-only values. Replace them in deployed environments.
`AUTH_LOGIN_START_URI` is the retry destination shown when a browser authorization request is invalid or expired.

`AUTH_AUDIENCE` and `AUTH_SCOPE` remain the default resource for backward compatibility.
`AUTH_ALLOWED_RESOURCES` is a comma-separated allowlist. Direct register/login requests may
select one entry with an optional `audience` field; omitted values continue to use `matsu-api`.
OAuth requests use the selected scope as the JWT audience. Refresh-token rotation always keeps
the audience that was recorded when the refresh token was issued.

Example Toolbox login:

```bash
curl -X POST http://localhost:18081/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"user@example.com","password":"password","audience":"matsu-toolbox-api"}'
```

## Development Key

`keys/private.pem` and `keys/jwks.json` are development-only key material so the full authentication flow can run locally without external secret management.

For production-like environments, replace these files with keys managed outside the repository and rotate `kid` values deliberately.
