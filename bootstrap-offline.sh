#!/bin/bash
set -e

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
HOST="${HOST:-localhost}"
FROZEN_DIR="$BASE_DIR/.frozen-images"

# All container images needed by the stack
IMAGES=(
  "mariadb:11"
  "nginx:stable-alpine"
  "portainer/portainer-ce:latest"
  "phpipam/phpipam-www:latest"
  "phpipam/phpipam-cron:latest"
  "librenms/librenms:latest"
  "grafana/grafana:latest"
  "alpine:latest"
)

echo "============================================"
echo " Docker Infrastructure Bootstrap (Offline)"
echo "============================================"
echo ""

# --- Prerequisites ---
for cmd in docker openssl curl jq; do
  if ! command -v $cmd &>/dev/null; then
    echo "ERROR: '$cmd' not found."
    exit 1
  fi
done

if ! docker compose version &>/dev/null 2>&1 && ! docker-compose --version &>/dev/null 2>&1; then
  echo "ERROR: docker compose plugin not found."
  exit 1
fi
COMPOSE="docker compose"
docker compose version &>/dev/null 2>&1 || COMPOSE="docker-compose"

echo "[1/9] Creating directory structure..."
mkdir -p "$BASE_DIR"/mariadb/data
mkdir -p "$BASE_DIR"/nginx/config.d
mkdir -p "$BASE_DIR"/nginx/ssl
mkdir -p "$BASE_DIR"/nginx/html
mkdir -p "$BASE_DIR"/portainer/data
mkdir -p "$BASE_DIR"/phpipam/data
mkdir -p "$BASE_DIR"/librenms/data
mkdir -p "$BASE_DIR"/grafana/data

echo "[2/9] Pre-downloading container images via registry API..."
mkdir -p "$FROZEN_DIR"

download_and_load_image() {
  local img="$1"
  local safe_name="${img//\//_}"
  local img_dir="$FROZEN_DIR/$safe_name"

  if docker image inspect "$img" &>/dev/null; then
    echo "  [skip] $img already in local Docker store"
    return 0
  fi

  if [ -d "$img_dir" ] && [ -f "$img_dir/manifest.json" ]; then
    echo "  [load] $img from cached download..."
    tar -cC "$img_dir" . | docker load
    return 0
  fi

  echo "  [download] $img ..."
  mkdir -p "$img_dir"

  local image="${img%%[:@]*}"
  local tag="${img##*:}"
  [[ "$image" != *"/"* ]] && image="library/$image"

  local token
  token=$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$image:pull" | jq -r '.token')

  local manifest
  manifest=$(curl -fsSL \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://registry-1.docker.io/v2/$image/manifests/$tag")

  local mediaType
  mediaType=$(echo "$manifest" | jq -r '.mediaType // ""')

  local submanifest="$manifest"
  case "$mediaType" in
    application/vnd.oci.image.index.v1+json | application/vnd.docker.distribution.manifest.list.v2+json)
      local targetArch targetVariant
      targetArch=$( (uname -m) 2>/dev/null || echo "amd64")
      case "$targetArch" in x86_64) targetArch="amd64" ;; aarch64) targetArch="arm64" ;; armv7l|armv6l) targetArch="arm" ;; esac
      submanifest=$(echo "$manifest" | jq -r --arg arch "$targetArch" '.manifests[] | select(.platform.architecture==$arch) | .digest' | head -1)
      submanifest=$(curl -fsSL \
        -H "Authorization: Bearer $token" \
        -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
        -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
        "https://registry-1.docker.io/v2/$image/manifests/$submanifest")
      ;;
  esac

  local configDigest
  configDigest=$(echo "$submanifest" | jq -r '.config.digest')
  local configId="${configDigest#*:}"

  curl -fsSL -H "Authorization: Bearer $token" \
    "https://registry-1.docker.io/v2/$image/blobs/$configDigest" \
    -o "$img_dir/$configId.json"

  local layersCount
  layersCount=$(echo "$submanifest" | jq '.layers | length')

  local parentId=""
  local layerFiles=()

  for i in $(seq 0 $((layersCount - 1))); do
    local layerDigest
    layerDigest=$(echo "$submanifest" | jq -r ".layers[$i].digest")
    local layerId
    layerId=$(printf "%s\n%s" "$parentId" "$layerDigest" | sha256sum | cut -d' ' -f1)

    mkdir -p "$img_dir/$layerId"
    echo '1.0' > "$img_dir/$layerId/VERSION"
    jq '{ id: .id } + if .parent then { parent: .parent } else {} end' \
      <(printf '{ "id": "%s"%s }' "$layerId" "${parentId:+, \"parent\": \"$parentId\"}") \
      > "$img_dir/$layerId/json" 2>/dev/null || \
    printf '{ "id": "%s"%s }\n' "$layerId" "${parentId:+, \"parent\": \"$parentId\"}" \
      > "$img_dir/$layerId/json"

    local layerFile="$layerId/layer.blob"
    layerFiles+=("$layerFile")

    echo "    Layer $((i+1))/$layersCount..."
    curl -L -# -H "Authorization: Bearer $token" \
      "https://registry-1.docker.io/v2/$image/blobs/$layerDigest" \
      -o "$img_dir/$layerFile"
    parentId="$layerId"
  done

  local jqLayers="[]"
  for lf in "${layerFiles[@]}"; do
    jqLayers=$(echo "$jqLayers" | jq --arg f "$lf" '. + [$f]')
  done

  local repoName="${image#library/}"
  echo '{}' | jq \
    --arg config "$configId.json" \
    --arg tag "$tag" \
    --arg repo "$repoName" \
    --argjson layers "$jqLayers" \
    '{Config: $config, RepoTags: [$repo + ":" + $tag], Layers: $layers}' \
    > "$img_dir/manifest.json"

  echo "  [load] $img into Docker..."
  tar -cC "$img_dir" . | docker load
}

