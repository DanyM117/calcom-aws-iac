#!/usr/bin/env bash
set -euo pipefail

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="${AWS_REGION:-us-east-1}"
BUCKET_NAME="calcom-infra-tfstate-${ACCOUNT_ID}"
DYNAMO_TABLE="calcom-infra-tfstate-lock"
TF_DIR="terraform"

echo "[*] Purgando versiones y delete markers en S3: ${BUCKET_NAME}..."
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  VERSIONS=$(aws s3api list-object-versions --bucket "$BUCKET_NAME" --query='{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json)
  if [ "$VERSIONS" != '{"Objects":null}' ] && [ -n "$VERSIONS" ]; then
    aws s3api delete-objects --bucket "$BUCKET_NAME" --delete "$VERSIONS" >/dev/null 2>&1 || true
  fi
  MARKERS=$(aws s3api list-object-versions --bucket "$BUCKET_NAME" --query='{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json)
  if [ "$MARKERS" != '{"Objects":null}' ] && [ -n "$MARKERS" ]; then
    aws s3api delete-objects --bucket "$BUCKET_NAME" --delete "$MARKERS" >/dev/null 2>&1 || true
  fi
  echo "[*] Eliminando bucket S3..."
  aws s3 rb "s3://${BUCKET_NAME}" --force --region "$AWS_REGION"
  echo "[OK] Bucket S3 eliminado."
else
  echo "[*] Bucket S3 no existe o ya fue eliminado."
fi

echo "[*] Eliminando tabla de bloqueos DynamoDB: ${DYNAMO_TABLE}..."
if aws dynamodb describe-table --table-name "$DYNAMO_TABLE" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws dynamodb delete-table --table-name "$DYNAMO_TABLE" --region "$AWS_REGION" >/dev/null
  echo "[OK] Tabla DynamoDB eliminada."
else
  echo "[*] Tabla DynamoDB no existe."
fi

echo "[*] Limpiando estado local..."
rm -rf "${TF_DIR}/.terraform" "${TF_DIR}/.terraform.lock.hcl" "${TF_DIR}/backend.tf" "${TF_DIR}/terraform.tfstate*"
echo "[OK] Teardown completo del backend ejecutado exitosamente."