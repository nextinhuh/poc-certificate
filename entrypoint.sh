#!/bin/sh
set -eu

# STEPPATH persiste no volume EFS (mount em /home/step). Se ca.json ja existe,
# a CA ja foi inicializada em algum boot anterior - so sobe o servidor.
STEPPATH="${STEPPATH:-/home/step}"
export STEPPATH

CA_NAME="${CA_NAME:-poc-mtls step-ca (teste pessoal, NAO usar em producao)}"
CA_DNS="${CA_DNS:-localhost}"
CA_ADDRESS="${CA_ADDRESS:-:9000}"
KEYCLOAK_ISSUER="${KEYCLOAK_ISSUER:-http://keycloak.poc-mtls.local:8080/realms/poc-terminal}"
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-step-ca-oidc}"
ROOT_CA_BUCKET="${ROOT_CA_BUCKET:?ROOT_CA_BUCKET env var e obrigatoria}"

if [ ! -f "${STEPPATH}/config/ca.json" ]; then
  echo "==> Primeira execucao: inicializando a CA (step ca init)"

  # OIDC_CLIENT_SECRET vem via SSM (injetado como env var "secret" na task
  # definition do ECS, nao fica hardcoded na imagem).
  : "${OIDC_CLIENT_SECRET:?OIDC_CLIENT_SECRET env var e obrigatoria}"

  mkdir -p "${STEPPATH}/secrets"
  head -c 32 /dev/urandom | base64 > "${STEPPATH}/secrets/password"

  step ca init \
    --deployment-type standalone \
    --name "${CA_NAME}" \
    --dns "${CA_DNS}" \
    --address "${CA_ADDRESS}" \
    --provisioner "poc-mtls-admin" \
    --password-file "${STEPPATH}/secrets/password" \
    --no-db

  # Provisioner OIDC: valida o id_token emitido pelo Keycloak (client
  # step-ca-oidc, scope openid) antes de assinar qualquer CSR. TTL curto
  # (5 min) herdado do ADR original da Barte.
  step ca provisioner add poc-terminal-oidc \
    --type OIDC \
    --client-id "${OIDC_CLIENT_ID}" \
    --client-secret "${OIDC_CLIENT_SECRET}" \
    --configuration-endpoint "${KEYCLOAK_ISSUER}/.well-known/openid-configuration" \
    --x509-min-dur 1m --x509-default-dur 5m --x509-max-dur 5m

  echo "==> Publicando root_ca.crt em s3://${ROOT_CA_BUCKET}/root_ca.crt"
  aws s3 cp "${STEPPATH}/certs/root_ca.crt" "s3://${ROOT_CA_BUCKET}/root_ca.crt"
else
  echo "==> ca.json ja existe no volume EFS, pulando bootstrap"
fi

echo "==> Subindo step-ca em ${CA_ADDRESS}"
exec step-ca "${STEPPATH}/config/ca.json" --password-file "${STEPPATH}/secrets/password"
