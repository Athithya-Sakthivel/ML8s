#!/usr/bin/env bash
CLUSTER_NAME="${CLUSTER_NAME:-ml8s-local}" 
KIND_VERSION="${KIND_VERSION:-v0.29.0}"
K8S_NODE_IMAGE="${K8S_NODE_IMAGE:-kindest/node:v1.33.1}"
LOCAL_BIN="${LOCAL_BIN:-$HOME/.local/bin}"
FLUX_IMAGES=(
  "ghcr.io/fluxcd/source-controller:v1.4.1"
  "ghcr.io/fluxcd/kustomize-controller:v1.4.0"
  "ghcr.io/fluxcd/helm-controller:v0.37.4"
  "ghcr.io/fluxcd/notification-controller:v1.4.0"
)
EXTRA_IMAGES=("${EXTRA_IMAGES[@]:-docker.io/qdrant/qdrant:v1.16.0}")
mkdir -p "$LOCAL_BIN"
export PATH="$LOCAL_BIN:$PATH"
log(){ printf "%s %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
require(){ command -v "$1" >/dev/null 2>&1 || { log "fatal: $1 required"; exit 1; } }
require curl
require docker
docker info >/dev/null 2>&1 || { log "fatal: docker daemon not running"; exit 1; }
OS="$(uname | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in x86_64|amd64) ARCH="amd64" ;; aarch64|arm64) ARCH="arm64" ;; *) ARCH="amd64" ;; esac
if ! command -v kind >/dev/null 2>&1; then
  log "installing kind ${KIND_VERSION}"
  curl -fsSL "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}" -o "${LOCAL_BIN}/kind"
  chmod +x "${LOCAL_BIN}/kind"
fi
if ! command -v kubectl >/dev/null 2>&1; then
  KUBECTL_VERSION="$(curl -s https://dl.k8s.io/release/stable.txt)"
  log "installing kubectl ${KUBECTL_VERSION}"
  curl -fsSL -o "${LOCAL_BIN}/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl"
  chmod +x "${LOCAL_BIN}/kubectl"
fi
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  log "deleting existing cluster ${CLUSTER_NAME}"
  kind delete cluster --name "${CLUSTER_NAME}"
fi
log "pulling node image ${K8S_NODE_IMAGE}"
docker pull "${K8S_NODE_IMAGE}"
log "creating cluster ${CLUSTER_NAME}"
cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --image "${K8S_NODE_IMAGE}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
EOF
log "waiting for node readiness"
kubectl wait --for=condition=Ready nodes --all --timeout=180s
NODES=( $(kind get nodes --name "${CLUSTER_NAME}") )
if [ "${#NODES[@]}" -eq 0 ]; then log "fatal: no kind nodes found"; exit 1; fi
for node in "${NODES[@]}"; do
  log "waiting for containerd to be ready on ${node}"
  for i in {1..30}; do
    if docker exec "${node}" sh -c 'command -v ctr >/dev/null 2>&1 && ctr version >/dev/null 2>&1'; then
      log "containerd ready on ${node}"
      break
    fi
    if [ "$i" -eq 30 ]; then log "fatal: containerd not ready on ${node} after timeout"; exit 1; fi
    sleep 2
  done
done
ALL_IMAGES=( "${FLUX_IMAGES[@]}" "${EXTRA_IMAGES[@]}" )
for node in "${NODES[@]}"; do
  for img in "${ALL_IMAGES[@]}"; do
    log "ensuring ${img} on ${node}"
    if docker exec "${node}" sh -c "ctr -n k8s.io images ls | awk '{print \$1}' | grep -q \"^${img}\$\"" >/dev/null 2>&1; then
      log "image ${img} already present on ${node}"
      continue
    fi
    log "attempting ctr pull ${img} inside ${node}"
    if docker exec "${node}" sh -c "ctr -n k8s.io images pull --all-platforms ${img}" >/dev/null 2>&1; then
      log "ctr pull succeeded for ${img} on ${node}"
      continue
    fi
    log "ctr pull failed, falling back to docker save/import for ${img}"
    if docker pull "${img}"; then
      docker save "${img}" | docker exec -i "${node}" sh -c "ctr -n k8s.io images import --all-platforms --digests -" && log "imported ${img} into ${node}" || log "warn: import failed for ${img} on ${node}"
    else
      log "warn: docker pull failed for ${img}; skipping"
    fi
  done
done
log "applying allow-all network policy"
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-all
  namespace: default
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - {}
  egress:
    - {}
EOF
for node in "${NODES[@]}"; do
  log "images on ${node}:"
  docker exec "${node}" sh -c 'ctr -n k8s.io images ls' || true
done
log "kind cluster ${CLUSTER_NAME} ready"
