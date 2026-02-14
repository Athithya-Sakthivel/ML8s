#!/usr/bin/env bash
set -Eeuo pipefail

DOCKER_USERNAME="${DOCKER_USERNAME:-ml8s}"
DOCKER_PASSWORD="${DOCKER_PASSWORD:-}"
VERSION_TAG="${VERSION_TAG:-v2-amd64-arm64}"
PLATFORMS="linux/amd64,linux/arm64"

FE_DOCKERFILE="src/images/Dockerfile.fe"
TRAIN_DOCKERFILE="src/images/Dockerfile.train"
BUILD_CONTEXT="."

FE_IMAGE="${DOCKER_USERNAME}/fe:${VERSION_TAG}"
TRAIN_IMAGE="${DOCKER_USERNAME}/train:${VERSION_TAG}"

BUILDER_NAME="ml8s-multiarch"

log() {
  printf '[INFO] %s\n' "$1"
}

fail() {
  printf '[ERROR] %s\n' "$1" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 not found"
}

ensure_builder() {
  if ! docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
    log "Creating buildx builder ${BUILDER_NAME}"
    docker buildx create --name "${BUILDER_NAME}" --use
  fi
  log "Bootstrapping builder"
  docker buildx inspect --bootstrap
}

login_dockerhub() {
  [[ -n "${DOCKER_PASSWORD}" ]] || fail "DOCKER_PASSWORD not set"
  log "Logging into Docker Hub as ${DOCKER_USERNAME}"
  printf '%s\n' "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USERNAME}" --password-stdin
}

build_and_push() {
  local image="$1"
  local dockerfile="$2"

  [[ -f "${dockerfile}" ]] || fail "Dockerfile not found: ${dockerfile}"

  log "Building and pushing multi-arch image ${image}"
  docker buildx build \
    --builder "${BUILDER_NAME}" \
    --platform "${PLATFORMS}" \
    --file "${dockerfile}" \
    --tag "${image}" \
    --push \
    "${BUILD_CONTEXT}"

  log "Completed ${image}"
}

main() {
  require docker
  require docker

  login_dockerhub
  ensure_builder

  build_and_push "${FE_IMAGE}" "${FE_DOCKERFILE}"
  build_and_push "${TRAIN_IMAGE}" "${TRAIN_DOCKERFILE}"

  log "Multi-arch images pushed successfully"
}

main "$@"
