FROM haskell:9.8-slim AS build

WORKDIR /build

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg pkg-config \
    && install -d /usr/share/postgresql-common/pgdg \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        | gpg --dearmor -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg \
    && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg] http://apt.postgresql.org/pub/repos/apt bullseye-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY kakeibo-auth.cabal cabal.project ./
RUN cabal update && cabal build --only-dependencies

COPY app ./app
RUN cabal build exe:kakeibo-auth \
    && cp "$(cabal list-bin exe:kakeibo-auth)" /usr/local/bin/kakeibo-auth

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libpq5 openssl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /usr/local/bin/kakeibo-auth /usr/local/bin/kakeibo-auth

EXPOSE 8080
CMD ["kakeibo-auth"]
