#!/usr/bin/env bash
set -euo pipefail
GIT_URL="${GIT_URL:-}"
GIT_TOKEN="${GIT_TOKEN:-}"
GIT_BRANCH="${GIT_BRANCH:-main}"
ENV="${ENV:-dev}"
MANIFEST_DIR="${MANIFEST_DIR:-src/manifests}"
FLYTE_DIR="${MANIFEST_DIR}/flyte"
CNPG_DIR="${MANIFEST_DIR}/cnpg"
NAMESPACES_DIR="${MANIFEST_DIR}/namespaces"
FLYTE_HELM_VERSION="${FLYTE_HELM_VERSION:-1.16.3}"
FLYTE_RELEASE_NAME="${FLYTE_RELEASE_NAME:-ml8s-flyte}"
FLYTE_NAMESPACE="${FLYTE_NAMESPACE:-ml8s-${ENV}-flyte}"
POSTGRES_CLUSTER_NAME="${POSTGRES_CLUSTER_NAME:-ml8s-postgres}"
POSTGRES_NS="${POSTGRES_NS:-ml8s-${ENV}-cnpg}"
MINIO_NS="${MINIO_NS:-ml8s-${ENV}-minio}"
MINIO_BUCKET="${MINIO_BUCKET:-ml8s-flyte-${ENV}}"
SOPS_PUB_FILE_ENV="${SOPS_AGE_PUBLIC_KEY:-}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT
log(){ printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail(){ log "ERROR: $*"; exit 1; }
[ -n "${GIT_URL}" ] || fail "GIT_URL must be set"
[ -n "${GIT_TOKEN}" ] || fail "GIT_TOKEN must be set"
command -v git >/dev/null 2>&1 || fail "git required"
mkdir -p "${TMPROOT}/repo"
AUTH_URL="$(echo "${GIT_URL}" | sed -E 's#^https://##')"
CLONE_URL="https://${GIT_TOKEN}@${AUTH_URL}"
log "cloning ${GIT_URL} (branch ${GIT_BRANCH})"
if ! git clone --depth 1 --branch "${GIT_BRANCH}" "${CLONE_URL}" "${TMPROOT}/repo" >/dev/null 2>&1; then
  log "branch ${GIT_BRANCH} not found; creating orphan branch in new clone"
  git clone --depth 1 "${CLONE_URL}" "${TMPROOT}/repo" >/dev/null 2>&1 || fail "git clone failed"
  cd "${TMPROOT}/repo"
  git checkout --orphan "${GIT_BRANCH}" >/dev/null 2>&1 || true
else
  cd "${TMPROOT}/repo"
fi
mkdir -p "${FLYTE_DIR}" "${CNPG_DIR}" "${NAMESPACES_DIR}"
KUST_TMP="${TMPROOT}/kustomization.yaml"
cat > "${KUST_TMP}" <<'KUST'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- namespaces/
- cnpg/
- flyte/
KUST
mv -f "${KUST_TMP}" "${MANIFEST_DIR}/kustomization.yaml"
NS_KUST_TMP="${TMPROOT}/namespaces.kustomization.yaml"
cat > "${NS_KUST_TMP}" <<'KUST'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- namespaces.yaml
KUST
mv -f "${NS_KUST_TMP}" "${NAMESPACES_DIR}/kustomization.yaml"
NS_TMP="${TMPROOT}/namespaces.yaml"
cat > "${NS_TMP}" <<NS
apiVersion: v1
kind: Namespace
metadata:
  name: ${FLYTE_NAMESPACE}
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${POSTGRES_NS}
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${MINIO_NS}
NS
mv -f "${NS_TMP}" "${NAMESPACES_DIR}/namespaces.yaml"
CNPG_KUST_TMP="${TMPROOT}/cnpg.kustomization.yaml"
cat > "${CNPG_KUST_TMP}" <<'KUST'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- cluster.yaml
- https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.27/releases/cnpg-1.27.3.yaml
KUST
mv -f "${CNPG_KUST_TMP}" "${CNPG_DIR}/kustomization.yaml"
CLUSTER_TMP="${TMPROOT}/cluster.yaml"
cat > "${CLUSTER_TMP}" <<YML
apiVersion: v1
kind: Secret
metadata:
  name: ${POSTGRES_CLUSTER_NAME}-superuser
  namespace: PLACEHOLDER_NS
type: kubernetes.io/basic-auth
stringData:
  username: postgres
  password: postgres
---
apiVersion: v1
kind: Secret
metadata:
  name: ${POSTGRES_CLUSTER_NAME}-app-user
  namespace: PLACEHOLDER_NS
type: kubernetes.io/basic-auth
stringData:
  username: flyte
  password: flytepass
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: PLACEHOLDER_CLUSTER
  namespace: PLACEHOLDER_NS
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:18.1-system-trixie
  postgresql:
    parameters:
      shared_buffers: "256MB"
      max_connections: "100"
  superuserSecret:
    name: ${POSTGRES_CLUSTER_NAME}-superuser
  bootstrap:
    initdb:
      database: flyteadmin
      owner: flyte
      secret:
        name: ${POSTGRES_CLUSTER_NAME}-app-user
  storage:
    storageClass: "standard"
    size: 8Gi
YML
sed -i "s|PLACEHOLDER_NS|${POSTGRES_NS}|g" "${CLUSTER_TMP}"
sed -i "s|PLACEHOLDER_CLUSTER|${POSTGRES_CLUSTER_NAME}|g" "${CLUSTER_TMP}"
mv -f "${CLUSTER_TMP}" "${CNPG_DIR}/cluster.yaml"
FLYTE_KUST_TMP="${TMPROOT}/flyte.kustomization.yaml"
cat > "${FLYTE_KUST_TMP}" <<'KUST'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- helmrepository.yaml
- values.yaml
- helmrelease.yaml
KUST
mv -f "${FLYTE_KUST_TMP}" "${FLYTE_DIR}/kustomization.yaml"
HELMREPO_TMP="${TMPROOT}/helmrepository.yaml"
cat > "${HELMREPO_TMP}" <<'YML'
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: flyteorg
  namespace: flux-system
spec:
  url: https://helm.flyte.org
  interval: 24h
YML
mv -f "${HELMREPO_TMP}" "${FLYTE_DIR}/helmrepository.yaml"
VALUES_TMP="${TMPROOT}/values.yaml"
cat > "${VALUES_TMP}" <<YML
image:
  tag: v1.16.4
resources:
  requests:
    cpu: 250m
    memory: 512Mi
  limits:
    cpu: 1000m
    memory: 2Gi
ingress:
  enabled: false
replicaCount: 1
YML
mv -f "${VALUES_TMP}" "${FLYTE_DIR}/values.yaml"
HELMREL_TMP="${TMPROOT}/helmrelease.yaml"
cat > "${HELMREL_TMP}" <<HELM
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: ${FLYTE_RELEASE_NAME}
  namespace: ${FLYTE_NAMESPACE}
spec:
  interval: 5m
  chart:
    spec:
      chart: flyte-core
      sourceRef:
        kind: HelmRepository
        name: flyteorg
        namespace: flux-system
      version: ${FLYTE_HELM_VERSION}
  values:
    storage:
      type: s3
      bucketName: ${MINIO_BUCKET}
    secretName: flyte-storage-secret
HELM
mv -f "${HELMREL_TMP}" "${FLYTE_DIR}/helmrelease.yaml"
STORAGE_TMP="${TMPROOT}/storage.yaml"
cat > "${STORAGE_TMP}" <<'YML'
apiVersion: v1
kind: Secret
metadata:
  name: flyte-storage-secret
  namespace: PLACEHOLDER_FLYTE_NS
type: Opaque
stringData:
  access_key_id: REPLACE_ME
  secret_key: REPLACE_ME
  endpoint: https://s3.amazonaws.com
  bucket: PLACEHOLDER_BUCKET
YML
sed -i "s|PLACEHOLDER_FLYTE_NS|${FLYTE_NAMESPACE}|g" "${STORAGE_TMP}"
sed -i "s|PLACEHOLDER_BUCKET|${MINIO_BUCKET}|g" "${STORAGE_TMP}"
PUB=""
if [ -f "${TMPROOT}/repo/${MANIFEST_DIR}/.sops.pub" ]; then
  PUB="$(sed -n '1p' "${TMPROOT}/repo/${MANIFEST_DIR}/.sops.pub" | sed 's/^# *public key: *//')"
elif [ -n "${SOPS_PUB_FILE_ENV:-}" ]; then
  PUB="${SOPS_PUB_FILE_ENV}"
fi
if [ -n "${PUB}" ]; then
  if ! command -v sops >/dev/null 2>&1; then
    SOPS_BIN="${TMPROOT}/sops.bin"
    curl -fsSL "https://github.com/getsops/sops/releases/download/v3.11.0/sops-v3.11.0.linux.amd64" -o "${SOPS_BIN}" || fail "download sops failed"
    chmod +x "${SOPS_BIN}"
    mv "${SOPS_BIN}" /usr/local/bin/sops 2>/dev/null || SOPS_PATH="${SOPS_BIN}"
  fi
  if command -v sops >/dev/null 2>&1 || [ -n "${SOPS_PATH:-}" ]; then
    SOPS_EXEC="${SOPS_PATH:-$(command -v sops)}"
    "${SOPS_EXEC}" --age="${PUB}" --encrypt "${STORAGE_TMP}" > "${FLYTE_DIR}/secret.enc.yaml" || fail "sops encrypt failed"
    rm -f "${STORAGE_TMP}"
    log "wrote ${FLYTE_DIR}/secret.enc.yaml (age encrypted)"
  else
    mv -f "${STORAGE_TMP}" "${FLYTE_DIR}/secret.yaml"
    log "sops not available; wrote plaintext ${FLYTE_DIR}/secret.yaml"
  fi
else
  mv -f "${STORAGE_TMP}" "${FLYTE_DIR}/secret.yaml"
  log "no sops public key found; wrote plaintext ${FLYTE_DIR}/secret.yaml (do not commit plaintext in prod)"
fi
git add --all "${MANIFEST_DIR}"
if git commit -m "chore: render flyte + cnpg manifests for ${ENV}" >/dev/null 2>&1; then
  log "commit created"
else
  log "nothing to commit"
fi
PUSH_URL="https://${GIT_TOKEN}@${AUTH_URL}"
for i in 1 2 3; do
  if git push "${PUSH_URL}" "HEAD:${GIT_BRANCH}" >/dev/null 2>&1; then
    log "git push succeeded"
    break
  fi
  sleep 2
done
log "render + push complete. Manifests in ${MANIFEST_DIR} ready for GitOps reconciliation"
exit 0
