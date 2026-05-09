#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="Dujiao-Next"
DEFAULT_DEPLOY_DIR="/opt/dujiao-next"

DEPLOY_DIR="${DUJIAO_NEXT_DIR:-$DEFAULT_DEPLOY_DIR}"
DB_BACKEND=""
TAG="${TAG:-latest}"
TZ_VALUE="${TZ:-Asia/Shanghai}"
API_PORT="${API_PORT:-8080}"
USER_PORT="${USER_PORT:-8081}"
ADMIN_PORT="${ADMIN_PORT:-8082}"
ADMIN_USERNAME="${DJ_DEFAULT_ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${DJ_DEFAULT_ADMIN_PASSWORD:-}"
POSTGRES_DB="${POSTGRES_DB:-dujiao_next}"
POSTGRES_USER="${POSTGRES_USER:-dujiao}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
USER_DOMAIN="${USER_DOMAIN:-user.example.com}"
ADMIN_DOMAIN="${ADMIN_DOMAIN:-admin.example.com}"
AUTO_YES=0
START_SERVICES=1

usage() {
  cat <<'EOF'
Install Dujiao-Next with Docker Compose.

Usage:
  bash install-dujiao-next.sh [options]

Options:
  --postgres              Use PostgreSQL + Redis. Default for unattended installs.
  --sqlite                Use SQLite + Redis.
  --dir PATH              Deployment directory. Default: /opt/dujiao-next
  --tag TAG               Docker image tag. Default: latest
  --tz TZ                 Timezone. Default: Asia/Shanghai
  --api-port PORT         Bind API to 127.0.0.1:PORT. Default: 8080
  --user-port PORT        Bind user frontend to 127.0.0.1:PORT. Default: 8081
  --admin-port PORT       Bind admin frontend to 127.0.0.1:PORT. Default: 8082
  --admin-user USER       Initial admin username. Default: admin
  --admin-pass PASSWORD   Initial admin password. Default: generated
  --user-domain DOMAIN    Domain used in generated Nginx example.
  --admin-domain DOMAIN   Domain used in generated Nginx example.
  --no-start              Only generate files, do not run docker compose up.
  -y, --yes               Non-interactive mode, accept defaults.
  -h, --help              Show this help.

Examples:
  bash install-dujiao-next.sh --postgres
  bash install-dujiao-next.sh --sqlite --dir /opt/dujiao-next --no-start
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  printf '\n[%s] %s\n' "$APP_NAME" "$*"
}

is_interactive() {
  [[ "$AUTO_YES" -eq 0 && -t 0 ]]
}

random_hex() {
  local bytes="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
  else
    od -An -N"$bytes" -tx1 /dev/urandom | tr -d ' \n'
  fi
}

random_admin_password() {
  printf 'Djn%sA9x' "$(random_hex 8)"
}

validate_port() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be a number: $value"
  (( value >= 1 && value <= 65535 )) || die "$name must be between 1 and 65535: $value"
}

