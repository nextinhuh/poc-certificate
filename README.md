# poc-certificate

## 1. Contexto geral do teste

Esta é uma POC pessoal (conta AWS pessoal do autor, fora da empresa) para validar, antes de propor formalmente para a empresa Barte, se o desenho de autenticação de terminais via **step-ca + Keycloak + ALB com listener mTLS** funciona de ponta a ponta:

1. Um cliente (terminal POS) pede um token ao backend, informando o serial number do hardware — o backend loga como esse terminal no Keycloak (Direct Access Grant) e devolve um **ID Token OIDC** de verdade.
2. O cliente gera um CSR local e manda `{csr, ott: <id_token>}` para **este serviço** (step-ca), que valida o token contra o Keycloak (provisioner OIDC) e, se válido, assina o CSR e devolve um certificado x509.
3. O cliente usa esse certificado para chamar um endpoint do backend só acessível através de um listener **mTLS** do ALB (trust store = CA raiz gerada por este step-ca).

Simplificado em relação ao plano corporativo real: sem domínio próprio, sem ALB dedicado/ACM (o endpoint `/1.0/sign` é só um path HTTP no ALB compartilhado — o certificado que importa aqui é o que este serviço emite, não o do listener público), sem revogação/CRL, sem HA. 3 repositórios independentes: `poc-keycloak` (também dono da infraestrutura compartilhada — ALB, cluster ECS, SGs, Cloud Map), **`poc-certificate`** (este), `poc-backend`.

## 2. Papel deste serviço (poc-certificate)

É a Autoridade Certificadora da POC. Na primeira execução, gera sua própria CA raiz/intermediária localmente (`step ca init`, sem interação humana) e configura um **provisioner OIDC** apontando para o realm `poc-terminal` do Keycloak — esse provisioner é quem valida o token recebido antes de assinar qualquer CSR. O estado (chaves da CA, banco de provisioners) persiste num volume EFS (access point restrito), para sobreviver a redeploys.

**O token precisa ser um ID Token de verdade, endereçado a este provisioner — e isso restringe qual grant o backend pode usar.** O provisioner OIDC do step-ca valida um **ID Token OIDC (JWT assinado pelo Keycloak)**, não um `access_token` opaco genérico, e exige que o campo `aud`/`azp` do token contenha o `--client-id` configurado aqui (`step-ca-oidc`).

Isso já nos levou a um beco sem saída real nesta POC: a primeira tentativa do `poc-backend` usava **OAuth2 Token Exchange** (RFC 8693) pra emitir esse token, impersonando o terminal com a identidade do próprio `poc-backend`. Validamos, testando ao vivo contra o Keycloak, que esse grant **nunca devolve `id_token`** — não importa `scope=openid`, `audience` ou `requested_token_type`, é uma limitação do mecanismo (Token Exchange v1 do Keycloak foi feito pra impersonação access-token-a-access-token, não pra emitir credenciais OIDC completas). A solução: o `poc-backend` usa **Direct Access Grant** (`grant_type=password`) **contra o próprio client `step-ca-oidc`** — é o único grant que realmente autentica um "usuário" e por isso emite `id_token` com a audiência certa. Ver README do `poc-backend` para os detalhes (senha derivada por terminal) e do `poc-keycloak` seção 8 (Direct Access Grants precisa estar habilitado nesse client).

**Como o step-ca valida esse token, na prática (sem chamar o Keycloak a cada requisição):**
1. Na primeira vez (ou quando o cache expira), busca o **JWKS** (chaves públicas do Keycloak) através do `--configuration-endpoint` configurado — e guarda em cache.
2. Confere a **assinatura** do JWT recebido contra essa chave pública — prova que o token foi mesmo emitido pelo Keycloak e não foi adulterado.
3. Confere os campos do payload: `iss` (emissor) bate com o `--configuration-endpoint`; `aud`/`azp` contém o `--client-id` (`step-ca-oidc`); `exp` (validade) ainda não passou.
4. Se tudo bate, confia na identidade do token (`sub`/`preferred_username` = serial number) e segue pra assinar o CSR.

