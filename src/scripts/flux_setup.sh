#!/usr/bin/env bash

# --- configuration (override via env) ---
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

# platform kustomization config (you can override)
PLATFORM_KUSTOMIZATION_NAME="${PLATFORM_KUSTOMIZATION_NAME:-platform}"
PLATFORM_KUSTOMIZATION_INTERVAL="${PLATFORM_KUSTOMIZATION_INTERVAL:-10m}"
PLATFORM_KUSTOMIZATION_FILE="${MANIFEST_DIR}/flux-system/${PLATFORM_KUSTOMIZATION_NAME}-kustomization.yaml"

# --- helpers ---
log(){ printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail(){ log "ERROR: $*"; exit 1; }
ensure_dir_atomic(){ mkdir -p "$1" || fail "mkdir failed for $1"; }
write_atomic(){ local file="$1"; local tmp="${file}.tmp"; mkdir -p "$(dirname "${file}")"; printf '%s\n' "$2" > "${tmp}" && mv -f "${tmp}" "${file}"; }

# --- basic validation ---
[ -n "${GIT_URL}" ] || fail "GIT_URL must be set"
[ -n "${GIT_TOKEN}" ] || fail "GIT_TOKEN must be set"
command -v git >/dev/null 2>&1 || fail "git required"
command -v kubectl >/dev/null 2>&1 || fail "kubectl required"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "${REPO_ROOT}" ] || fail "must run inside a git repository (cd to repo root)"
cd "${REPO_ROOT}"

AUTH_URL="$(echo "${GIT_URL}" | sed -E 's#^https://##')"

log "ASSUMPTIONS: running from repo root; script will operate in-place and push using token; private age key at ${AGE_KEY_FILE}"

# --- ensure branch and authoritative reset (idempotent) ---
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "${CURRENT_BRANCH}" != "${GIT_BRANCH}" ]; then
  git rev-parse --verify "${GIT_BRANCH}" >/dev/null 2>&1 && git checkout "${GIT_BRANCH}" || fail "switch to ${GIT_BRANCH} or set GIT_BRANCH"
fi

log "fetching origin/${GIT_BRANCH}"
git fetch --quiet origin "${GIT_BRANCH}" || log "git fetch failed (continuing)"

if git show-ref --verify --quiet "refs/remotes/origin/${GIT_BRANCH}"; then
  log "resetting local ${GIT_BRANCH} to origin/${GIT_BRANCH} (authoritative)"
  git reset --hard "origin/${GIT_BRANCH}" || log "reset failed; continuing"
else
  log "origin/${GIT_BRANCH} not found; will create branch on push"
fi

# --- ensure manifest skeleton (idempotent) ---
COMMIT_PATHS=()
if [ -e "${MANIFEST_DIR}" ]; then
  log "found existing ${MANIFEST_DIR}; ensuring placeholders exist"
  ensure_dir_atomic "${MANIFEST_DIR}/flux-system"
  ensure_dir_atomic "${MANIFEST_DIR}/platform"
  if [ ! -f "${MANIFEST_DIR}/flux-system/.keep" ]; then
    write_atomic "${MANIFEST_DIR}/flux-system/.keep" "flux-system placeholder"
    COMMIT_PATHS+=("${MANIFEST_DIR}/flux-system/.keep")
  fi
  if [ ! -f "${MANIFEST_DIR}/platform/.keep" ]; then
    write_atomic "${MANIFEST_DIR}/platform/.keep" "platform placeholder"
    COMMIT_PATHS+=("${MANIFEST_DIR}/platform/.keep")
  fi
  if [ ! -f "${MANIFEST_DIR}/kustomization.yaml" ]; then
    ROOT_KUST=$'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n- flux-system/\n- platform/\n'
    write_atomic "${MANIFEST_DIR}/kustomization.yaml" "${ROOT_KUST}"
    COMMIT_PATHS+=("${MANIFEST_DIR}/kustomization.yaml")
  else
    log "existing ${MANIFEST_DIR}/kustomization.yaml preserved"
  fi
else
  log "creating skeleton under ${MANIFEST_DIR}"
  ensure_dir_atomic "${MANIFEST_DIR}/flux-system"
  ensure_dir_atomic "${MANIFEST_DIR}/platform"
  write_atomic "${MANIFEST_DIR}/flux-system/.keep" "flux-system placeholder"
  write_atomic "${MANIFEST_DIR}/platform/.keep" "platform placeholder"
  ROOT_KUST=$'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n- flux-system/\n- platform/\n'
  write_atomic "${MANIFEST_DIR}/kustomization.yaml" "${ROOT_KUST}"
  COMMIT_PATHS+=("${MANIFEST_DIR}/flux-system/.keep" "${MANIFEST_DIR}/platform/.keep" "${MANIFEST_DIR}/kustomization.yaml")
fi

