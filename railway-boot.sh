#!/bin/sh
# Kortix boot script for Railway. One file, one role per image (KORTIX_ROLE is baked into each image).
#
# Derived from the boot script that the Kortix one-click blueprint (kortix-ai/suna, `stack/generate.py`) ships to every service,
# with the Railway differences applied:
#   - private hosts are <service>.railway.internal, and every public service listens on the injected PORT (8080), because
#     Railway's healthcheck dials the injected port;
#   - the three secrets (JWT_SECRET, KORTIX_SECRET_SEED, POSTGRES_PASSWORD) come from the template as ${{secret()}} values;
#   - sign-up is closed (GoTrue before-user-created hook plus KORTIX_SIGNUP_MODE=closed) and the single admin is created from
#     ADMIN_EMAIL / ADMIN_PASSWORD at boot, so the deploy form stays empty and nobody can claim the first account.
set -eu

role="${KORTIX_ROLE:?KORTIX_ROLE is not set}"
log() { echo "[kortix-boot:$role] $*"; }

DB_HOST="${DB_HOST:-db.railway.internal}"
AUTH_HOST="${AUTH_HOST:-auth.railway.internal}"
REST_HOST="${REST_HOST:-rest.railway.internal}"
STORAGE_HOST="${STORAGE_HOST:-storage.railway.internal}"
KONG_HOST="${KONG_HOST:-kong.railway.internal}"
API_HOST="${API_HOST:-api.railway.internal}"
GATEWAY_HOST="${GATEWAY_HOST:-gateway.railway.internal}"
# Ports the siblings dial. api and kong are public services, so they listen on Railway's injected 8080.
API_PORT=8080
KONG_PORT=8080

# derive LABEL -> 64 hex chars, stable for one KORTIX_SECRET_SEED.
derive() {
  printf '%s:%s' "$1" "${KORTIX_SECRET_SEED:?KORTIX_SECRET_SEED is not set}" | sha256sum | cut -c1-64
}

# hmac_b64url DATA -> base64url(HMAC-SHA256(JWT_SECRET, DATA))
hmac_b64url() {
  if command -v openssl >/dev/null 2>&1; then
    printf '%s' "$1" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | base64 | tr '+/' '-_' | tr -d '=\n'
  elif command -v node >/dev/null 2>&1; then
    node -e 'process.stdout.write(require("crypto").createHmac("sha256",process.env.JWT_SECRET).update(process.argv[1]).digest("base64url"))' "$1"
  else
    bun -e 'process.stdout.write(require("crypto").createHmac("sha256",process.env.JWT_SECRET).update(process.argv[1]).digest("base64url"))' "$1"
  fi
}

# Supabase legacy API key for a role, identical to `kortix self-host init`'s.
supabase_key() {
  case "$1" in
    anon) payload='eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlIiwiaWF0IjoxNjQxMDI0MDAwLCJleHAiOjIxMTQzODA4MDB9' ;;
    service_role) payload='eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UiLCJpYXQiOjE2NDEwMjQwMDAsImV4cCI6MjExNDM4MDgwMH0' ;;
  esac
  hp="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.$payload"
  printf '%s.%s' "$hp" "$(hmac_b64url "$hp")"
}

need_jwt_secret() { : "${JWT_SECRET:?JWT_SECRET is not set}"; export JWT_SECRET; }
anon_key() { need_jwt_secret; printf '%s' "${SUPABASE_ANON_KEY:-$(supabase_key anon)}"; }
service_key() { need_jwt_secret; printf '%s' "${SUPABASE_SERVICE_ROLE_KEY:-$(supabase_key service_role)}"; }
need_seed() { : "${KORTIX_SECRET_SEED:?KORTIX_SECRET_SEED is not set}"; }
db_url() { printf 'postgres://%s:%s@%s:5432/postgres' "$1" "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set}" "$DB_HOST"; }

# Wait until a URL answers 2xx. Uses bun, node or wget, whichever the image has.
wait_for() {
  if command -v bun >/dev/null 2>&1; then
    until bun -e 'fetch(process.argv[1]).then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))' "$1"; do sleep 3; done
  else
    until node -e 'fetch(process.argv[1]).then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))' "$1"; do sleep 3; done
  fi
}

