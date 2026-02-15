#!/usr/bin/env bash

FLUX_CLI_VERSION="${FLUX_CLI_VERSION:-v2.7.5}"
SOPS_SECRET_NAME="${SOPS_SECRET_NAME:-sops-age}"
GIT_URL="${GIT_URL:-}"
GIT_TOKEN="${GIT_TOKEN:-}"
GIT_BRANCH="${GIT_BRANCH:-main}"
PUSH_PUBLIC_KEY_TO_REPO="${PUSH_PUBLIC_KEY_TO_REPO:-true}"
TMPDIR="${TMPDIR:-/tmp}"
AGE_KEY_FILE="${TMPDIR}/age.agekey"
log(){ printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail(){ log "ERROR: $*"; exit 1; }
[ -n "$GIT_URL" ] || fail "GIT_URL must be set"
[ -n "$GIT_TOKEN" ] || fail "GIT_TOKEN must be set (classic PAT ghp_)"
command -v kubectl >/dev/null 2>&1 || fail "kubectl required"
command -v git >/dev/null 2>&1 || fail "git required"
if ! command -v flux >/dev/null 2>&1; then
  log "installing flux CLI ${FLUX_CLI_VERSION}"
  OS="$(uname | tr '[:upper:]' '[:lower:]')"
  case "${OS}" in
    linux) ASSET="flux_${FLUX_CLI_VERSION#v}_linux_amd64.tar.gz" ;;
    darwin) ASSET="flux_${FLUX_CLI_VERSION#v}_darwin_amd64.tar.gz" ;;
    *) fail "unsupported os ${OS}" ;;
  esac
  URL="https://github.com/fluxcd/flux2/releases/download/${FLUX_CLI_VERSION}/${ASSET}"
  TMP_TAR="${TMPDIR}/flux-${FLUX_CLI_VERSION}.tar.gz"
  curl -fsSL "${URL}" -o "${TMP_TAR}" || fail "download flux failed"
  tar -C "${TMPDIR}" -xzf "${TMP_TAR}"
  mv "${TMPDIR}/flux" /usr/local/bin/flux || mv "${TMPDIR}/flux" /usr/local/bin/flux || fail "move flux failed"
  chmod +x /usr/local/bin/flux
  log "flux installed to /usr/local/bin/flux"
else
  log "flux cli found at $(command -v flux)"
fi
if ! command -v age-keygen >/dev/null 2>&1; then
  log "installing age-keygen"
  AGE_API="https://api.github.com/repos/FiloSottile/age/releases/latest"
  AGE_TAG="$(curl -fsSL "${AGE_API}" | grep -Po '\"tag_name\":\\s*\"\\K(.*?)(?=\")')"
  [ -n "${AGE_TAG}" ] || fail "could not find age release"
  OS="$(uname | tr '[:upper:]' '[:lower:]')"
  case "${OS}" in
    linux) AGE_ASSET="age-${AGE_TAG}-linux-amd64.tar.gz" ;;
    darwin) AGE_ASSET="age-${AGE_TAG}-darwin-amd64.tar.gz" ;;
    *) fail "unsupported os for age" ;;
  esac
  AGE_URL="https://github.com/FiloSottile/age/releases/download/${AGE_TAG}/${AGE_ASSET}"
  TMP_AGE="${TMPDIR}/age-${AGE_TAG}.tar.gz"
  curl -fsSL "${AGE_URL}" -o "${TMP_AGE}" || fail "download age failed"
  tar -C "${TMPDIR}" -xzf "${TMP_AGE}"
  if [ -f "${TMPDIR}/age/age-keygen" ]; then mv "${TMPDIR}/age/age-keygen" /usr/local/bin/age-keygen; else mv "${TMPDIR}/age-keygen" /usr/local/bin/age-keygen; fi
  chmod +x /usr/local/bin/age-keygen
  log "age-keygen installed"
else
  log "age-keygen present at $(command -v age-keygen)"
fi
if [ -f "${AGE_KEY_FILE}" ]; then
  log "reusing existing age key ${AGE_KEY_FILE}"
else
  log "generating age keypair -> ${AGE_KEY_FILE}"
  age-keygen -o "${AGE_KEY_FILE}" || fail "age-keygen failed"
fi
PUB_LINE="$(grep -i 'public key:' -m1 "${AGE_KEY_FILE}" | sed 's/^[[:space:]]*//')"
[ -n "${PUB_LINE}" ] || fail "could not extract public key from ${AGE_KEY_FILE}"
log "public key: ${PUB_LINE}"
BOOT_CMD=(flux bootstrap git --url="${GIT_URL}" --branch="${GIT_BRANCH}" --path="src/manifests" --token-auth --username=git --password="${GIT_TOKEN}" --version="${FLUX_CLI_VERSION}")
log "running flux bootstrap git (will push flux-system manifests)"
"${BOOT_CMD[@]}" || fail "flux bootstrap failed"
log "ensuring flux-system namespace exists"
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
log "creating sops secret ${SOPS_SECRET_NAME} in flux-system"
kubectl -n flux-system create secret generic "${SOPS_SECRET_NAME}" --from-file=age.agekey="${AGE_KEY_FILE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
log "sops secret ${SOPS_SECRET_NAME} ensured"
if [ "${PUSH_PUBLIC_KEY_TO_REPO}" = "true" ]; then
  log "pushing public key into repository at src/manifests/.sops.pub"
  TMP_CLONE="$(mktemp -d)"
  AUTH_URL="$(echo "${GIT_URL}" | sed -E 's#^https://##')"
  git clone --depth 1 --branch "${GIT_BRANCH}" "https://${GIT_TOKEN}@${AUTH_URL}" "${TMP_CLONE}" >/dev/null 2>&1 || fail "git clone failed"
  mkdir -p "${TMP_CLONE}/src/manifests"
  printf '%s\n' "# public key: ${PUB_LINE#public key: }" > "${TMP_CLONE}/src/manifests/.sops.pub"
  cd "${TMP_CLONE}"
  git add src/manifests/.sops.pub
  git commit -m "chore: add sops public key for cluster bootstrap" >/dev/null 2>&1 || log "no change to commit"
  git push origin "${GIT_BRANCH}" >/dev/null 2>&1 || fail "git push of .sops.pub failed"
  cd - >/dev/null 2>&1
  rm -rf "${TMP_CLONE}"
  log "public key pushed to src/manifests/.sops.pub"
else
  log "PUSH_PUBLIC_KEY_TO_REPO is false; not pushing public key"
fi
log "flux bootstrap + sops setup complete. Keep private key ${AGE_KEY_FILE} secure."
exit 0