prompt_value() {
  local label="$1"
  local default_value="$2"
  local result

  if is_interactive; then
    read -r -p "$label [$default_value]: " result
    printf '%s' "${result:-$default_value}"
  else
    printf '%s' "$default_value"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --postgres)
        DB_BACKEND="postgres"
        ;;
      --sqlite)
        DB_BACKEND="sqlite"
        ;;
      --dir)
        [[ $# -ge 2 ]] || die "--dir requires a path"
        DEPLOY_DIR="$2"
        shift
        ;;
      --tag)
        [[ $# -ge 2 ]] || die "--tag requires a value"
        TAG="$2"
        shift
        ;;
      --tz)
        [[ $# -ge 2 ]] || die "--tz requires a value"
        TZ_VALUE="$2"
        shift
        ;;
      --api-port)
        [[ $# -ge 2 ]] || die "--api-port requires a value"
        API_PORT="$2"
        shift
        ;;
      --user-port)
        [[ $# -ge 2 ]] || die "--user-port requires a value"
        USER_PORT="$2"
        shift
        ;;
      --admin-port)
        [[ $# -ge 2 ]] || die "--admin-port requires a value"
        ADMIN_PORT="$2"
        shift
        ;;
      --admin-user)
        [[ $# -ge 2 ]] || die "--admin-user requires a value"
        ADMIN_USERNAME="$2"
        shift
        ;;
      --admin-pass)
        [[ $# -ge 2 ]] || die "--admin-pass requires a value"
        ADMIN_PASSWORD="$2"
        shift
        ;;
      --user-domain)
        [[ $# -ge 2 ]] || die "--user-domain requires a value"
        USER_DOMAIN="$2"
        shift
        ;;
      --admin-domain)
        [[ $# -ge 2 ]] || die "--admin-domain requires a value"
        ADMIN_DOMAIN="$2"
        shift
        ;;
      --no-start)
        START_SERVICES=0
        ;;
      -y|--yes)
        AUTO_YES=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
    shift
  done
}

collect_inputs() {
  if [[ -z "$DB_BACKEND" ]]; then
    if is_interactive; then
      local selected
      read -r -p "Database backend [postgres/sqlite] (default: postgres): " selected
      selected="${selected:-postgres}"
      case "$selected" in
        postgres|Postgres|POSTGRES)
          DB_BACKEND="postgres"
          ;;
        sqlite|SQLite|SQLITE)
          DB_BACKEND="sqlite"
          ;;
        *)
          die "Unsupported database backend: $selected"
          ;;
      esac
    else
      DB_BACKEND="postgres"
    fi
  fi

  DEPLOY_DIR="$(prompt_value "Deploy directory" "$DEPLOY_DIR")"
  ADMIN_USERNAME="$(prompt_value "Initial admin username" "$ADMIN_USERNAME")"
  USER_DOMAIN="$(prompt_value "User domain for Nginx example" "$USER_DOMAIN")"
  ADMIN_DOMAIN="$(prompt_value "Admin domain for Nginx example" "$ADMIN_DOMAIN")"

  [[ "$DB_BACKEND" == "postgres" || "$DB_BACKEND" == "sqlite" ]] || die "Unsupported database backend: $DB_BACKEND"
  [[ "$ADMIN_USERNAME" != *[[:space:]]* ]] || die "Admin username cannot contain whitespace"

  validate_port "API port" "$API_PORT"
  validate_port "User port" "$USER_PORT"
  validate_port "Admin port" "$ADMIN_PORT"

  if [[ -z "$ADMIN_PASSWORD" ]]; then
    ADMIN_PASSWORD="$(random_admin_password)"
  fi
  if [[ -z "$REDIS_PASSWORD" ]]; then
    REDIS_PASSWORD="$(random_hex 24)"
  fi
  if [[ -z "$POSTGRES_PASSWORD" ]]; then
    POSTGRES_PASSWORD="$(random_hex 24)"
  fi
}

ensure_dependencies() {
  if [[ "$START_SERVICES" -eq 0 ]]; then
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      COMPOSE_CMD=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1; then
      COMPOSE_CMD=(docker-compose)
    else
      COMPOSE_CMD=(docker compose)
    fi
    return
  fi

  command -v docker >/dev/null 2>&1 || die "Docker is not installed or not in PATH."

  if docker info >/dev/null 2>&1; then
    DOCKER_CMD=(docker)
  elif command -v sudo >/dev/null 2>&1; then
    if is_interactive && sudo docker info >/dev/null 2>&1; then
      DOCKER_CMD=(sudo docker)
    elif [[ "$AUTO_YES" -eq 1 ]] && sudo -n docker info >/dev/null 2>&1; then
      DOCKER_CMD=(sudo docker)
    else
      die "Docker daemon is not reachable. Start Docker or run this script with a user allowed to access Docker."
    fi
  else
    die "Docker daemon is not reachable. Start Docker or run this script with a user allowed to access Docker."
  fi

  if "${DOCKER_CMD[@]}" compose version >/dev/null 2>&1; then
    COMPOSE_CMD=("${DOCKER_CMD[@]}" compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    if [[ "${DOCKER_CMD[0]}" == "sudo" ]]; then
      COMPOSE_CMD=(sudo docker-compose)
    else
      COMPOSE_CMD=(docker-compose)
    fi
  else
    die "Docker Compose is not available. Install the Docker Compose plugin or docker-compose."
  fi
}

prepare_directories() {
  log "Preparing deployment directory: $DEPLOY_DIR"

  local parent_dir
  parent_dir="$(dirname "$DEPLOY_DIR")"
  if [[ -d "$DEPLOY_DIR" && -w "$DEPLOY_DIR" ]]; then
    mkdir -p "$DEPLOY_DIR"
  elif [[ -d "$parent_dir" && -w "$parent_dir" ]]; then
    mkdir -p "$DEPLOY_DIR"
  elif [[ "$EUID" -eq 0 ]]; then
    mkdir -p "$DEPLOY_DIR"
  elif command -v sudo >/dev/null 2>&1; then
    sudo mkdir -p "$DEPLOY_DIR"
    sudo chown -R "$(id -u):$(id -g)" "$DEPLOY_DIR"
  else
    die "Cannot create $DEPLOY_DIR. Run as root or choose a writable --dir."
  fi

  mkdir -p \
    "$DEPLOY_DIR/config" \
    "$DEPLOY_DIR/data/db" \
    "$DEPLOY_DIR/data/uploads" \
    "$DEPLOY_DIR/data/logs" \
    "$DEPLOY_DIR/data/redis" \
    "$DEPLOY_DIR/data/postgres"

  chmod -R 0777 \
    "$DEPLOY_DIR/data/logs" \
    "$DEPLOY_DIR/data/db" \
    "$DEPLOY_DIR/data/uploads" \
    "$DEPLOY_DIR/data/redis" \
    "$DEPLOY_DIR/data/postgres"
}

backup_if_exists() {
  local path="$1"
  if [[ -e "$path" ]]; then
    local ts
    ts="$(date +%Y%m%d%H%M%S)"
    cp -a "$path" "$path.bak.$ts"
    echo "Backed up existing file: $path.bak.$ts"
  fi
}

write_env_file() {
  backup_if_exists "$DEPLOY_DIR/.env"

  cat > "$DEPLOY_DIR/.env" <<ENV
TAG=$TAG
TZ=$TZ_VALUE

API_PORT=$API_PORT
USER_PORT=$USER_PORT
ADMIN_PORT=$ADMIN_PORT

DJ_DEFAULT_ADMIN_USERNAME=$ADMIN_USERNAME
DJ_DEFAULT_ADMIN_PASSWORD=$ADMIN_PASSWORD

REDIS_PASSWORD=$REDIS_PASSWORD

POSTGRES_DB=$POSTGRES_DB
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
ENV
}

write_config_file() {
  backup_if_exists "$DEPLOY_DIR/config/config.yml"

  local app_secret jwt_secret user_jwt_secret database_config
  app_secret="$(random_hex 16)"
  jwt_secret="$(random_hex 32)"
  user_jwt_secret="$(random_hex 32)"

  if [[ "$DB_BACKEND" == "postgres" ]]; then
    printf -v database_config '%s\n' \
      "  driver: postgres" \
      "  dsn: host=postgres user=$POSTGRES_USER password=$POSTGRES_PASSWORD dbname=$POSTGRES_DB port=5432 sslmode=disable TimeZone=$TZ_VALUE" \
      "  pool:" \
      "    max_open_conns: 20" \
      "    max_idle_conns: 5" \
      "    conn_max_lifetime_seconds: 1200" \
      "    conn_max_idle_time_seconds: 300"
  else
    printf -v database_config '%s\n' \
      "  driver: sqlite" \
      "  dsn: /app/db/dujiao.db?_busy_timeout=5000&_journal_mode=WAL&_synchronous=NORMAL" \
      "  pool:" \
      "    max_open_conns: 1" \
      "    max_idle_conns: 1" \
      "    conn_max_lifetime_seconds: 0" \
      "    conn_max_idle_time_seconds: 0"
  fi

  cat > "$DEPLOY_DIR/config/config.yml" <<YAML
app:
  secret_key: "$app_secret"
  totp_issuer: Dujiao-Next

server:
  host: 0.0.0.0
  port: 8080
  mode: release

log:
  dir: /app/logs
  filename: app.log
  max_size_mb: 100
  max_backups: 14
  max_age_days: 30
  compress: true

database:
$database_config

jwt:
  secret: "$jwt_secret"
  expire_hours: 24

user_jwt:
  secret: "$user_jwt_secret"
  expire_hours: 24
  remember_me_expire_hours: 168

bootstrap:
  default_admin_username: ""
  default_admin_password: ""

telegram_auth:
  enabled: false
  bot_username: ""
  bot_token: ""
  mini_app_url: ""
  login_expire_seconds: 300
  replay_ttl_seconds: 300

redis:
  enabled: true
  host: redis
  port: 6379
  password: "$REDIS_PASSWORD"
  db: 0
  prefix: "dj"

queue:
  enabled: true
  host: redis
  port: 6379
  password: "$REDIS_PASSWORD"
  db: 1
  concurrency: 10
  queues:
    default: 10
    critical: 5

upstream_sync_interval: "5m"

upload:
  max_size: 10485760
  allowed_types:
    - image/jpeg
    - image/png
    - image/gif
    - image/webp
    - image/svg+xml
  allowed_extensions:
    - .jpg
    - .jpeg
    - .png
    - .gif
    - .webp
    - .svg
  max_width: 4096
  max_height: 4096

cors:
  allowed_origins:
    - "*"
  allowed_methods:
    - GET
    - POST
    - PUT
    - PATCH
    - DELETE
    - OPTIONS
  allowed_headers:
    - Content-Type
    - Content-Length
    - Accept-Encoding
    - Authorization
    - Cache-Control
    - X-Requested-With
    - X-CSRF-Token
  allow_credentials: false
  max_age: 600

security:
  login_rate_limit:
    window_seconds: 300
    max_attempts: 5
    block_seconds: 900
  password_policy:
    min_length: 8
    require_upper: true
    require_lower: true
    require_number: true
    require_special: false

email:
  enabled: false
  host: smtp.example.com
  port: 465
  username: ""
  password: ""
  from: ""
  from_name: Dujiao-Next
  use_tls: false
  use_ssl: true
  verify_code:
    expire_minutes: 10
    send_interval_seconds: 60
    max_attempts: 5
    length: 6

order:
  payment_expire_minutes: 15

web:
  admin_path: "/admin"
YAML
}

write_compose_files() {
  backup_if_exists "$DEPLOY_DIR/docker-compose.sqlite.yml"
  backup_if_exists "$DEPLOY_DIR/docker-compose.postgres.yml"

  cat > "$DEPLOY_DIR/docker-compose.sqlite.yml" <<'YAML'
services:
  redis:
    image: redis:7-alpine
    container_name: dujiaonext-redis
    restart: unless-stopped
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD}
    command: ["redis-server", "--appendonly", "yes", "--requirepass", "${REDIS_PASSWORD}"]
    volumes:
      - ./data/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 3s
      retries: 10
    networks:
      - dujiao-net

  api:
    image: dujiaonext/api:${TAG}
    container_name: dujiaonext-api
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      DJ_DEFAULT_ADMIN_USERNAME: ${DJ_DEFAULT_ADMIN_USERNAME}
      DJ_DEFAULT_ADMIN_PASSWORD: ${DJ_DEFAULT_ADMIN_PASSWORD}
    ports:
      - "127.0.0.1:${API_PORT}:8080"
    volumes:
      - ./config/config.yml:/app/config.yml:ro
      - ./data/db:/app/db
      - ./data/uploads:/app/uploads
      - ./data/logs:/app/logs
    depends_on:
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8080/health"]
      interval: 10s
      timeout: 3s
      retries: 10
    networks:
      - dujiao-net

  user:
    image: dujiaonext/user:${TAG}
    container_name: dujiaonext-user
    restart: unless-stopped
    environment:
      TZ: ${TZ}
    ports:
      - "127.0.0.1:${USER_PORT}:80"
    depends_on:
      api:
        condition: service_healthy
    networks:
      - dujiao-net

  admin:
    image: dujiaonext/admin:${TAG}
    container_name: dujiaonext-admin
    restart: unless-stopped
    environment:
      TZ: ${TZ}
    ports:
      - "127.0.0.1:${ADMIN_PORT}:80"
    depends_on:
      api:
        condition: service_healthy
    networks:
      - dujiao-net

networks:
  dujiao-net:
    driver: bridge
YAML

  cat > "$DEPLOY_DIR/docker-compose.postgres.yml" <<'YAML'
services:
  redis:
    image: redis:7-alpine
    container_name: dujiaonext-redis
    restart: unless-stopped
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD}
    command: ["redis-server", "--appendonly", "yes", "--requirepass", "${REDIS_PASSWORD}"]
    volumes:
      - ./data/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 3s
      retries: 10
    networks:
      - dujiao-net

  postgres:
    image: postgres:16-alpine
    container_name: dujiaonext-postgres
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - dujiao-net

  api:
    image: dujiaonext/api:${TAG}
    container_name: dujiaonext-api
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      DJ_DEFAULT_ADMIN_USERNAME: ${DJ_DEFAULT_ADMIN_USERNAME}
      DJ_DEFAULT_ADMIN_PASSWORD: ${DJ_DEFAULT_ADMIN_PASSWORD}
    ports:
      - "127.0.0.1:${API_PORT}:8080"
    volumes:
      - ./config/config.yml:/app/config.yml:ro
      - ./data/uploads:/app/uploads
      - ./data/logs:/app/logs
    depends_on:
      redis:
        condition: service_healthy
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8080/health"]
      interval: 10s
      timeout: 3s
      retries: 10
    networks:
      - dujiao-net

  user:
    image: dujiaonext/user:${TAG}
    container_name: dujiaonext-user
    restart: unless-stopped
    environment:
      TZ: ${TZ}
    ports:
      - "127.0.0.1:${USER_PORT}:80"
    depends_on:
      api:
        condition: service_healthy
    networks:
      - dujiao-net

  admin:
    image: dujiaonext/admin:${TAG}
    container_name: dujiaonext-admin
    restart: unless-stopped
    environment:
      TZ: ${TZ}
    ports:
      - "127.0.0.1:${ADMIN_PORT}:80"
    depends_on:
      api:
        condition: service_healthy
    networks:
      - dujiao-net

networks:
  dujiao-net:
    driver: bridge
YAML
}

write_nginx_example() {
  backup_if_exists "$DEPLOY_DIR/nginx.dujiao-next.example.conf"

  cat > "$DEPLOY_DIR/nginx.dujiao-next.example.conf" <<NGINX
# Example only. Install this in your real Nginx site config and add HTTPS.

server {
    listen 80;
    server_name $USER_DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:$USER_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:$API_PORT/api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /uploads/ {
        proxy_pass http://127.0.0.1:$API_PORT/uploads/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

server {
    listen 80;
    server_name $ADMIN_DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:$ADMIN_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:$API_PORT/api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /uploads/ {
        proxy_pass http://127.0.0.1:$API_PORT/uploads/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX
}

write_readme() {
  local compose_file="docker-compose.$DB_BACKEND.yml"
  backup_if_exists "$DEPLOY_DIR/README.install.txt"

  cat > "$DEPLOY_DIR/README.install.txt" <<README
Dujiao-Next Docker Compose install

Deployment directory:
  $DEPLOY_DIR

Selected backend:
  $DB_BACKEND

Useful commands:
  cd $DEPLOY_DIR
  docker compose --env-file .env -f $compose_file ps
  docker compose --env-file .env -f $compose_file logs -f api
  docker compose --env-file .env -f $compose_file pull
  docker compose --env-file .env -f $compose_file up -d
  docker compose --env-file .env -f $compose_file down

Local checks on the server:
  API:   http://127.0.0.1:$API_PORT/health
  User:  http://127.0.0.1:$USER_PORT
  Admin: http://127.0.0.1:$ADMIN_PORT

Initial admin:
  Username: $ADMIN_USERNAME
  Password: $ADMIN_PASSWORD

Nginx example:
  $DEPLOY_DIR/nginx.dujiao-next.example.conf

Important:
  Redis and PostgreSQL are not exposed to the public network.
  API/User/Admin are bound to 127.0.0.1 and should be accessed through Nginx.
  Change the initial admin password after first login.
README
}

write_files() {
  log "Writing .env, config.yml, compose files, and Nginx example"
  write_env_file
  write_config_file
  write_compose_files
  write_nginx_example
  write_readme
}

start_services() {
  local compose_file="docker-compose.$DB_BACKEND.yml"
  if [[ "$START_SERVICES" -eq 0 ]]; then
    log "Files generated. Skipping docker compose up because --no-start was set."
    return
  fi

  log "Pulling images and starting services with $compose_file"
  (
    cd "$DEPLOY_DIR"
    "${COMPOSE_CMD[@]}" --env-file .env -f "$compose_file" pull
    "${COMPOSE_CMD[@]}" --env-file .env -f "$compose_file" up -d
    "${COMPOSE_CMD[@]}" --env-file .env -f "$compose_file" ps
  )
}

print_summary() {
  local compose_file="docker-compose.$DB_BACKEND.yml"
  cat <<SUMMARY

Done.

Deployment directory:
  $DEPLOY_DIR

Compose file:
  $compose_file

Initial admin:
  Username: $ADMIN_USERNAME
  Password: $ADMIN_PASSWORD

Local URLs on the server:
  API health: http://127.0.0.1:$API_PORT/health
  User:       http://127.0.0.1:$USER_PORT
  Admin:      http://127.0.0.1:$ADMIN_PORT

Nginx reverse proxy example:
  $DEPLOY_DIR/nginx.dujiao-next.example.conf

Useful commands:
  cd $DEPLOY_DIR
  ${COMPOSE_CMD[*]} --env-file .env -f $compose_file ps
  ${COMPOSE_CMD[*]} --env-file .env -f $compose_file logs -f api
  ${COMPOSE_CMD[*]} --env-file .env -f $compose_file down

SUMMARY
}

main() {
  parse_args "$@"
  collect_inputs
  ensure_dependencies
  prepare_directories
  write_files
  start_services
  print_summary
}

main "$@"