case "$role" in
  db)
    need_seed; need_jwt_secret
    # Railway mounts the volume owned by root. The data directory is a subfolder of the mount, so lost+found never lands in it.
    mkdir -p "$(dirname "${PGDATA:-/var/lib/postgresql/data/pgdata}")"
    chown postgres:postgres "$(dirname "${PGDATA:-/var/lib/postgresql/data/pgdata}")"
    # Supabase's vault/pgsodium root key, derived so it survives redeploys without a second volume.
    derive pgsodium-root-key > /etc/postgresql-custom/pgsodium_root.key
    chown postgres:postgres /etc/postgresql-custom/pgsodium_root.key 2>/dev/null || true
    export POSTGRES_HOST=/var/run/postgresql PGPORT=5432 POSTGRES_PORT=5432 POSTGRES_DB=postgres PGDATABASE=postgres
    export PGPASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set}"
    export JWT_EXP="${JWT_EXPIRY:-3600}"
    # Supabase's postgresql.conf pins data_directory, so PGDATA alone is ignored; pass it explicitly.
    exec docker-entrypoint.sh postgres -c config_file=/etc/postgresql/postgresql.conf \
      -c data_directory="${PGDATA:-/var/lib/postgresql/data/pgdata}" \
      -c max_connections="${POSTGRES_MAX_CONNECTIONS:-200}" -c log_min_messages=fatal
    ;;

  auth)
    need_seed; need_jwt_secret
    export GOTRUE_JWT_SECRET="$JWT_SECRET"
    export GOTRUE_DB_DATABASE_URL="$(db_url supabase_auth_admin)"
    # No mail server: accounts are confirmed on creation, and nobody can sign up (see the hook below).
    export GOTRUE_HOOK_SEND_EMAIL_ENABLED=false
    export GOTRUE_MAILER_AUTOCONFIRM=true
    # Closed sign-up: Kortix's own before-user-created hook (created by its migrations) refuses every address that is not
    # reserved, so GoTrue answers 403 "Sign-up on this instance is closed." to the public sign-up endpoint.
    export GOTRUE_HOOK_BEFORE_USER_CREATED_ENABLED=true
    export GOTRUE_HOOK_BEFORE_USER_CREATED_URI="pg-functions://postgres/kortix/before_user_created_hook"
    exec auth
    ;;

  storage)
    need_seed; need_jwt_secret
    export ANON_KEY="$(anon_key)" SERVICE_KEY="$(service_key)" AUTH_JWT_SECRET="$JWT_SECRET"
    export DATABASE_URL="$(db_url supabase_storage_admin)"
    export POSTGREST_URL="http://$REST_HOST:3000"
    export S3_PROTOCOL_ACCESS_KEY_ID="${S3_PROTOCOL_ACCESS_KEY_ID:-$(derive s3-access-key-id | cut -c1-32)}"
    export S3_PROTOCOL_ACCESS_KEY_SECRET="${S3_PROTOCOL_ACCESS_KEY_SECRET:-$(derive s3-access-key-secret)}"
    exec docker-entrypoint.sh node dist/start/server.js
    ;;

  kong)
    need_seed; need_jwt_secret
    export SUPABASE_ANON_KEY="$(anon_key)" SUPABASE_SERVICE_KEY="$(service_key)"
    export DASHBOARD_USERNAME="${DASHBOARD_USERNAME:-kortix}"
    export DASHBOARD_PASSWORD="${DASHBOARD_PASSWORD:-$(derive kong-dashboard)}"
    mkdir -p /tmp/kong
    cp /opt/kortix/kong/temp.yml /opt/kortix/kong/kong-entrypoint.sh /tmp/kong/
    sed -i -e "s#http://auth:9999#http://$AUTH_HOST:9999#g" \
           -e "s#http://rest:3000#http://$REST_HOST:3000#g" \
           -e "s#http://storage:5000#http://$STORAGE_HOST:5000#g" /tmp/kong/temp.yml
    sed -i 's#/home/kong/temp.yml#/tmp/kong/temp.yml#g' /tmp/kong/kong-entrypoint.sh
    # Railway's healthcheck needs one unauthenticated 200 route; Kong has none.
    sed -i '/^services:$/r /opt/kortix/kong/healthz.yml' /tmp/kong/temp.yml
    # Public service on the injected port, dual stack; the private network resolves to IPv6, so look AAAA up too.
    export KONG_PROXY_LISTEN="0.0.0.0:${PORT:-8080}, [::]:${PORT:-8080}"
    export KONG_DNS_ORDER="LAST,AAAA,A,CNAME"
    exec sh /tmp/kong/kong-entrypoint.sh
    ;;

  api)
    need_seed; need_jwt_secret
    : "${ADMIN_EMAIL:?ADMIN_EMAIL is not set}" "${ADMIN_PASSWORD:?ADMIN_PASSWORD is not set}"
    export SUPABASE_ANON_KEY="$(anon_key)" SUPABASE_SERVICE_ROLE_KEY="$(service_key)" SUPABASE_JWT_SECRET="$JWT_SECRET"
    export DATABASE_URL="$(db_url postgres | sed 's#^postgres://#postgresql://#')"
    export SUPABASE_URL="http://$KONG_HOST:$KONG_PORT"
    export LLM_GATEWAY_PROXY_TARGET="http://$GATEWAY_HOST:8090"
    export KORTIX_CONFIG_ARCHIVE_S3_ENDPOINT="http://$KONG_HOST:$KONG_PORT/storage/v1/s3"
    export KORTIX_CONFIG_ARCHIVE_S3_ACCESS_KEY_ID="${S3_PROTOCOL_ACCESS_KEY_ID:-$(derive s3-access-key-id | cut -c1-32)}"
    export KORTIX_CONFIG_ARCHIVE_S3_SECRET_ACCESS_KEY="${S3_PROTOCOL_ACCESS_KEY_SECRET:-$(derive s3-access-key-secret)}"
    export API_KEY_SECRET="${API_KEY_SECRET:-$(derive api-key-secret)}"
    export INTERNAL_SERVICE_KEY="${INTERNAL_SERVICE_KEY:-$(derive internal-service-key)}"
    export TUNNEL_SIGNING_SECRET="${TUNNEL_SIGNING_SECRET:-$(derive tunnel-signing-secret)}"
    export GATEWAY_INTERNAL_TOKEN="${GATEWAY_INTERNAL_TOKEN:-$(derive gateway-internal-token)}"
    export KORTIX_URL="${KORTIX_URL:-$API_PUBLIC_URL}"
    export CORS_ALLOWED_ORIGINS="${CORS_ALLOWED_ORIGINS:-$PUBLIC_URL,$API_PUBLIC_URL}"
    export ENABLE_EMAIL_AUTOCONFIRM=true KORTIX_PUBLIC_AUTH_METHODS="${KORTIX_PUBLIC_AUTH_METHODS:-password}"
    # Closed sign-up: the API writes the policy at boot; the admin address is reserved so it cannot be claimed through sign-up.
    export KORTIX_SIGNUP_MODE=closed
    export KORTIX_PLATFORM_ADMIN_EMAILS="$ADMIN_EMAIL"
    # Kortix runs its migrations before the API starts. They need GoTrue's auth schema, so wait for auth first.
    log "waiting for auth at http://$AUTH_HOST:9999/health"
    wait_for "http://$AUTH_HOST:9999/health"
    log "running database migrations"
    bun /app/packages/db/scripts/migrate.ts bootstrap
    # The one admin login, created through GoTrue's admin API. 422 means it exists already (a redeploy), which is fine.
    log "creating the admin login"
    bun -e '
      const [url, key, email, password] = process.argv.slice(1);
      const r = await fetch(url + "/admin/users", {
        method: "POST",
        headers: { "content-type": "application/json", authorization: "Bearer " + key, apikey: key },
        body: JSON.stringify({ email, password, email_confirm: true }),
      });
      if (r.ok) console.log("[kortix-boot:api] admin created");
      else if (r.status === 422) console.log("[kortix-boot:api] admin exists");
      else { console.error("[kortix-boot:api] admin create failed " + r.status + " " + (await r.text())); process.exit(1); }
    ' "http://$AUTH_HOST:9999" "$SUPABASE_SERVICE_ROLE_KEY" "$ADMIN_EMAIL" "$ADMIN_PASSWORD"
    unset ADMIN_PASSWORD
    exec /usr/local/bin/docker-entrypoint.sh bun run src/index.ts
    ;;

  gateway)
    need_seed
    # Private service: Railway still injects PORT=8080, so pin the port the siblings dial.
    export PORT=8090
    export GATEWAY_INTERNAL_TOKEN="${GATEWAY_INTERNAL_TOKEN:-$(derive gateway-internal-token)}"
    export KORTIX_API_URL="http://$API_HOST:$API_PORT"
    exec /usr/local/bin/docker-entrypoint.sh bun run src/main.ts
    ;;

  frontend)
    need_jwt_secret
    export SUPABASE_ANON_KEY="$(anon_key)"
    export KORTIX_PUBLIC_SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY"
    export KORTIX_API_PROXY_TARGET="http://$API_HOST:$API_PORT"
    export SUPABASE_SERVER_URL="http://$KONG_HOST:$KONG_PORT"
    export KORTIX_PUBLIC_AUTH_METHODS="${KORTIX_PUBLIC_AUTH_METHODS:-password}"
    export KORTIX_PUBLIC_CONNECTORS_ENABLED="${KORTIX_PUBLIC_CONNECTORS_ENABLED:-false}"
    unset COMPOSIO_API_KEY EMAIL_URL
    exec /docker-entrypoint.sh
    ;;

  *)
    log "unknown KORTIX_ROLE"; exit 64 ;;
esac
