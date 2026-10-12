#!/bin/bash
set -ex

# 1. Actualizar paquetes e instalar dependencias básicas
apt-get update -y
apt-get install -y ca-certificates curl gnupg git openssl

# 2. Instalar Docker y Docker Compose oficial
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://docker.com | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://docker.com $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker

# 3. Clonar repositorio de Cal.diy
cd /opt
git clone https://github.com calcom-stack
cd calcom-stack

# 4. Generar claves seguras
SECRET_NEXTAUTH=$(openssl rand -base64 32)
SECRET_CALENDSO=$(openssl rand -base64 24)
SECRET_JWT=$(openssl rand -hex 32)

# 5. Crear archivo .env
cat <<EOF > .env
NODE_ENV="production"
NEXTAUTH_SECRET="$SECRET_NEXTAUTH"
CALENDSO_ENCRYPTION_KEY="$SECRET_CALENDSO"
JWT_SECRET="$SECRET_JWT"

POSTGRES_USER="unicorn_user"
POSTGRES_PASSWORD="magical_password"
POSTGRES_DB="calendso"
DATABASE_HOST="database"
DATABASE_URL="postgresql://unicorn_user:magical_password@database:5432/calendso"
DATABASE_DIRECT_URL="postgresql://unicorn_user:magical_password@database:5432/calendso"

NEXT_PUBLIC_WEBAPP_URL="http://localhost"
NEXTAUTH_URL="http://localhost/api/auth"

ORGANIZATIONS_ENABLED=true
ORGANIZATIONS_AUTOSURFACE_ENABLED=true

API_PORT=80
API_URL="http://calcom-api:80"
REDIS_URL="redis://redis:6379"
STRIPE_API_KEY="sk_test_placeholder"
EOF

# 6. Parchear docker-compose.yml (Usar imagen calcom/cal.com)
sed -i 's|image: calcom.docker.scarf.sh/calcom/cal.diy:latest|image: calcom/cal.com:latest|g' docker-compose.yml

# 7. Crear configuración de Nginx dockerizado
mkdir -p nginx/conf.d
cat <<'EOF' > nginx/conf.d/default.conf
server {
    listen 80 default_server;
    server_name _;
    client_max_body_size 20M;

    # API v2 para AWS Bedrock y WhatsApp
    location /api/v2/ {
        proxy_pass http://calcom-api:80/v2/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Frontend Web
    location / {
        proxy_pass http://calcom:3000;
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

# 8. Agregar servicio Nginx a docker-compose.yml si no existe
cat <<'EOF' >> docker-compose.yml

  nginx:
    image: nginx:alpine
    container_name: calcom-nginx
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
    depends_on:
      - calcom
      - calcom-api
    networks:
      - stack
EOF

# 9. Levantar los contenedores
export DOCKER_BUILDKIT=1
docker compose up -d

# 10. Esperar a que la base de datos esté lista y aplicar migraciones
sleep 25
docker compose exec -T -e DATABASE_URL="postgresql://unicorn_user:magical_password@database:5432/calendso" -e DATABASE_DIRECT_URL="postgresql://unicorn_user:magical_password@database:5432/calendso" calcom yarn workspace @calcom/prisma db-deploy
docker compose exec -T -e DATABASE_URL="postgresql://unicorn_user:magical_password@database:5432/calendso" -e DATABASE_DIRECT_URL="postgresql://unicorn_user:magical_password@database:5432/calendso" calcom yarn workspace @calcom/prisma db-seed

docker compose restart calcom calcom-api nginx