# commit/push skeleton if needed
if [ "${#COMMIT_PATHS[@]}" -gt 0 ]; then
  for p in "${COMMIT_PATHS[@]}"; do git add -- "${p}"; done
  git commit -m "chore: add flux-safe skeleton (flux-system + platform)" >/dev/null 2>&1 || log "nothing new to commit for skeleton"
  log "force-pushing skeleton state to remote ${GIT_BRANCH}"
  git push --force-with-lease "https://${GIT_TOKEN}@${AUTH_URL}" "HEAD:${GIT_BRANCH}" || fail "force push skeleton failed"
else
  log "skeleton already present; enforcing remote sync (force-with-lease)"
  git push --force-with-lease "https://${GIT_TOKEN}@${AUTH_URL}" "HEAD:${GIT_BRANCH}" || fail "force push sync failed"
fi

# --- ensure flux CLI present ---
log "ensuring flux CLI ${FLUX_CLI_VERSION}"
if ! command -v flux >/dev/null 2>&1; then
  OS="$(uname | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m)"
  case "${ARCH}" in x86_64|amd64) ARCH="amd64" ;; aarch64|arm64) ARCH="arm64" ;; *) ARCH="amd64" ;; esac
  case "${OS}" in linux) ASSET="flux_${FLUX_CLI_VERSION#v}_linux_${ARCH}.tar.gz" ;; darwin) ASSET="flux_${FLUX_CLI_VERSION#v}_darwin_${ARCH}.tar.gz" ;; *) fail "unsupported os ${OS}" ;; esac
  URL="https://github.com/fluxcd/flux2/releases/download/${FLUX_CLI_VERSION}/${ASSET}"
  TMP_TAR="${TMPDIR}/flux-${FLUX_CLI_VERSION}.tar.gz"
  curl -fL "${URL}" -o "${TMP_TAR}" || fail "download flux failed"
  tar -C "${TMPDIR}" -xzf "${TMP_TAR}" || fail "extract flux failed"
  if [ -f "${TMPDIR}/flux" ]; then mv "${TMPDIR}/flux" /usr/local/bin/flux || fail "move flux failed"; else mv "${TMPDIR}/flux-${FLUX_CLI_VERSION#v}/flux" /usr/local/bin/flux || fail "move flux failed"; fi
  chmod +x /usr/local/bin/flux
  log "flux installed"
else
  log "flux cli found at $(command -v flux)"
fi

# --- ensure age-keygen present ---
log "ensure age-keygen ${AGE_VERSION} present"
if ! command -v age-keygen >/dev/null 2>&1; then
  OS="$(uname | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m)"
  case "${ARCH}" in x86_64|amd64) ARCH="amd64" ;; aarch64|arm64) ARCH="arm64" ;; *) ARCH="amd64" ;; esac
  AGE_ASSET="age-v${AGE_VERSION#v}-linux-${ARCH}.tar.gz"
  AGE_URL="https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/${AGE_ASSET}"
  TMP_AGE="${TMPDIR}/age-${AGE_VERSION}.tar.gz"
  if ! curl -fL "${AGE_URL}" -o "${TMP_AGE}"; then
    AGE_ASSET="age-${AGE_VERSION#v}-linux-${ARCH}.tar.gz"
    AGE_URL="https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/${AGE_ASSET}"
    curl -fL "${AGE_URL}" -o "${TMP_AGE}" || fail "download age failed (check AGE_VERSION)"
  fi
  tar -C "${TMPDIR}" -xzf "${TMP_AGE}" || fail "extract age failed"
  if [ -f "${TMPDIR}/age/age-keygen" ]; then mv "${TMPDIR}/age/age-keygen" /usr/local/bin/age-keygen
  elif [ -f "${TMPDIR}/age-keygen" ]; then mv "${TMPDIR}/age-keygen" /usr/local/bin/age-keygen
  else fail "age binary not found after extract"; fi
  chmod +x /usr/local/bin/age-keygen
  log "age-keygen installed"
else
  log "age-keygen present at $(command -v age-keygen)"
fi

# --- generate or reuse age key ---
log "generate or reuse age key at ${AGE_KEY_FILE}"
if [ -f "${AGE_KEY_FILE}" ]; then
  log "reusing existing age key ${AGE_KEY_FILE}"
else
  age-keygen -o "${AGE_KEY_FILE}" || fail "age-keygen failed"
fi

PUB_LINE="$(grep -i 'public key:' -m1 "${AGE_KEY_FILE}" | sed 's/^[[:space:]]*//')"
[ -n "${PUB_LINE}" ] || fail "could not extract public key from ${AGE_KEY_FILE}"
log "public key: ${PUB_LINE}"

# --- bootstrap flux into the cluster (idempotent) ---
log "running flux bootstrap git writing under ${MANIFEST_DIR}/flux-system"
BOOT_CMD=(flux bootstrap git --url="${GIT_URL}" --branch="${GIT_BRANCH}" --path="${MANIFEST_DIR}/flux-system" --token-auth --username=git --password="${GIT_TOKEN}" --version="${FLUX_CLI_VERSION}" --timeout=5m)
if "${BOOT_CMD[@]}"; then
  log "flux bootstrap completed (or already applied)"