for img in "${IMAGES[@]}"; do
  download_and_load_image "$img"
done
echo "  All images ready"

echo "[3/9] Fixing Grafana data permissions..."
docker run --rm -v "$BASE_DIR/grafana/data:/data" alpine chown 472:472 /data 2>/dev/null || true
echo "  Grafana data dir ownership set to UID 472"

echo "[4/9] Generating SSL certificate..."
if [ ! -f "$BASE_DIR/nginx/ssl/nginx.key" ] || [ ! -f "$BASE_DIR/nginx/ssl/nginx.crt" ]; then
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "$BASE_DIR/nginx/ssl/nginx.key" \
    -out "$BASE_DIR/nginx/ssl/nginx.crt" \
    -subj "/CN=${HOST}" 2>/dev/null
  echo "  Self-signed cert generated (CN=${HOST}, 10 years)"
else
  echo "  SSL certificate already exists, skipping"
fi

echo "[5/9] Generating passwords..."
MARIADB_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9!@#%^&*()-_+=' | head -c 32)
PHPIPAM_DB_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
LIBRENMS_DB_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
GRAFANA_DB_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
GRAFANA_ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
LIBRENMS_ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
echo "  All passwords generated"

echo "[6/9] Creating configuration files..."

# --- MariaDB ---
cat > "$BASE_DIR/mariadb/.env" <<EOF
MARIADB_ROOT_PASSWORD=$MARIADB_ROOT_PASSWORD
MARIADB_DATABASE=default
EOF
echo "$MARIADB_ROOT_PASSWORD" > "$BASE_DIR/mariadb/password.txt"

cat > "$BASE_DIR/mariadb/docker-compose.yml" <<'COMPOSE'
services:
  mariadb:
    image: mariadb:11
    container_name: mariadb
    restart: unless-stopped
    networks:
      database_net:
        ipv4_address: 172.16.20.2
    volumes:
      - ./data:/var/lib/mysql
    env_file: .env

