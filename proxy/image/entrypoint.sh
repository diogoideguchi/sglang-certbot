#!/bin/bash
# Wrapper de entrypoint: garante DNS (Cloudflare) e certificado TLS
# (Let's Encrypt via certbot + dns-cloudflare) atualizados antes de subir o
# comando real do SGLang, recebido via "Container Start Command" da RunPod.
#
# NÃO injeta flags no comando do usuário — só prepara ambiente (variáveis,
# arquivos de config) e termina com `exec "$@"`, preservando ao máximo o
# comportamento da imagem stock.
#
# Usa conexão TCP direta da RunPod (Expose TCP Ports), não o proxy HTTP
# deles (que fica atrás do Cloudflare da própria RunPod e é fonte conhecida
# de 502 — a RunPod recomenda TCP direto pra evitar isso). Por isso só
# depende de RUNPOD_PUBLIC_IP e RUNPOD_TCP_PORT_<porta>, ambas env vars
# auto-injetadas pela RunPod no próprio pod (confirmado na documentação
# oficial: docs.runpod.io/pods/templates/environment-variables e
# docs.runpod.io/pods/configuration/expose-ports) — nunca chama a API da
# RunPod nem faz lookup por pod ID/imagem (isso era o modelo do reconciler
# externo antigo, que rodava FORA do pod).
set -euo pipefail

