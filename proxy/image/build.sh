#!/bin/bash
# Build + tag da imagem como hantonio/sglang-certbot:<versão sglang>.<versão certbot>.
# Versões lidas de dentro da imagem já construída (fonte da verdade), não
# chutadas no script.
set -euo pipefail

REGISTRY_IMAGE="${REGISTRY_IMAGE:-hantonio/sglang-certbot}"
SGLANG_VERSION="${SGLANG_VERSION:-v0.5.18}"
BUILD_TAG="sglang-certbot:build-tmp"

cd "$(dirname "$0")"

docker build --build-arg "SGLANG_VERSION=${SGLANG_VERSION}" -t "$BUILD_TAG" .

sglang_ver="$(docker run --rm --entrypoint pip "$BUILD_TAG" show sglang | awk '/^Version:/{print $2}')"
certbot_ver="$(docker run --rm --entrypoint certbot "$BUILD_TAG" --version | awk '{print $2}')"

tag="${REGISTRY_IMAGE}:${sglang_ver}.${certbot_ver}"
docker tag "$BUILD_TAG" "$tag"
docker tag "$BUILD_TAG" "${REGISTRY_IMAGE}:latest"

echo "Imagem taggeada: ${tag} (+ ${REGISTRY_IMAGE}:latest)"
echo "Push manual: docker push ${tag} && docker push ${REGISTRY_IMAGE}:latest"