networks:
  database_net:
    external: true
COMPOSE

# --- Nginx ---
cat > "$BASE_DIR/nginx/docker-compose.yml" <<'COMPOSE'
services:
  nginx:
    image: nginx:stable-alpine
    container_name: nginx
    restart: unless-stopped
    networks:
      proxy_net:
        ipv4_address: 172.16.10.2
    ports:
      - "80:80"
      - "443:443"
      - "9443:9443"
    volumes:
      - ./config.d:/etc/nginx/conf.d
      - ./html:/usr/share/nginx/html
      - ./ssl:/etc/nginx/ssl

networks:
  proxy_net:
    external: true
COMPOSE

cat > "$BASE_DIR/nginx/config.d/default.conf" <<'NGINX'
server {
    listen 443 ssl;
    server_name _;

    ssl_certificate /etc/nginx/ssl/nginx.crt;
    ssl_certificate_key /etc/nginx/ssl/nginx.key;

    location /portainer/ {
        rewrite ^/portainer(/.*)$ $1 break;
        proxy_pass https://172.16.10.250:9443;
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
    }

    location /ipam/ {
        proxy_pass http://172.16.10.11:80/ipam/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
    }

    location /grafana/ {
        proxy_pass http://172.16.10.13:3000/grafana/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

}

server {
    listen 9443 ssl;
    server_name _;

    ssl_certificate /etc/nginx/ssl/nginx.crt;
    ssl_certificate_key /etc/nginx/ssl/nginx.key;

    location / {
        proxy_pass http://172.16.10.21:8000;
        proxy_http_version 1.1;
        proxy_set_header Host localhost:9443;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port $server_port;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header Accept-Encoding "";
        gzip off;
        proxy_redirect http://localhost:9443/ https://$host:9443/;
        proxy_redirect http://localhost:9443 https://$host:9443;
        sub_filter_once off;
        sub_filter 'http://localhost:9443/' 'https://$host:9443/';
        sub_filter 'http://localhost:9443' 'https://$host:9443';
        sub_filter 'https://localhost:9443/' 'https://$host:9443/';
        sub_filter 'https://localhost:9443' 'https://$host:9443';
    }
}

server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}
NGINX

# --- Portainer ---
cat > "$BASE_DIR/portainer/docker-compose.yml" <<'COMPOSE'
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    networks:
      proxy_net:
        ipv4_address: 172.16.10.250
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./data:/data
    command: --base-url /portainer

networks:
  proxy_net:
    external: true
COMPOSE

# --- phpIPAM ---
cat > "$BASE_DIR/phpipam/.env" <<EOF
IPAM_DATABASE_HOST=172.16.20.2
IPAM_DATABASE_PORT=3306
IPAM_DATABASE_USER=phpipam
IPAM_DATABASE_PASS=$PHPIPAM_DB_PASSWORD
IPAM_DATABASE_NAME=phpipam
IPAM_TRUST_X_FORWARDED=true
# IPAM_DISABLE_INSTALLER=true  # uncomment after installation completes
EOF
echo "$PHPIPAM_DB_PASSWORD" > "$BASE_DIR/phpipam/password_db.txt"

cat > "$BASE_DIR/phpipam/docker-compose.yml" <<'COMPOSE'
services:
  phpipam:
    image: phpipam/phpipam-www:latest
    container_name: phpipam
    restart: unless-stopped
    networks:
      proxy_net:
        ipv4_address: 172.16.10.11
      database_net:
        ipv4_address: 172.16.20.11
    volumes:
      - ./data:/app/data
    environment:
      IPAM_BASE: /ipam/
      TZ: Asia/Taipei
    env_file: .env

  phpipam-cron:
    image: phpipam/phpipam-cron:latest
    container_name: phpipam-cron
    restart: unless-stopped
    networks:
      proxy_net:
        ipv4_address: 172.16.10.12
      database_net:
        ipv4_address: 172.16.20.12
    cap_add:
      - NET_ADMIN
      - NET_RAW
    environment:
      SCAN_INTERVAL: 15m
      TZ: Asia/Taipei
    env_file: .env

