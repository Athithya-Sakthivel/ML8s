#!/usr/bin/env bash

rm -rf src/manifests/ && git add src && git commit -m "removed src/manifests/" && git push origin main --force

FLUX_CLI_VERSION="${FLUX_CLI_VERSION:-v2.7.5}"
SOPS_SECRET_NAME="${SOPS_SECRET_NAME:-sops-age}"
GIT_URL="${GIT_URL:-}"
GIT_TOKEN="${GIT_TOKEN:-}"
GIT_BRANCH="${GIT_BRANCH:-main}"
PUSH_PUBLIC_KEY_TO_REPO="${PUSH_PUBLIC_KEY_TO_REPO:-true}"
TMPDIR="${TMPDIR:-/tmp}"
AGE_KEY_FILE="${TMPDIR}/age.agekey"
MANIFEST_DIR="${MANIFEST_DIR:-src/manifests}"
AGE_VERSION="${AGE_VERSION:-v1.1.1}"
log(){ printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail(){ log "ERROR: $*"; exit 1; }
if [ -z "${GIT_URL}" ]; then fail "GIT_URL must be set"; fi
if [ -z "${GIT_TOKEN}" ]; then fail "GIT_TOKEN must be set"; fi
command -v git >/dev/null 2>&1 || fail "git required"
command -v kubectl >/dev/null 2>&1 || fail "kubectl required"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "${REPO_ROOT}" ] || fail "must run inside a git repository (cd to repo root)"
cd "${REPO_ROOT}"
ASSUMPTIONS=$'ASSUMPTIONS/INVARIANTS:\n- run from repo root\n- working tree must be clean\n- local branch must be up-to-date with origin\n- script will modify src/manifests/ in-place and push using GIT_TOKEN\n- private age key will be written to '"${AGE_KEY_FILE}"$'\n- flux installed or will be downloaded to /usr/local/bin/flux\n'
log "${ASSUMPTIONS}"
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "${CURRENT_BRANCH}" != "${GIT_BRANCH}" ]; then
  git rev-parse --verify "${GIT_BRANCH}" >/dev/null 2>&1 && git checkout "${GIT_BRANCH}" || fail "switch to ${GIT_BRANCH} or set GIT_BRANCH"
fi
git diff --quiet --ignore-submodules || fail "working tree is dirty; commit or stash changes first"
git fetch --quiet origin "${GIT_BRANCH}" || fail "git fetch failed"
BEHIND_COUNT="$(git rev-list --count HEAD..origin/${GIT_BRANCH} 2>/dev/null || echo 0)"
if [ "${BEHIND_COUNT}" -gt 0 ]; then
  fail "local branch is behind origin/${GIT_BRANCH}; run 'git pull --ff-only' before running this script"
fi
ensure_dir_atomic(){ mkdir -p "$1" || fail "mkdir failed for $1"; }
write_atomic(){ local file="$1"; local tmp="${file}.tmp"; mkdir -p "$(dirname "${file}")"; printf '%s\n' "$2" > "${tmp}" && mv -f "${tmp}" "${file}"; }
if [ -e "${MANIFEST_DIR}" ]; then
  log "found existing ${MANIFEST_DIR}; validating structure"
  if [ ! -d "${MANIFEST_DIR}/flux-system" ]; then
    log "creating ${MANIFEST_DIR}/flux-system placeholder"
    ensure_dir_atomic "${MANIFEST_DIR}/flux-system"
    write_atomic "${MANIFEST_DIR}/flux-system/.keep" "flux-system placeholder"
    git add "${MANIFEST_DIR}/flux-system/.keep"
  fi
  if [ ! -d "${MANIFEST_DIR}/platform" ]; then
    log "creating ${MANIFEST_DIR}/platform placeholder"
    ensure_dir_atomic "${MANIFEST_DIR}/platform"
    write_atomic "${MANIFEST_DIR}/platform/.keep" "platform placeholder"
    git add "${MANIFEST_DIR}/platform/.keep"
  fi
  if [ -f "${MANIFEST_DIR}/kustomization.yaml" ]; then
    if ! grep -q "flux-system/" "${MANIFEST_DIR}/kustomization.yaml" 2>/dev/null || ! grep -q "platform/" "${MANIFEST_DIR}/kustomization.yaml" 2>/dev/null; then
      fail "${MANIFEST_DIR}/kustomization.yaml exists but does not list flux-system/ and platform/; fix manually"
    fi
  else
    ROOT_KUST=$'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n- flux-system/\n- platform/\n'
    write_atomic "${MANIFEST_DIR}/kustomization.yaml" "${ROOT_KUST}"
    git add "${MANIFEST_DIR}/kustomization.yaml"
  fi
