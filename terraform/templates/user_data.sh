#!/bin/bash
set -euo pipefail

# 1. Configurar 4GB de Swap para prevenir OOM durante builds
if [ ! -f /swapfile ]; then
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# 2. Esperar liberación de locks de apt/dpkg
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    sleep 5
done

# 3. Instalar dependencias
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg git openssl

# 4. Instalación de Docker
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm -f get-docker.sh
    systemctl enable --now docker
    usermod -aG docker ubuntu
fi

# 5. Obtener IP pública para configurar variables de entorno
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" http://169.254.169.254/latest/meta-data/public-ipv4)
APP_BASE_URL="http://${PUBLIC_IP}"

# 6. Clonar repositorio base oficial
rm -rf /opt/calcom-stack
git clone --depth 1 https://github.com/calcom/cal.com.git /opt/calcom-stack
cd /opt/calcom-stack

# 7. Crear microservicio del Agente de IA (WhatsApp + Bedrock)
mkdir -p agent

cat << 'EOF' > agent/Dockerfile
FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn[standard] boto3 redis httpx psycopg[binary]
COPY main.py /app/main.py
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

cat << 'EOF' > agent/main.py
import os
import hmac
import hashlib
import json
import boto3
import psycopg
from psycopg.rows import dict_row
import redis.asyncio as redis
from fastapi import FastAPI, Request, HTTPException, BackgroundTasks, Query

app = FastAPI()

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379")
CALCOM_INTERNAL_API = os.getenv("API_URL", "http://calcom-api:80")
WHATSAPP_VERIFY_TOKEN = os.getenv("WHATSAPP_VERIFY_TOKEN", "bedrock_haiku_token_2026")
WHATSAPP_APP_SECRET = os.getenv("WHATSAPP_APP_SECRET", "")
BEDROCK_MODEL_ID = "us.anthropic.claude-haiku-4-5-20251001-v1:0"

redis_client = redis.from_url(REDIS_URL, decode_responses=True)
bedrock = boto3.client("bedrock-runtime", region_name=os.getenv("AWS_REGION", "us-east-1"))

@app.get("/webhook/whatsapp")
async def verify_webhook(
    hub_mode: str = Query(None, alias="hub.mode"),
    hub_challenge: str = Query(None, alias="hub.challenge"),
    hub_verify_token: str = Query(None, alias="hub.verify_token"),
):
    if hub_mode == "subscribe" and hub_verify_token == WHATSAPP_VERIFY_TOKEN:
        return int(hub_challenge)
    raise HTTPException(status_code=403, detail="Token de verificación inválido")