networks:
  proxy_net:
    external: true
  database_net:
    external: true
COMPOSE

# --- LibreNMS ---
cat > "$BASE_DIR/librenms/.env" <<EOF
DB_HOST=172.16.20.2
DB_PORT=3306
DB_NAME=librenms
DB_USER=librenms
DB_PASSWORD=$LIBRENMS_DB_PASSWORD
LIBRENMS_BASE_URL=https://${HOST}:9443
TZ=UTC
EOF
echo "$LIBRENMS_DB_PASSWORD" > "$BASE_DIR/librenms/password_db.txt"
cat > "$BASE_DIR/librenms/admin_credentials.txt" <<EOF
Username: admin
Password: $LIBRENMS_ADMIN_PASSWORD
EOF

cat > "$BASE_DIR/librenms/docker-compose.yml" <<'COMPOSE'
services:
  librenms:
    image: librenms/librenms:latest
    container_name: librenms
    restart: unless-stopped
    networks:
      proxy_net:
        ipv4_address: 172.16.10.21
      database_net:
        ipv4_address: 172.16.20.21
    environment:
      APP_TRUSTED_PROXIES: '*'
      SESSION_SECURE_COOKIE: 'true'
    volumes:
      - ./data:/data
    env_file: .env

  librenms-snmptrapd:
    image: librenms/librenms:latest
    container_name: librenms-snmptrapd
    restart: unless-stopped
    networks:
      database_net:
        ipv4_address: 172.16.20.22
    ports:
      - "162:162/udp"
    cap_add:
      - NET_ADMIN
    environment:
      SIDECAR_SNMPTRAPD: '1'
      TZ: UTC
    env_file: .env

networks:
  proxy_net:
    external: true
  database_net:
    external: true
COMPOSE

# --- Grafana ---
cat > "$BASE_DIR/grafana/docker-compose.yml" <<COMPOSE
services:
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    networks:
      proxy_net:
        ipv4_address: 172.16.10.13
      database_net:
        ipv4_address: 172.16.20.13
    volumes:
      - ./data:/var/lib/grafana
    environment:
      GF_SERVER_ROOT_URL: https://${HOST}/grafana/
      GF_SERVER_SERVE_FROM_SUB_PATH: 'true'
      GF_DATABASE_TYPE: mysql
      GF_DATABASE_HOST: 172.16.20.2:3306
      GF_DATABASE_NAME: grafana
      GF_DATABASE_USER: grafana
      GF_DATABASE_PASSWORD: ${GRAFANA_DB_PASSWORD}
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD}
      TZ: Asia/Taipei

networks:
  proxy_net:
    external: true
  database_net:
    external: true
COMPOSE

cat > "$BASE_DIR/grafana/password_db.txt" <<EOF
Database user: grafana
DB password: $GRAFANA_DB_PASSWORD

Admin user: admin
Admin password: $GRAFANA_ADMIN_PASSWORD
EOF

echo "  All configuration files created"

echo "[7/9] Creating Docker networks..."
docker network inspect proxy_net >/dev/null 2>&1 || \
  docker network create --subnet=172.16.10.0/24 proxy_net
docker network inspect database_net >/dev/null 2>&1 || \
  docker network create --subnet=172.16.20.0/24 database_net
echo "  Networks ready"

echo "[8/9] Starting MariaDB and initializing databases..."

# Clean MariaDB data directory (files owned by container user UID 999)
echo "  Cleaning MariaDB data directory..."
docker run --rm -v "$BASE_DIR/mariadb/data:/data" alpine sh -c "rm -rf /data/* /data/.* 2>/dev/null" || true

$COMPOSE -f "$BASE_DIR/mariadb/docker-compose.yml" up -d