log() { echo "[entrypoint] $*" >&2; }
die() { echo "[entrypoint] ERRO: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# (a) Validação de env vars essenciais
# ---------------------------------------------------------------------------
: "${CLOUDFLARE_API_TOKEN:?Set CLOUDFLARE_API_TOKEN (token de API Cloudflare com permissão Zone:DNS:Edit na zona do domínio)}"
: "${SGLANG_TLS_DOMAIN:?Set SGLANG_TLS_DOMAIN (ex. sglang.seu-dominio.com — domínio completo do certificado/A record)}"
: "${CERTBOT_EMAIL:?Set CERTBOT_EMAIL (email de contato pro Lets Encrypt, usado em avisos de expiração)}"
: "${RUNPOD_PUBLIC_IP:?RUNPOD_PUBLIC_IP não foi injetada pela RunPod — pod não está exposto via TCP direto (Expose TCP Ports)?}"

CERT_PERSIST_DIR="${CERT_PERSIST_DIR:-/workspace/certbot}"
CERT_RENEW_INTERVAL_SECONDS="${CERT_RENEW_INTERVAL_SECONDS:-43200}"  # 12h
SGLANG_CONTAINER_PORT="${SGLANG_CONTAINER_PORT:-8000}"

# Network volume da RunPod (/workspace) não aceita chmod 600 (EPERM) e tem
# POSIX limitado (locks, rename) — certbot faz chmod/lockf no config-dir.
# Por isso o certbot roda em disco local do container e o volume só guarda
# um tar.gz do config-dir (arquivo comum, sem depender de permissões).
CERTBOT_LOCAL_DIR="/root/certbot"
CERT_ARCHIVE="${CERT_PERSIST_DIR}/${SGLANG_TLS_DOMAIN}.tar.gz"

mkdir -p "$CERT_PERSIST_DIR" "${CERTBOT_LOCAL_DIR}/config"

if [[ -f "$CERT_ARCHIVE" ]]; then
  log "restaurando estado do certbot de ${CERT_ARCHIVE}"
  tar -xzpf "$CERT_ARCHIVE" -C "${CERTBOT_LOCAL_DIR}/config" \
    || die "falha ao extrair ${CERT_ARCHIVE} — arquivo corrompido? remova-o pra forçar nova emissão"
fi

# Salva o config-dir local no volume (tmp + mv pra não deixar tar.gz parcial).
persist_certbot_state() {
  if ! { tar -czf "${CERT_ARCHIVE}.tmp" -C "${CERTBOT_LOCAL_DIR}/config" . \
         && mv -f "${CERT_ARCHIVE}.tmp" "$CERT_ARCHIVE"; }; then
    log "AVISO: falha ao salvar estado do certbot em ${CERT_ARCHIVE} (cert segue válido localmente)"
  fi
}

public_port_var="RUNPOD_TCP_PORT_${SGLANG_CONTAINER_PORT}"
public_port="${!public_port_var:-<não encontrada em ${public_port_var}>}"
log "RUNPOD_PUBLIC_IP=${RUNPOD_PUBLIC_IP} ${public_port_var}=${public_port}"
log "DNS (A record) não carrega porta — o client precisa saber essa porta por fora. Recomendado: configurar SGLANG_CONTAINER_PORT >= 70000 pra porta externa fixa (symmetrical port mapping da RunPod)."

# ---------------------------------------------------------------------------
# (b) cloudflare.ini pra plugin dns-cloudflare do certbot
# ---------------------------------------------------------------------------
CF_INI="${CERTBOT_LOCAL_DIR}/cloudflare.ini"
umask 077
cat > "$CF_INI" <<EOF
dns_cloudflare_api_token = ${CLOUDFLARE_API_TOKEN}
EOF
chmod 600 "$CF_INI"

# ---------------------------------------------------------------------------
# (c) Atualiza o A record via API Cloudflare pro IP público atual do pod
# ---------------------------------------------------------------------------
cf_api() {
  curl -sS -m 15 -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
               -H "Content-Type: application/json" "$@"
}

# Domínio raiz: assume-se que a zona é o domínio registrável (ex.
# seu-dominio.com pra sglang.seu-dominio.com, ou o próprio domínio se for
# de 1 nível). Se
# CLOUDFLARE_ZONE_ID for setado, pula esse passo (evita ambiguidade em
# domínios com múltiplos níveis, ex. sub.dom.example.com).
zone_id="${CLOUDFLARE_ZONE_ID:-}"
if [[ -z "$zone_id" ]]; then
  zone_guess="$(echo "$SGLANG_TLS_DOMAIN" | rev | cut -d. -f1,2 | rev)"
  zone_resp="$(cf_api "https://api.cloudflare.com/client/v4/zones?name=${zone_guess}")" \
    || die "falha ao consultar zona Cloudflare pra '${zone_guess}'"
  zone_id="$(echo "$zone_resp" | jq -r '.result[0].id // empty')"
  [[ -n "$zone_id" ]] || die "zona Cloudflare não encontrada pra '${zone_guess}' (defina CLOUDFLARE_ZONE_ID explicitamente se o domínio tiver mais níveis)"
fi

rec_resp="$(cf_api "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=A&name=${SGLANG_TLS_DOMAIN}")" \
  || die "falha ao consultar A record de '${SGLANG_TLS_DOMAIN}'"
rec_id="$(echo "$rec_resp" | jq -r '.result[0].id // empty')"
rec_ip="$(echo "$rec_resp" | jq -r '.result[0].content // empty')"

if [[ "$rec_ip" == "$RUNPOD_PUBLIC_IP" ]]; then
  log "A record de ${SGLANG_TLS_DOMAIN} já aponta pra ${RUNPOD_PUBLIC_IP}, nada a fazer."
elif [[ -n "$rec_id" ]]; then
  log "atualizando A record de ${SGLANG_TLS_DOMAIN}: ${rec_ip:-<vazio>} -> ${RUNPOD_PUBLIC_IP}"
  cf_api -X PUT "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${rec_id}" \
    --data "$(jq -n --arg name "$SGLANG_TLS_DOMAIN" --arg ip "$RUNPOD_PUBLIC_IP" \
      '{type:"A", name:$name, content:$ip, ttl:120, proxied:false}')" \
    | jq -e '.success == true' >/dev/null \
    || die "falha ao atualizar A record de ${SGLANG_TLS_DOMAIN}"
else
  log "criando A record de ${SGLANG_TLS_DOMAIN} -> ${RUNPOD_PUBLIC_IP}"
  cf_api -X POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
    --data "$(jq -n --arg name "$SGLANG_TLS_DOMAIN" --arg ip "$RUNPOD_PUBLIC_IP" \
      '{type:"A", name:$name, content:$ip, ttl:120, proxied:false}')" \
    | jq -e '.success == true' >/dev/null \
    || die "falha ao criar A record de ${SGLANG_TLS_DOMAIN}"
fi

# ---------------------------------------------------------------------------
# (d) Emissão/renovação do certificado
# ---------------------------------------------------------------------------
certbot_common_args=(
  --non-interactive --agree-tos
  --email "$CERTBOT_EMAIL"
  --config-dir "${CERTBOT_LOCAL_DIR}/config"
  --work-dir "${CERTBOT_LOCAL_DIR}/work"
  --logs-dir "${CERTBOT_LOCAL_DIR}/logs"
)

live_cert="${CERTBOT_LOCAL_DIR}/config/live/${SGLANG_TLS_DOMAIN}/fullchain.pem"

if [[ -f "$live_cert" ]]; then
  log "certificado existente restaurado de ${CERT_ARCHIVE}, tentando renovar (no-op se ainda válido)"
  certbot renew "${certbot_common_args[@]}" \
    --cert-name "$SGLANG_TLS_DOMAIN" \
    || log "AVISO: renovação falhou, seguindo com o certificado existente (pode estar perto de expirar)"
else
  log "nenhum certificado existente, emitindo novo pra ${SGLANG_TLS_DOMAIN}"
  if ! certbot certonly "${certbot_common_args[@]}" \
      --dns-cloudflare \
      --dns-cloudflare-credentials "$CF_INI" \
      --dns-cloudflare-propagation-seconds 30 \
      -d "$SGLANG_TLS_DOMAIN"; then
    die "emissão do certificado falhou pra ${SGLANG_TLS_DOMAIN} — abortando start (TLS é requisito, container não sobe sem cert; ver logs certbot acima e em ${CERTBOT_LOCAL_DIR}/logs)"
  fi
fi

[[ -f "$live_cert" ]] || die "certificado ainda não existe em ${live_cert} após emissão/renovação — estado inesperado"
persist_certbot_state

# ---------------------------------------------------------------------------
# (e) Exporta paths do cert/key pro comando do usuário consumir
# ---------------------------------------------------------------------------
export SGLANG_SSL_CERTFILE="${CERTBOT_LOCAL_DIR}/config/live/${SGLANG_TLS_DOMAIN}/fullchain.pem"
export SGLANG_SSL_KEYFILE="${CERTBOT_LOCAL_DIR}/config/live/${SGLANG_TLS_DOMAIN}/privkey.pem"
log "TLS pronto: SGLANG_SSL_CERTFILE=${SGLANG_SSL_CERTFILE}"
log "dica: adicione --ssl-certfile \"\$SGLANG_SSL_CERTFILE\" --ssl-keyfile \"\$SGLANG_SSL_KEYFILE\" --enable-ssl-refresh ao seu comando de start pra hot-reload sem restart"

# ---------------------------------------------------------------------------
# (f) Loop de renovação em background, desacoplado do processo principal
# ---------------------------------------------------------------------------
(
  while true; do
    sleep "$CERT_RENEW_INTERVAL_SECONDS"
    log "[renew-loop] checando renovação de ${SGLANG_TLS_DOMAIN}"
    if certbot renew "${certbot_common_args[@]}" --cert-name "$SGLANG_TLS_DOMAIN"; then
      persist_certbot_state
    else
      log "[renew-loop] AVISO: tentativa de renovação falhou, tentando de novo no próximo ciclo"
    fi
  done
) &
disown

# ---------------------------------------------------------------------------
# (g) Executa o comando real do SGLang sem modificá-lo
# ---------------------------------------------------------------------------
log "iniciando comando: $*"
exec "$@"