@app.post("/webhook/whatsapp")
async def receive_whatsapp(request: Request, background_tasks: BackgroundTasks):
    raw_body = await request.body()
    if WHATSAPP_APP_SECRET:
        signature = request.headers.get("X-Hub-Signature-256", "")
        expected = "sha256=" + hmac.new(WHATSAPP_APP_SECRET.encode(), raw_body, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(signature, expected):
            raise HTTPException(status_code=401, detail="Firma inválida")

    payload = json.loads(raw_body)
    background_tasks.add_task(process_whatsapp_event, payload)
    return {"status": "accepted"}

async def process_whatsapp_event(payload: dict):
    try:
        value = payload["entry"][0]["changes"][0]["value"]
        if "messages" not in value:
            return
        phone_number_id = value["metadata"]["phone_number_id"]
        msg = value["messages"][0]
        user_phone = msg["from"]
        text = msg.get("text", {}).get("body", "")
        if not text:
            return
    except (KeyError, IndexError):
        return

    # 1. Buscar las credenciales del negocio en PostgreSQL
    DATABASE_URL = os.getenv("DATABASE_DIRECT_URL")
    try:
        with psycopg.connect(DATABASE_URL) as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                cur.execute(
                    "SELECT calcom_api_key, event_type_id, timezone, business_name FROM agent_tenants WHERE phone_number_id = %s",
                    (phone_number_id,)
                )
                tenant = cur.fetchone()
                if not tenant:
                    print(f"Negocio no registrado: {phone_number_id}")
                    return # Ignorar mensajes hacia números no registrados
    except Exception as e:
        print(f"Error de base de datos: {e}")
        return

    # 2. Control de concurrencia por usuario (Lock en Redis)
    lock_key = f"lock:wa:{phone_number_id}:{user_phone}"
    async with redis_client.lock(lock_key, timeout=30, blocking_timeout=10):
        history_key = f"chat:wa:{phone_number_id}:{user_phone}"
        raw_history = await redis_client.get(history_key)
        messages = json.loads(raw_history) if raw_history else []
        messages.append({"role": "user", "content": [{"text": text}]})

        # 3. Invocar Bedrock inyectando el contexto específico del negocio
        system_prompt = (
            f"Eres el asistente virtual de {tenant['business_name']}. "
            "Tu objetivo es agendar citas para los clientes. Sé amable, conciso y directo."
        )

        response = bedrock.converse(
            modelId=BEDROCK_MODEL_ID,
            system=[{"text": system_prompt}],
            messages=messages[-10:],
            # Aquí iría el toolConfig con las funciones consultar_horarios y agendar_cita 
            # usando tenant['calcom_api_key'] y tenant['event_type_id']
            inferenceConfig={"maxTokens": 400, "temperature": 0.2}
        )

        output_message = response["output"]["message"]
        messages.append(output_message)
        await redis_client.set(history_key, json.dumps(messages[-10:]), ex=86400)
EOF

# 8. Generar secretos criptográficos y archivo .env
SECRET_NEXTAUTH=$(openssl rand -base64 32)
SECRET_CALENDSO=$(openssl rand -base64 24)
SECRET_JWT=$(openssl rand -hex 32)
DB_PASS=$(openssl rand -hex 16)

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

# 9. Crear configuración de Nginx (Web + API v2 + Webhook)
mkdir -p nginx/conf.d
cat <<'EOF' > nginx/conf.d/default.conf
server {
    listen 80 default_server;
    server_name _;

    client_max_body_size 20M;
    resolver 127.0.0.11 valid=10s ipv6=off;

    # Webhook de WhatsApp hacia el contenedor del Agente IA
    location /webhook/whatsapp {
        set $agent_upstream whatsapp-agent;
        proxy_pass http://$agent_upstream:8000/webhook/whatsapp;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Endpoint API v2 interno
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

# 10. Generar docker-compose.yml con todos los servicios
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

  whatsapp-agent:
    container_name: whatsapp-agent
    build:
      context: ./agent
      dockerfile: Dockerfile
    restart: always
    networks:
      - stack
    env_file: .env
    environment:
      - AWS_REGION=us-east-1
      - REDIS_URL=redis://redis:6379
      - API_URL=http://calcom-api:80
    depends_on:
      redis:
        condition: service_started
      calcom-api:
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
      - whatsapp-agent
    networks:
      - stack
EOF

# 11. Levantar base de datos y esperar inicialización
export DOCKER_BUILDKIT=1
docker compose up -d database redis

until docker compose exec -T database pg_isready -U calcom_user -d calendso >/dev/null 2>&1; do
    sleep 3
done

# 11.5 Crear tabla de enrutamiento para el Agente IA
docker compose exec -T database psql -U calcom_user -d calendso -c "
CREATE TABLE IF NOT EXISTS agent_tenants (
    id SERIAL PRIMARY KEY,
    phone_number_id VARCHAR(50) UNIQUE NOT NULL,
    calcom_api_key VARCHAR(255) NOT NULL,
    event_type_id INT NOT NULL,
    timezone VARCHAR(50) DEFAULT 'America/Monterrey',
    business_name VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
"

# 12. Levantar stack completo (compila la API y el Agente)
docker compose up -d --build

until [ "$(docker inspect -f '{{.State.Running}}' calcom 2>/dev/null)" = "true" ]; do
    sleep 3
done

# 13. Ejecutar migraciones de base de datos
docker compose exec -T calcom yarn workspace @calcom/prisma db-deploy
docker compose restart calcom calcom-api whatsapp-agent nginx