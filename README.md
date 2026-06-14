# matsu Auth

Haskell + Servant authentication server for the matsu workspace.

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

## Development Key

`keys/private.pem` and `keys/jwks.json` are development-only key material so the full authentication flow can run locally without external secret management.

For production-like environments, replace these files with keys managed outside the repository and rotate `kid` values deliberately.
