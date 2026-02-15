#!/usr/bin/env bash

K3S_VERSION="${K3S_VERSION:-v1.28.5+k3s1}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${HOME}/.kube/config}"
GIT_URL="${GIT_URL:-}"
GIT_TOKEN="${GIT_TOKEN:-}"
GIT_BRANCH="${GIT_BRANCH:-main}"
FLUX_CLI_VERSION="${FLUX_CLI_VERSION:-v2.7.5}"
SOPS_SECRET_NAME="${SOPS_SECRET_NAME:-sops-age}"
AGE_KEY_FILE="${AGE_KEY_FILE:-/tmp/age.agekey}"
MANIFEST_DIR="${MANIFEST_DIR:-src/manifests}"
PRELOAD_IMAGES="${PRELOAD_IMAGES:-ghcr.io/fluxcd/source-controller:v1.4.1 ghcr.io/fluxcd/kustomize-controller:v1.4.0 ghcr.io/fluxcd/helm-controller:v0.37.4 ghcr.io/fluxcd/notification-controller:v1.4.0}"
TMPDIR="${TMPDIR:-/tmp}"
K3S_LOG="${K3S_LOG:-/tmp/k3s.log}"
log(){ printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail(){ log "ERROR: $*"; exit 1; }
[ -n "${GIT_URL}" ] || fail "GIT_URL must be set"
[ -n "${GIT_TOKEN}" ] || fail "GIT_TOKEN must be set"
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v sudo >/dev/null 2>&1 || fail "sudo is required"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "${REPO_ROOT}" ] || fail "must run inside a git repository"
cd "${REPO_ROOT}"
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "${CURRENT_BRANCH}" != "${GIT_BRANCH}" ]; then
  git rev-parse --verify "${GIT_BRANCH}" >/dev/null 2>&1 || fail "branch ${GIT_BRANCH} not present locally; checkout or set GIT_BRANCH"
  git checkout "${GIT_BRANCH}" || fail "git checkout ${GIT_BRANCH} failed"
fi
git diff --quiet --ignore-submodules || fail "working tree dirty; commit or stash before running"
git fetch --quiet origin "${GIT_BRANCH}" || fail "git fetch failed"
BEHIND_COUNT="$(git rev-list --count HEAD..origin/${GIT_BRANCH} 2>/dev/null || echo 0)"
if [ "${BEHIND_COUNT}" -gt 0 ]; then
  fail "local branch is behind origin/${GIT_BRANCH}; run 'git pull --ff-only' first"
