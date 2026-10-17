#!/bin/bash
set -euo pipefail

# 1. Configurar 4GB de Swap para prevenir OOM durante builds de Docker/Prisma
if [ ! -f /swapfile ]; then
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# 2. Esperar liberación de locks de apt/dpkg por cloud-init
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    sleep 5
done

# 3. Instalar dependencias básicas
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg git openssl

# 4. Instalación de Docker oficial
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm -f get-docker.sh
    systemctl enable --now docker
    usermod -aG docker ubuntu
fi

# 5. Obtener IP pública vía IMDSv2 para configurar NEXTAUTH_URL / WEBAPP_URL
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" http://169.254.169.254/latest/meta-data/public-ipv4)
APP_BASE_URL="http://${PUBLIC_IP}"

# 6. Clonar repositorio base (necesario para contexto de build de calcom-api y prisma)
rm -rf /opt/calcom-stack
git clone --depth 1 https://github.com/calcom/cal.diy.git /opt/calcom-stack
cd /opt/calcom-stack

# 7. Generar secretos criptográficos
SECRET_NEXTAUTH=$(openssl rand -base64 32)
SECRET_CALENDSO=$(openssl rand -base64 24)
SECRET_JWT=$(openssl rand -hex 32)
DB_PASS=$(openssl rand -hex 16)

# 8. Crear archivo .env de producción
cat <<EOF > .env
NODE_ENV="production"
NEXTAUTH_SECRET="${SECRET_NEXTAUTH}"
CALENDSO_ENCRYPTION_KEY="${SECRET_CALENDSO}"
JWT_SECRET="${SECRET_JWT}"
POSTGRES_USER="calcom_user"
POSTGRES_PASSWORD="${DB_PASS}"
POSTGRES_DB="calendso"
DATABASE_HOST="database:5432"
DATABASE_URL="postgresql://calcom_user:${DB_PASS}@database:5432/calendso"
DATABASE_DIRECT_URL="postgresql://calcom_user:${DB_PASS}@database:5432/calendso"
NEXT_PUBLIC_WEBAPP_URL="${APP_BASE_URL}"
NEXTAUTH_URL="${APP_BASE_URL}/api/auth"
NEXT_PUBLIC_API_V2_URL="${APP_BASE_URL}/api/v2"
API_PORT=80
API_URL="http://calcom-api:80"
REDIS_URL="redis://redis:6379"
CALCOM_TELEMETRY_DISABLED=1
EOF

chmod 600 .env

# 9. Crear configuración de Nginx
mkdir -p nginx/conf.d
cat <<'EOF' > nginx/conf.d/default.conf
server {
    listen 80 default_server;
    server_name _;

    client_max_body_size 20M;
    resolver 127.0.0.11 valid=10s ipv6=off;

    # Endpoint API v2 para Agente IA (AWS Bedrock / WhatsApp)
    location /api/v2/ {
        set $api_upstream calcom-api;
        proxy_pass http://$api_upstream:80/v2/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 90s;
        proxy_read_timeout 90s;
    }

    # Frontend Web de Cal.com
    location / {
        set $web_upstream calcom;
        proxy_pass http://$web_upstream:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

# 10. Generar docker-compose.yml declarativo (sin mutaciones frágiles con sed)
cat <<'EOF' > docker-compose.yml
volumes:
  database-data:
  redis-data:
  certs:

networks:
  stack:

services:
  database:
    container_name: database
    image: postgres:16-alpine
    restart: always
    volumes:
      - database-data:/var/lib/postgresql/data/
    env_file: .env
    networks:
      - stack
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 10

  redis:
    container_name: redis
    image: redis:7-alpine
    restart: always
    volumes:
      - redis-data:/data
    networks:
      - stack

  calcom:
    image: calcom/cal.com:latest
    container_name: calcom
    restart: always
    networks:
      - stack
    env_file: .env
    environment:
      - DATABASE_URL=${DATABASE_URL}
      - DATABASE_DIRECT_URL=${DATABASE_DIRECT_URL}
      - NEXT_PUBLIC_WEBAPP_URL=${NEXT_PUBLIC_WEBAPP_URL}
    depends_on:
      database:
        condition: service_healthy
      redis:
        condition: service_started

  calcom-api:
    container_name: calcom-api
    build:
      context: .
      dockerfile: apps/api/v2/Dockerfile
      args:
        DATABASE_URL: ${DATABASE_URL}
        DATABASE_DIRECT_URL: ${DATABASE_DIRECT_URL}
    restart: always
    networks:
      - stack
    env_file: .env
    environment:
      - DATABASE_URL=${DATABASE_URL}
      - DATABASE_DIRECT_URL=${DATABASE_DIRECT_URL}
    depends_on:
      database:
        condition: service_healthy
      redis:
        condition: service_started

  nginx:
    image: nginx:alpine
    container_name: calcom-nginx
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - certs:/etc/letsencrypt
    depends_on:
      - calcom
      - calcom-api
    networks:
      - stack
EOF

# 11. Levantar base de datos primero y esperar healthcheck
export DOCKER_BUILDKIT=1
docker compose up -d database redis

until docker compose exec -T database pg_isready -U calcom_user -d calendso >/dev/null 2>&1; do
    sleep 3
done

# 12. Levantar stack completo y ejecutar migraciones de producción
docker compose up -d --build

# Esperar a que el contenedor calcom esté en ejecución para lanzar Prisma
until [ "$(docker inspect -f '{{.State.Running}}' calcom 2>/dev/null)" = "true" ]; do
    sleep 3
done

docker compose exec -T calcom yarn workspace @calcom/prisma db-deploy
docker compose restart calcom calcom-api nginx