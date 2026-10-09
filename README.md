# sglang-certbot

Expõe um modelo servido pelo [SGLang](https://github.com/sgl-project/sglang)
(rodando num pod RunPod) via HTTPS com certificado Let's Encrypt válido e
renovação automática, sem depender de IP fixo do pod.

## Como funciona

O SGLang termina TLS nativamente dentro do próprio pod (suporte built-in a
`--ssl-certfile`/`--ssl-keyfile`/`--enable-ssl-refresh`), com certbot
embutido na imagem emitindo/renovando o certificado via desafio **DNS-01**
da Cloudflare — não depende de HTTP-01/porta 80 acessível, nem de proxy
externo. O entrypoint também mantém o A record do domínio atualizado na
Cloudflare, usando `RUNPOD_PUBLIC_IP` (env var auto-injetada pela RunPod no
próprio pod — sem chamada de API).

> Usa a conexão **TCP direta** da RunPod (Expose TCP Ports), não o proxy
> HTTP deles (que fica atrás do Cloudflare da própria RunPod — fonte
> conhecida de 502/instabilidade; a própria RunPod recomenda TCP direto
> pra evitar isso).

```
Cliente
   │  https://<seu-domínio>:<porta>
   ▼
Pod RunPod — imagem custom (lmsysorg/sglang + certbot embutido)
   entrypoint.sh, no start:
     1. atualiza A record da Cloudflare -> RUNPOD_PUBLIC_IP
     2. emite/renova cert via certbot (DNS-01, plugin Cloudflare)
     3. sobe loop de renovação em background (12h)
     4. exec do comando recebido via "Container Start Command" (inalterado)
   sglang.launch_server --ssl-certfile ... --ssl-keyfile ... --enable-ssl-refresh
```

## Pré-requisitos

- Domínio numa zona gerenciada pela Cloudflare.
- Conta RunPod com um template de pod GPU.
- Docker Hub (ou outro registry) se for buildar sua própria imagem.

## Build e publicação

Imagem publicada como `hantonio/sglang-certbot:<versão sglang>.<versão certbot>`
(ex. `hantonio/sglang-certbot:0.5.21.2.9.0`), sempre lendo as versões reais
de dentro da imagem já buildada (sglang via `pip show sglang`, certbot via
`certbot --version`) — nunca digitadas à mão.

**CI**: `.github/workflows/build-push.yml` builda e publica automaticamente
a cada push em `main` que toque `proxy/image/**`. Requer secrets do repo
GitHub:

| Secret | Descrição |
|---|---|
| `DOCKERHUB_USERNAME` | Usuário/org do Docker Hub |
| `DOCKERHUB_TOKEN` | Access Token do Docker Hub (não a senha) — criar em hub.docker.com > Account Settings > Security |

**Local**: `proxy/image/build.sh` faz o mesmo processo (build → extrai
versões → tag) sem publicar:

```bash
./proxy/image/build.sh
# push manual, sob revisão:
# docker push <seu-registry>/sglang-certbot:<tag gerada>
```

Build manual (sem tag automática):

```bash
docker build --build-arg SGLANG_VERSION=v0.5.21 \
  -t <seu-registry>/sglang-certbot:dev -f proxy/image/Dockerfile proxy/image/
```

## Configuração do template RunPod

- Imagem: `<seu-registry>/sglang-certbot:<tag>`.
- Expor a porta do SGLang via **Expose TCP Ports** (não via HTTP Proxy).
  Recomendado usar uma porta interna **>= 70000** ("symmetrical port
  mapping" da RunPod — feature oficial): a porta externa fica idêntica à
  interna e previsível entre restarts, só o IP muda. Elimina qualquer
  necessidade do client descobrir a porta.
- Variáveis de ambiente — ver `proxy/image/cloudflare-dns.env.example` e a
  tabela abaixo. `CLOUDFLARE_API_TOKEN` e `SGLANG_API_KEY` como RunPod
  Secret, nunca em texto puro no template.
- Comando de start (o wrapper **não** injeta flags — o comando roda como
  configurado, `exec "$@"` puro):
  ```
  python3 -m sglang.launch_server --host 0.0.0.0 --port ${SGLANG_CONTAINER_PORT} \
    --api-key ${SGLANG_API_KEY} \
    --ssl-certfile ${SGLANG_SSL_CERTFILE} --ssl-keyfile ${SGLANG_SSL_KEYFILE} \
    --enable-ssl-refresh \
    <args do modelo>
  ```
  `SGLANG_SSL_CERTFILE`/`SGLANG_SSL_KEYFILE` são exportadas pelo entrypoint
  antes do exec — só referenciar, não precisa configurar.

### Configuração no console Cloudflare

1. Domínio numa zona Cloudflare (nameservers apontando pra Cloudflare).
2. **API Token** (não Global API Key): *My Profile → API Tokens → Create
   Token*, permissão **Zone → DNS → Edit** restrita à zona do domínio.
3. O A record do subdomínio é criado/atualizado automaticamente pelo
   entrypoint — não precisa criar manual. Ele é criado com **proxy
   desativado** (nuvem cinza/DNS-only), necessário pra TCP direto da
   RunPod; não mude pra "Proxied" depois.
4. `CLOUDFLARE_ZONE_ID` só é necessário se o domínio tiver mais de 2 níveis
   (ex. `sub.dominio.exemplo.com`), onde a detecção automática por zona
   (2 últimos labels) fica ambígua.

### Variáveis de ambiente

| Variável | Obrigatória | Default | Descrição |
|---|---|---|---|
| `CLOUDFLARE_API_TOKEN` | sim | — | Token API Cloudflare (Zone:DNS:Edit na zona do domínio) |
| `SGLANG_TLS_DOMAIN` | sim | — | FQDN do certificado/A record (ex. `sglang.seu-dominio.com`) |
| `CERTBOT_EMAIL` | sim | — | Contato Let's Encrypt |
| `RUNPOD_PUBLIC_IP` | sim (auto-injetada pela RunPod) | — | IP público atual do pod (TCP direto) |
| `SGLANG_CONTAINER_PORT` | não | `8000` | Porta interna do SGLang — usada só pra logar a porta pública lida de `RUNPOD_TCP_PORT_<essa porta>` (auto-injetada); nenhuma chamada de API envolvida |
| `CLOUDFLARE_ZONE_ID` | não | auto-resolvido via API | Override pra domínios com mais de 2 níveis |
| `CERT_PERSIST_DIR` | não | `/workspace/certbot` | Diretório persistente (volume RunPod) com config/work/logs do certbot + cloudflare.ini |
| `CERT_RENEW_INTERVAL_SECONDS` | não | `43200` (12h) | Intervalo do loop de renovação em background |

Exportadas pelo entrypoint (output, pro comando do usuário consumir):
`SGLANG_SSL_CERTFILE`, `SGLANG_SSL_KEYFILE`.

## Operação

```bash
# logs do entrypoint (DNS update, emissão/renovação de cert) no stdout do pod,
# prefixados com [entrypoint]

# testar direto (sem proxy)
curl -s https://<seu-domínio>:<porta>/health

# confirmar que o A record aponta pro IP atual do pod
dig +short <seu-domínio>
```

Restart do pod: A record é atualizado automaticamente no próximo start;
certificado existente em `CERT_PERSIST_DIR` (persistente) é reaproveitado
(renovado, não reemitido) enquanto ainda válido.

## Verificação end-to-end (antes de ir pra produção)

1. `docker build -t sglang-certbot:test -f proxy/image/Dockerfile proxy/image/` — build não precisa de GPU.
2. `shellcheck proxy/image/entrypoint.sh`.
3. Rodar o container sem GPU com comando trivial (`-- echo ok`) e env vars reais apontando pra uma zona/domínio de teste descartável na Cloudflare — exercita a chamada real à API e emissão DNS-01 (não precisa de porta 80 nem GPU).
4. Testes negativos: faltando env var obrigatória → falha rápido com mensagem clara; `CLOUDFLARE_API_TOKEN` inválido sem cert persistido → aborta com erro claro, não trava.
5. Teste de idempotência: rodar 2x com `CERT_PERSIST_DIR` montado como volume local — 2ª vez pula emissão, vai direto pro `certbot renew` (no-op).
6. No RunPod real: conferir nos logs o update de A record, emissão de cert, export das env vars, SGLang subindo com SSL. `curl -v https://<seu-domínio>:<porta>/health` confirma handshake TLS válido. Restart do pod confirma reaproveitamento do cert + A record atualizado pro novo IP.