Nenhuma chamada de rede pro Keycloak acontece nesse momento — é tudo verificação criptográfica local, usando chaves já em cache.

Expõe `POST /1.0/sign` (nativo do step-ca) e `GET /health`, como paths no ALB compartilhado (listener 80, HTTP puro — não tem TLS de borda porque não há domínio, e isso não afeta o que está sendo validado). Internamente, o step-ca sempre serve HTTPS (com certificado próprio, autoassinado) na porta 9000 — o ALB usa um target group `HTTPS` para esse backend, mas não valida esse certificado (comportamento padrão do ALB para target groups HTTPS), então funciona sem nenhum certificado "de confiança pública" no meio.

## 3. Contrato entre serviços (fonte de verdade — igual nos 3 READMEs)

| Item | Valor exato |
|---|---|
| Realm Keycloak | `poc-terminal` |
| Client backend | `poc-backend` (confidential, `serviceAccountsEnabled=true`, `directAccessGrantsEnabled=true`) |
| Client do provisioner do step-ca | `step-ca-oidc` (confidential, `directAccessGrantsEnabled=true` — o `poc-backend` loga como esse client pra emitir o `id_token` do terminal) |
| URL interna do Keycloak (via Cloud Map) | `http://keycloak.poc-mtls.local:8080` |
| Admin REST API (criar usuário) | `POST http://keycloak.poc-mtls.local:8080/admin/realms/poc-terminal/users` |
| Token endpoint | `POST http://keycloak.poc-mtls.local:8080/realms/poc-terminal/protocol/openid-connect/token` |
| SSM: secret do client `poc-backend` | `/poc-mtls/keycloak/backend-client-secret` (SecureString) |
| SSM: secret do client `step-ca-oidc` | `/poc-mtls/keycloak/stepca-client-secret` (SecureString) |
| Bucket S3 da CA raiz | criado por **este repositório** (`poc-certificate`), objeto `root_ca.crt`; nome exposto no output Terraform `root_ca_bucket_name` |
| ALB (nome/tag) | `data "aws_lb" "shared"` por tag `Name=poc-mtls-shared-alb` |
| Cluster ECS | `data "aws_ecs_cluster" "this"` — nome fixo `poc-mtls-ECS` |
| Namespace Cloud Map | `poc-mtls.local` |
| Porta/health-check step-ca | `9000` (HTTPS interno), `GET /health` |
| Porta backend | `8080`; paths `/auth/token` (POST), `/public/ping` (GET), `/consumer/ping` (GET) |
| Path público do step-ca no ALB | `/1.0/sign` (POST), `/health` (GET) — listener 80 |
| Path bloqueado no listener 80 | `/consumer/*` → fixed-response 404 |
| Path liberado só no listener 8443 (mTLS) | `/consumer/*` → target group backend |
| TTL do certificado emitido | 5 minutos (`x509-default-dur` / `x509-max-dur` do provisioner) |

## 4. O que precisa ser implementado aqui

- `Dockerfile`: `FROM smallstep/step-ca:latest` + `aws-cli`/`curl`/`jq`, copia `entrypoint.sh`.
- `entrypoint.sh`: se `${STEPPATH}/config/ca.json` não existir (primeira execução no volume EFS), roda `step ca init` não-interativo (`--deployment-type standalone --no-db`), adiciona o provisioner `poc-terminal-oidc` (`step ca provisioner add ... --type OIDC --client-id step-ca-oidc --client-secret $OIDC_CLIENT_SECRET --configuration-endpoint <issuer>/.well-known/openid-configuration --x509-default-dur 5m --x509-max-dur 5m`), e publica `certs/root_ca.crt` no bucket S3. Se `ca.json` já existir, pula direto pra subir o servidor (`exec step-ca ...`).
- `terraform/s3.tf`: bucket dedicado (`force_destroy = true`, bloqueado a acesso público) para o `root_ca.crt`.
- `terraform/efs.tf`: file system + access point restrito a `/home/step` (certs + banco de provisioners do CA), mount targets nas subnets públicas, SG liberando NFS (2049) só das tasks.
- `terraform/ecs.tf`: task definition com o volume EFS montado em `/home/step`, variáveis de ambiente (`KEYCLOAK_ISSUER`, `OIDC_CLIENT_ID`, `ROOT_CA_BUCKET`) e o secret `OIDC_CLIENT_SECRET` vindo do SSM (`data.aws_ssm_parameter.stepca_client_secret`, criado pelo `poc-keycloak` — **precisa rodar depois do `poc-keycloak`**), target group HTTPS (porta 9000, health check `/health`), regra de listener no `data.aws_lb_listener.http` do `poc-keycloak` com `path_pattern = ["/1.0/sign", "/health"]`.