else
  log "creating safe skeleton under ${MANIFEST_DIR}"
  ensure_dir_atomic "${MANIFEST_DIR}/flux-system"
  ensure_dir_atomic "${MANIFEST_DIR}/platform"
  write_atomic "${MANIFEST_DIR}/flux-system/.keep" "flux-system placeholder"
  write_atomic "${MANIFEST_DIR}/platform/.keep" "platform placeholder"
  ROOT_KUST=$'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n- flux-system/\n- platform/\n'
  write_atomic "${MANIFEST_DIR}/kustomization.yaml" "${ROOT_KUST}"
  git add --all "${MANIFEST_DIR}"
fi
if git commit -m "chore: ensure flux-safe skeleton (flux-system + platform)" >/dev/null 2>&1; then
  log "pushing skeleton commit"
  git push "https://${GIT_TOKEN}@$(echo ${GIT_URL} | sed -E 's#^https://##')" "HEAD:${GIT_BRANCH}" || fail "git push skeleton failed"
else
  log "no skeleton changes to commit"
fi
log "ensuring flux CLI ${FLUX_CLI_VERSION}"
if ! command -v flux >/dev/null 2>&1; then
  OS="$(uname | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m)"
  case "${ARCH}" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) ARCH="amd64" ;;
  esac
  case "${OS}" in
    linux) ASSET="flux_${FLUX_CLI_VERSION#v}_linux_${ARCH}.tar.gz" ;;
    darwin) ASSET="flux_${FLUX_CLI_VERSION#v}_darwin_${ARCH}.tar.gz" ;;
    *) fail "unsupported os ${OS}" ;;
  esac
  URL="https://github.com/fluxcd/flux2/releases/download/${FLUX_CLI_VERSION}/${ASSET}"
  TMP_TAR="${TMPDIR}/flux-${FLUX_CLI_VERSION}.tar.gz"
  curl -fsSL "${URL}" -o "${TMP_TAR}" || fail "download flux failed"
  tar -C "${TMPDIR}" -xzf "${TMP_TAR}" || fail "extract flux failed"
  if [ -f "${TMPDIR}/flux" ]; then mv "${TMPDIR}/flux" /usr/local/bin/flux || fail "move flux failed"; else mv "${TMPDIR}/flux-${FLUX_CLI_VERSION#v}/flux" /usr/local/bin/flux || fail "move flux failed"; fi
  chmod +x /usr/local/bin/flux
  log "flux installed to /usr/local/bin/flux"
else
  log "flux cli found at $(command -v flux)"