echo "  Waiting for MariaDB to be ready..."
for i in $(seq 1 30); do
  if docker exec mariadb mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "SELECT 1" &>/dev/null; then
    echo "  MariaDB is ready"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "ERROR: MariaDB did not become ready in time"
    exit 1
  fi
  sleep 2
done

docker exec -i mariadb mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" <<SQL
CREATE DATABASE IF NOT EXISTS phpipam CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'phpipam'@'172.16.20.11' IDENTIFIED BY '$PHPIPAM_DB_PASSWORD';
CREATE USER IF NOT EXISTS 'phpipam'@'172.16.20.12' IDENTIFIED BY '$PHPIPAM_DB_PASSWORD';
CREATE USER IF NOT EXISTS 'phpipam'@'localhost' IDENTIFIED BY '$PHPIPAM_DB_PASSWORD';
GRANT ALL PRIVILEGES ON *.* TO 'phpipam'@'172.16.20.11' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'phpipam'@'172.16.20.12' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'phpipam'@'localhost' WITH GRANT OPTION;

CREATE DATABASE IF NOT EXISTS librenms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'librenms'@'172.16.20.21' IDENTIFIED BY '$LIBRENMS_DB_PASSWORD';
GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'172.16.20.21';

CREATE DATABASE IF NOT EXISTS grafana CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'grafana'@'172.16.20.13' IDENTIFIED BY '$GRAFANA_DB_PASSWORD';
GRANT ALL PRIVILEGES ON grafana.* TO 'grafana'@'172.16.20.13';

FLUSH PRIVILEGES;
SQL
echo "  Databases and users created"

echo "[9/9] Setting permissions..."
chmod -R u+rwX "$BASE_DIR" 2>/dev/null || true
chmod +x "$BASE_DIR/bootstrap.sh"
chmod +x "$BASE_DIR/bootstrap-offline.sh"
echo "  Permissions set"

# Create start-all.sh (same as before, unchanged)
cat > "$BASE_DIR/start-all.sh" <<'SCRIPT'
#!/bin/bash
set -e

SCRIPT_DIR="$(dirname "$0")"

echo "Starting MariaDB..."
docker compose -f "$SCRIPT_DIR/mariadb/docker-compose.yml" up -d

echo "Starting Portainer..."
docker compose -f "$SCRIPT_DIR/portainer/docker-compose.yml" up -d

echo "Starting phpIPAM..."
docker compose -f "$SCRIPT_DIR/phpipam/docker-compose.yml" up -d

echo "Starting LibreNMS..."
docker compose -f "$SCRIPT_DIR/librenms/docker-compose.yml" up -d

echo "Starting Grafana..."
docker compose -f "$SCRIPT_DIR/grafana/docker-compose.yml" up -d

echo "Starting Nginx..."
docker compose -f "$SCRIPT_DIR/nginx/docker-compose.yml" up -d

echo "All containers started."
SCRIPT
chmod +x "$BASE_DIR/start-all.sh"
echo "  start-all.sh created"

echo ""
echo "============================================"
echo " Bootstrap Complete (Offline Mode)"
echo "============================================"
echo ""
echo "  All container images pre-loaded into Docker."
echo "  Containers can now be started:"
echo "    bash start-all.sh"
echo ""
echo "  First-time setup (web installers):"
echo "    Portainer : https://<host>/portainer/  (create admin user)"
echo "    phpIPAM   : https://<host>/ipam/       (web installer)"
echo "    LibreNMS  : https://<host>:9443        (web installer)"
echo "    Grafana   : https://<host>/grafana/    (login: admin / $GRAFANA_ADMIN_PASSWORD)"
echo ""
echo "  Passwords saved to respective service directories."
echo "  SSL certificate: $BASE_DIR/nginx/ssl/"
echo "  Frozen images cached at: $FROZEN_DIR/"
echo "  (delete that directory to force re-download)"
echo ""