## 5. Variáveis de ambiente / SSM

- Consome: `/poc-mtls/keycloak/stepca-client-secret` (SSM SecureString, escrito pelo `poc-keycloak`).
- Produz: bucket S3 com `root_ca.crt` (nome via output `root_ca_bucket_name`, usado manualmente na 2ª leva do `poc-keycloak` para `enable_mtls_listener=true` + `root_ca_bucket_name=<esse nome>`).
- Env vars do container: `STEPPATH=/home/step`, `CA_DNS=localhost`, `CA_ADDRESS=:9000`, `KEYCLOAK_ISSUER=http://keycloak.poc-mtls.local:8080/realms/poc-terminal`, `OIDC_CLIENT_ID=step-ca-oidc`, `ROOT_CA_BUCKET=<bucket criado por este repo>`.

## 6. Workflow de CI/CD (`.github/workflows/deploy.yml`)

Em push na `main`: assume a IAM role via OIDC → cria o repositório ECR se não existir → build/tag/push da imagem → `terraform init` (key `step-ca/terraform.tfstate`) → `terraform apply -auto-approve` (`image_tag`) → imprime `root_ca_bucket_name` no log (para o usuário colar manualmente no `workflow_dispatch` do `poc-keycloak` na 2ª leva).

**Pré-requisito de ordem**: este repositório só funciona depois que o `poc-keycloak` já rodou pelo menos uma vez (precisa que o SSM parameter do client secret já exista).

## 7. Como testar isoladamente

```bash
curl -i http://<shared-alb-dns>/health
# esperado: 200

# smoke test do provisioner OIDC (sem token valido, so pra confirmar que o
# endpoint rejeita corretamente):
curl -X POST http://<shared-alb-dns>/1.0/sign \
  -H "Content-Type: application/json" \
  -d '{"csr":"...","ott":"token-invalido-de-proposito"}'
# esperado: 4xx (token invalido rejeitado, nao 5xx de erro interno)
```

**Teste de ponta a ponta (validado nesta POC)** — pega um token real do `poc-backend`, gera um CSR local e assina:

```bash
ALB_DNS="<shared-alb-dns>"
SERIAL="pos-teste-001"

# 1. token real do terminal (ver README do poc-backend)
TOKEN=$(curl -s -X POST "http://${ALB_DNS}/auth/token" \
  -H "Content-Type: application/json" \
  -d "{\"serialNumber\": \"${SERIAL}\"}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['accessToken'])")

# 2. gera chave + CSR local
openssl req -newkey rsa:2048 -nodes -keyout terminal.key -out terminal.csr -subj "/CN=${SERIAL}"

# 3. monta o body (CSR precisa ir como string JSON, com \n escapado) e assina
CSR=$(jq -Rs . < terminal.csr)
jq -n --argjson csr "$CSR" --arg ott "$TOKEN" '{csr:$csr, ott:$ott}' \
  | curl -s -X POST "http://${ALB_DNS}/1.0/sign" -H "Content-Type: application/json" -d @- \
  -w "\nHTTP %{http_code}\n"
# esperado: 201 com {"crt": "-----BEGIN CERTIFICATE-----...", "ca": "..."}
```

## 8. Fora de escopo

Revogação/CRL; múltiplas réplicas/multi-AZ real; job de limpeza/reciclagem diária do EFS; backup do banco de provisioners; domínio próprio/ACM para o listener público do ALB (irrelevante para o que este teste valida).