fi
write_atomic(){ local file="$1"; local tmp="${file}.tmp"; mkdir -p "$(dirname "${file}")"; printf '%s\n' "$2" > "${tmp}" && mv -f "${tmp}" "${file}"; }
ensure_dir_atomic(){ mkdir -p "$1" || fail "mkdir failed for $1"; }
install_k3s(){
  if command -v k3s >/dev/null 2>&1; then
    INSTALLED="$(k3s --version | head -n1 | awk '{print $3}' || true)"
    if [ "${INSTALLED}" = "${K3S_VERSION}" ]; then
      log "k3s ${K3S_VERSION} already installed"
      return
    else
      log "existing k3s ${INSTALLED} found; uninstalling"
      sudo /usr/local/bin/k3s-uninstall.sh || true
    fi
  fi
  log "installing k3s ${K3S_VERSION} (skip auto-start)"
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" INSTALL_K3S_SKIP_START=true sh -s - || fail "k3s installer failed"
  log "k3s binary installed"
}
start_k3s_serviceless(){
  log "starting k3s server in non-systemd mode (logs: ${K3S_LOG})"
  sudo nohup env PATH="$PATH" k3s server --disable traefik --disable servicelb >"${K3S_LOG}" 2>&1 &
  sleep 1
  log "waiting for k3s API"
  retry=0
  until sudo k3s kubectl get nodes >/dev/null 2>&1; do
    retry=$((retry+1))
    if [ "${retry}" -gt 60 ]; then
      cat "${K3S_LOG}" || true
      fail "k3s API did not become ready in time"
    fi
    sleep 2
  done
  log "k3s API ready"
  sudo mkdir -p "$(dirname "${KUBECONFIG_PATH}")"
  sudo cp /etc/rancher/k3s/k3s.yaml "${KUBECONFIG_PATH}"
  sudo chown $(id -u):$(id -g) "${KUBECONFIG_PATH}"
  chmod 600 "${KUBECONFIG_PATH}"
  export KUBECONFIG="${KUBECONFIG_PATH}"
}
preload_images(){
  for IMG in ${PRELOAD_IMAGES}; do
    log "ensuring image ${IMG} present in k3s runtime"
    if sudo k3s ctr -n k8s.io images ls | grep -qF "${IMG}"; then
      log "image already present: ${IMG}"
      continue
    fi
    log "pulling ${IMG} into k3s runtime"
    if sudo k3s ctr -n k8s.io images pull "${IMG}"; then
      log "pulled ${IMG}"
      continue
    fi
    log "pull failed for ${IMG}; retrying once"
    sleep 2
    if sudo k3s ctr -n k8s.io images pull "${IMG}"; then
      log "pulled ${IMG} on retry"
      continue
    fi
    log "warn: failed to preload ${IMG}; will proceed (node-side pull may occur at pod start)"
  done
}
install_flux_cli(){
  if command -v flux >/dev/null 2>&1; then
    log "flux cli found at $(command -v flux)"
    return
  fi
  log "installing flux cli ${FLUX_CLI_VERSION}"
  OS="$(uname | tr '[:upper:]' '[:lower:]')"
  case "${OS}" in linux) ASSET="flux_${FLUX_CLI_VERSION#v}_linux_amd64.tar.gz" ;; darwin) ASSET="flux_${FLUX_CLI_VERSION#v}_darwin_amd64.tar.gz" ;; *) fail "unsupported os ${OS}" ;; esac
  URL="https://github.com/fluxcd/flux2/releases/download/${FLUX_CLI_VERSION}/${ASSET}"
  TMP_TAR="${TMPDIR}/flux-${FLUX_CLI_VERSION}.tar.gz"
  curl -fsSL "${URL}" -o "${TMP_TAR}" || fail "download flux failed"
  tar -C "${TMPDIR}" -xzf "${TMP_TAR}"
  sudo mv "${TMPDIR}/flux" /usr/local/bin/flux || fail "move flux failed"
  sudo chmod +x /usr/local/bin/flux
  log "flux installed to /usr/local/bin/flux"
}
ensure_age_key(){
  if [ -f "${AGE_KEY_FILE}" ]; then
    log "reusing existing age key ${AGE_KEY_FILE}"
    return
  fi
  if ! command -v age-keygen >/dev/null 2>&1; then
    log "installing age-keygen"
    AGE_API="https://api.github.com/repos/FiloSottile/age/releases/latest"
    AGE_TAG="$(curl -fsSL "${AGE_API}" | grep -Po '\"tag_name\":\\s*\"\\K(.*?)(?=\")')"
    [ -n "${AGE_TAG}" ] || fail "could not find age release"
    OS="$(uname | tr '[:upper:]' '[:lower:]')"
    case "${OS}" in linux) AGE_ASSET="age-${AGE_TAG}-linux-amd64.tar.gz" ;; darwin) AGE_ASSET="age-${AGE_TAG}-darwin-amd64.tar.gz" ;; *) fail "unsupported os for age" ;; esac
    AGE_URL="https://github.com/FiloSottile/age/releases/download/${AGE_TAG}/${AGE_ASSET}"
    TMP_AGE="${TMPDIR}/age-${AGE_TAG}.tar.gz"
    curl -fsSL "${AGE_URL}" -o "${TMP_AGE}" || fail "download age failed"
    tar -C "${TMPDIR}" -xzf "${TMP_AGE}"
    if [ -f "${TMPDIR}/age/age-keygen" ]; then sudo mv "${TMPDIR}/age/age-keygen" /usr/local/bin/age-keygen; else sudo mv "${TMPDIR}/age-keygen" /usr/local/bin/age-keygen; fi
    sudo chmod +x /usr/local/bin/age-keygen
  fi
  age-keygen -o "${AGE_KEY_FILE}" || fail "age-keygen failed"
  log "generated age key at ${AGE_KEY_FILE}"
}
flux_bootstrap_and_commit(){
  AUTH_URL="$(echo "${GIT_URL}" | sed -E 's#^https://##')"
  if [ ! -d "${MANIFEST_DIR}" ]; then
    ensure_dir_atomic "${MANIFEST_DIR}/flux-system"
    ensure_dir_atomic "${MANIFEST_DIR}/platform"
    write_atomic "${MANIFEST_DIR}/kustomization.yaml" $'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n- flux-system/\n- platform/\n'
    git add --all "${MANIFEST_DIR}"
    git commit -m "chore: add flux-safe skeleton (flux-system + platform)" >/dev/null 2>&1 || log "no skeleton changes to commit"
    git push "https://${GIT_TOKEN}@${AUTH_URL}" "HEAD:${GIT_BRANCH}" || fail "git push skeleton failed"
  fi
  export KUBECONFIG="${KUBECONFIG_PATH}"
  log "running flux bootstrap git --path=${MANIFEST_DIR}/flux-system"
  flux bootstrap git --url="${GIT_URL}" --branch="${GIT_BRANCH}" --path="${MANIFEST_DIR}/flux-system" --token-auth --username=git --password="${GIT_TOKEN}" --version="${FLUX_CLI_VERSION}" --timeout=2m || log "flux bootstrap returned non-zero (continuing; controllers will reconcile in background)"
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
  git commit -m "chore: add sops-age secret manifest (flux-system namespace)" >/dev/null 2>&1 || log "no change to commit for sops secret"
  if [ "${PUSH_PUBLIC_KEY_TO_REPO:-true}" = "true" ]; then
    PUB_LINE="$(grep -i 'public key:' -m1 "${AGE_KEY_FILE}" | sed 's/^[[:space:]]*//')"
    write_atomic "${MANIFEST_DIR}/.sops.pub" "# public key: ${PUB_LINE#public key: }"
    git add "${MANIFEST_DIR}/.sops.pub"
    git commit -m "chore: add sops public key for cluster bootstrap" >/dev/null 2>&1 || log "no change for .sops.pub"
  fi
  git push "https://${GIT_TOKEN}@${AUTH_URL}" "HEAD:${GIT_BRANCH}" || log "git push failed (check network/credentials)"
}
main(){
  install_k3s
  start_k3s_serviceless
  preload_images
  install_flux_cli
  ensure_age_key
  flux_bootstrap_and_commit
  kubectl get nodes -o wide
  kubectl -n flux-system get pods -o wide || true
  log "bootstrap sequence complete; flux will reconcile platform manifests from ${GIT_URL} (path ${MANIFEST_DIR})"
}
main
exit 0