else
  log "flux bootstrap reported failure; check controllers and logs"
fi

# --- ensure SOPS secret manifest in platform path ---
SOPS_MANIFEST_DIR="${MANIFEST_DIR}/platform/sops"
ensure_dir_atomic "${SOPS_MANIFEST_DIR}"
if [ ! -f "${SOPS_MANIFEST_DIR}/secret.yaml" ]; then
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
    git push "https://${GIT_TOKEN}@${AUTH_URL}" "HEAD:${GIT_BRANCH}" || fail "git push of sops manifest failed"
    log "sops secret manifest committed and pushed"
  else
    log "no change to commit for sops secret"
  fi
else
  log "sops secret manifest already present; not overwriting"
fi

# --- ensure .sops.pub exists in repo (idempotent) ---
if [ "${PUSH_PUBLIC_KEY_TO_REPO}" = "true" ]; then
  SOPS_PUB_PATH="${MANIFEST_DIR}/.sops.pub"
  PUB_CONTENT="# public key: ${PUB_LINE#public key: }"
  if [ -f "${SOPS_PUB_PATH}" ]; then
    if [ "$(sed -n '1p' "${SOPS_PUB_PATH}")" = "${PUB_CONTENT}" ]; then
      log ".sops.pub already present and matches; skipping"
    else
      log ".sops.pub present but differs; preserving existing file (idempotent mode)"
    fi
  else
    write_atomic "${SOPS_PUB_PATH}" "${PUB_CONTENT}"
    git add "${SOPS_PUB_PATH}"
    if git commit -m "chore: add sops public key for cluster bootstrap" >/dev/null 2>&1; then
      git push "https://${GIT_TOKEN}@${AUTH_URL}" "HEAD:${GIT_BRANCH}" || fail "git push of .sops.pub failed"
      log "public key pushed to ${SOPS_PUB_PATH}"
    else
      log "no change for .sops.pub"
    fi
  fi
else
  log "PUSH_PUBLIC_KEY_TO_REPO is false; not pushing public key"
fi

# --- ensure a platform Kustomization CR is declared under flux-system (permanent fix) ---
# This is the critical change: create a Kustomization resource (applied by flux-system)
# that points to ./src/manifests/platform so platform/ is reconciled automatically.
ensure_dir_atomic "$(dirname "${PLATFORM_KUSTOMIZATION_FILE}")"

PLATFORM_KUSTOMIZATION_YAML=$(cat <<EOF
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: ${PLATFORM_KUSTOMIZATION_NAME}
  namespace: flux-system
spec:
  interval: ${PLATFORM_KUSTOMIZATION_INTERVAL}
  path: ./src/manifests/platform
  prune: true
  suspend: false
  sourceRef:
    kind: GitRepository
    name: flux-system
  validation: client
  # Ensure platform resources are applied after the flux-system bootstrap resources
  dependsOn:
    - name: flux-system
EOF
)

# Write only if different, commit and push
if [ -f "${PLATFORM_KUSTOMIZATION_FILE}" ]; then
  # compare content
  if ! cmp -s <(printf '%s\n' "${PLATFORM_KUSTOMIZATION_YAML}") "${PLATFORM_KUSTOMIZATION_FILE}"; then
    log "updating existing ${PLATFORM_KUSTOMIZATION_FILE}"
    write_atomic "${PLATFORM_KUSTOMIZATION_FILE}" "${PLATFORM_KUSTOMIZATION_YAML}"
    git add "${PLATFORM_KUSTOMIZATION_FILE}"
    git commit -m "chore: ensure platform Kustomization (reconcile platform/ path)" >/dev/null 2>&1 || log "nothing new to commit for platform kustomization"
    git push "https://${GIT_TOKEN}@${AUTH_URL}" "HEAD:${GIT_BRANCH}" || fail "git push of platform kustomization failed"
    log "platform kustomization updated and pushed"
  else
    log "platform kustomization already present and identical; skipping"
  fi
else
  log "creating ${PLATFORM_KUSTOMIZATION_FILE}"
  write_atomic "${PLATFORM_KUSTOMIZATION_FILE}" "${PLATFORM_KUSTOMIZATION_YAML}"
  git add "${PLATFORM_KUSTOMIZATION_FILE}"
  git commit -m "chore: add platform Kustomization (reconcile platform/ path)" >/dev/null 2>&1 || log "nothing new to commit for platform kustomization"
  git push "https://${GIT_TOKEN}@${AUTH_URL}" "HEAD:${GIT_BRANCH}" || fail "git push of platform kustomization failed"
  log "platform kustomization committed and pushed"
fi

log "bootstrap complete. ${MANIFEST_DIR} contains flux skeleton, platform Kustomization, and any sops manifests created."
exit 0
