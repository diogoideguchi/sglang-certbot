ARG SGLANG_VERSION=v0.5.21
FROM lmsysorg/sglang:${SGLANG_VERSION}

# certbot + plugin DNS-01 Cloudflare via apt (evita depender de pip em
# build-time); curl+jq pra chamadas REST à API da Cloudflare no entrypoint.
RUN apt-get update && apt-get install -y --no-install-recommends \
      certbot \
      python3-certbot-dns-cloudflare \
      curl \
      jq \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# Sem CMD: o "Container Start Command" da RunPod supre o comando completo
# (ex. python3 -m sglang.launch_server ...), preservando o comportamento
# stock da imagem base — o entrypoint só prepara ambiente (DNS + cert) e
# faz exec "$@" no final, sem alterar o comando recebido.