fi
log "ensure age-keygen ${AGE_VERSION} present"
if ! command -v age-keygen >/dev/null 2>&1; then
  OS="$(uname | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m)"
  case "${ARCH}" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) ARCH="amd64" ;;
  esac
  case "${OS}" in
    linux) AGE_ASSET="age-${AGE_VERSION#v}-linux-${ARCH}.tar.gz" ;;
    darwin) AGE_ASSET="age-${AGE_VERSION#v}-darwin-${ARCH}.tar.gz" ;;
    *) fail "unsupported os for age" ;;
  esac
  AGE_URL="https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/${AGE_ASSET}"
  TMP_AGE="${TMPDIR}/age-${AGE_VERSION}.tar.gz"
  curl -fsSL "${AGE_URL}" -o "${TMP_AGE}" || fail "download age failed"
  tar -C "${TMPDIR}" -xzf "${TMP_AGE}" || fail "extract age failed"
  if [ -f "${TMPDIR}/age/age-keygen" ]; then mv "${TMPDIR}/age/age-keygen" /usr/local/bin/age-keygen; elif [ -f "${TMPDIR}/age-keygen" ]; then mv "${TMPDIR}/age-keygen" /usr/local/bin/age-keygen; else fail "age binary not found after extract"; fi
  chmod +x /usr/local/bin/age-keygen
  log "age-keygen installed"
else
  log "age-keygen present at $(command -v age-keygen)"
fi
log "generate or reuse age key at ${AGE_KEY_FILE}"
if [ -f "${AGE_KEY_FILE}" ]; then
  log "reusing existing age key ${AGE_KEY_FILE}"
else
  age-keygen -o "${AGE_KEY_FILE}" || fail "age-keygen failed"
fi
PUB_LINE="$(grep -i 'public key:' -m1 "${AGE_KEY_FILE}" | sed 's/^[[:space:]]*//')"
[ -n "${PUB_LINE}" ] || fail "could not extract public key from ${AGE_KEY_FILE}"
log "public key: ${PUB_LINE}"
log "running flux bootstrap git (will write flux components under ${MANIFEST_DIR}/flux-system)"
BOOT_CMD=(flux bootstrap git --url="${GIT_URL}" --branch="${GIT_BRANCH}" --path="${MANIFEST_DIR}/flux-system" --token-auth --username=git --password="${GIT_TOKEN}" --version="${FLUX_CLI_VERSION}" --timeout=5m)
"${BOOT_CMD[@]}" || fail "flux bootstrap failed"
SOPS_MANIFEST_DIR="${MANIFEST_DIR}/platform/sops"
ensure_dir_atomic "${SOPS_MANIFEST_DIR}"
SOPS_SECRET_YAML=$(cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SOPS_SECRET_NAME}
  namespace: flux-system
type: Opaque
stringData:
  age.agekey: |
$(sed 's/^/    /' "${AGE_KEY_FILE}")
EOF
)
write_atomic "${SOPS_MANIFEST_DIR}/secret.yaml" "${SOPS_SECRET_YAML}"
git add "${SOPS_MANIFEST_DIR}/secret.yaml"
if git commit -m "chore: add sops-age secret manifest (flux-system namespace)" >/dev/null 2>&1; then
  log "pushing sops secret manifest commit"
  git push "https://${GIT_TOKEN}@$(echo ${GIT_URL} | sed -E 's#^https://##')" "HEAD:${GIT_BRANCH}" || fail "git push of sops manifest failed"
else
  log "no change to commit for sops secret"
fi
if [ "${PUSH_PUBLIC_KEY_TO_REPO}" = "true" ]; then
  SOPS_PUB_PATH="${MANIFEST_DIR}/.sops.pub"
  write_atomic "${SOPS_PUB_PATH}" "# public key: ${PUB_LINE#public key: }"
  git add "${SOPS_PUB_PATH}"
  if git commit -m "chore: add sops public key for cluster bootstrap" >/dev/null 2>&1; then
    git push "https://${GIT_TOKEN}@$(echo ${GIT_URL} | sed -E 's#^https://##')" "HEAD:${GIT_BRANCH}" || fail "git push of .sops.pub failed"
    log "public key pushed to ${SOPS_PUB_PATH}"
  else
    log "no change for .sops.pub"
  fi
else
  log "PUSH_PUBLIC_KEY_TO_REPO is false; not pushing public key"
fi
log "flux bootstrap + sops manifest persisted locally and pushed. Local repo contains src/manifests/ ready for viewing."
exit 0
