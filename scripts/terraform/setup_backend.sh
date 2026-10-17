#!/usr/bin/env bash
set -euo pipefail

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="${AWS_REGION:-us-east-1}"
BUCKET_NAME="calcom-infra-tfstate-${ACCOUNT_ID}"
DYNAMO_TABLE="calcom-infra-tfstate-lock"
TF_DIR="terraform"

echo "[*] Verificando/Creando Bucket S3: ${BUCKET_NAME} en ${AWS_REGION}..."
if ! aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
    if [ "$AWS_REGION" == "us-east-1" ]; then
        aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION"
    else
        aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" --create-bucket-configuration LocationConstraint="$AWS_REGION"
    fi
    aws s3api put-bucket-versioning --bucket "$BUCKET_NAME" --versioning-configuration Status=Enabled
    aws s3api put-bucket-encryption --bucket "$BUCKET_NAME" --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
else
    echo "[OK] El bucket S3 ya existe."
fi

echo "[*] Verificando/Creando Tabla DynamoDB: ${DYNAMO_TABLE}..."
if ! aws dynamodb describe-table --table-name "$DYNAMO_TABLE" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws dynamodb create-table \
        --table-name "$DYNAMO_TABLE" \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region "$AWS_REGION" >/dev/null
    aws dynamodb wait table-exists --table-name "$DYNAMO_TABLE" --region "$AWS_REGION"
else
    echo "[OK] La tabla DynamoDB ya existe."
fi

echo "[*] Generando backend.tf en el directorio ${TF_DIR}..."
cat <<EOF > "${TF_DIR}/backend.tf"
terraform {
  backend "s3" {
    bucket         = "${BUCKET_NAME}"
    key            = "prod/terraform.tfstate"
    region         = "${AWS_REGION}"
    dynamodb_table = "${DYNAMO_TABLE}"
    encrypt        = true
  }
}
EOF
echo "[OK] Backend remoto configurado exitosamente."