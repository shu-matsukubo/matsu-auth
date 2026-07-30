CREATE TABLE IF NOT EXISTS users (
    sub uuid PRIMARY KEY,
    email text NOT NULL UNIQUE,
    password_hash text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS refresh_tokens (
    token text PRIMARY KEY,
    user_sub uuid NOT NULL REFERENCES users(sub) ON DELETE CASCADE,
    audience text NOT NULL DEFAULT 'matsu-api',
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS refresh_tokens_user_sub_idx ON refresh_tokens(user_sub);
CREATE INDEX IF NOT EXISTS refresh_tokens_expires_at_idx ON refresh_tokens(expires_at);

CREATE TABLE IF NOT EXISTS authorization_requests (
    request_id text PRIMARY KEY,
    client_id text NOT NULL,
    redirect_uri text NOT NULL,
    state text NOT NULL,
    scope text NOT NULL,
    code_challenge text NOT NULL,
    expires_at timestamptz NOT NULL,
    used_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS authorization_requests_expires_at_idx
    ON authorization_requests(expires_at);

CREATE TABLE IF NOT EXISTS authorization_codes (
    code text PRIMARY KEY,
    user_sub uuid NOT NULL REFERENCES users(sub) ON DELETE CASCADE,
    client_id text NOT NULL,
    redirect_uri text NOT NULL,
    code_challenge text NOT NULL,
    scope text NOT NULL,
    expires_at timestamptz NOT NULL,
    used_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS authorization_codes_expires_at_idx
    ON authorization_codes(expires_at);
